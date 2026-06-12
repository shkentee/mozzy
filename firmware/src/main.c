/* mojizo firmware application entry point.
 *
 * Bring-up profile: blink the green LED, log over USB CDC ACM. Later
 * tasks add SD mount, BLE peripheral, audio capture, recording state
 * machine.
 */
#include <hal/nrf_power.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/pm/device.h>
#include <zephyr/device.h>

#include "ble.h"
#include "boot_cmd.h"
#include "led.h"
#include "sd.h"
#include "wr_audio.h"
#include "wr_battery.h"
#include "wr_button.h"
#include "wr_recorder.h"
#include "wr_storage_service.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

#define STATUS_FLASH_PERIOD_MS 4000
#define SD_THREAD_STACK_SIZE 4096
#define SD_THREAD_PRIORITY 7

static K_THREAD_STACK_DEFINE(sd_thread_stack, SD_THREAD_STACK_SIZE);
static struct k_thread sd_thread;

/* Hardware watchdog: armed after init, fed in the main loop. If the firmware
 * hangs (radio dies, console goes silent) the WDT resets the SoC instead of
 * leaving it stuck with the radio on, draining the battery flat. */
#define WDT_TIMEOUT_MS 8000
static const struct device *const wdt_dev = DEVICE_DT_GET(DT_NODELABEL(wdt0));
static int wdt_channel = -1;

static void watchdog_arm(void)
{
	if (!device_is_ready(wdt_dev)) {
		LOG_WRN("watchdog device not ready; continuing without WDT");
		return;
	}

	const struct wdt_timeout_cfg cfg = {
		.flags = WDT_FLAG_RESET_SOC,
		.window = {.min = 0U, .max = WDT_TIMEOUT_MS},
		.callback = NULL,
	};

	wdt_channel = wdt_install_timeout(wdt_dev, &cfg);
	if (wdt_channel < 0) {
		LOG_WRN("wdt_install_timeout failed: %d", wdt_channel);
		return;
	}

	const int rc = wdt_setup(wdt_dev, WDT_OPT_PAUSE_HALTED_BY_DBG);
	if (rc < 0) {
		LOG_WRN("wdt_setup failed: %d", rc);
		wdt_channel = -1;
		return;
	}

	LOG_INF("watchdog armed (%d ms)", WDT_TIMEOUT_MS);
}

static void watchdog_feed_now(void)
{
	if (wdt_channel >= 0) {
		(void)wdt_feed(wdt_dev, wdt_channel);
	}
}

/* Battery charge-current select (Seeed XIAO nRF52840, BQ25100 charger).
 * The HICHG pin P0.13 sets the charge current via the BQ25100 R(ISET):
 *   open/high -> 50 mA (board default),  driven LOW -> 100 mA (R(ISET) halved).
 * Driving HIGH would disable charging (0 mA), so we only ever pull it LOW.
 * Held low here so USB charging runs at 100 mA — the small ~250 mAh cell
 * otherwise tops up slowly (the 30 W PD source can't raise this; the cap is
 * on-board). 100 mA into a 250 mAh cell is ~0.4 C, comfortably safe. */
#define CHARGE_HICHG_PORT DT_NODELABEL(gpio0)
#define CHARGE_HICHG_PIN  13U

static void charge_current_set_high(void)
{
	const struct device *port = DEVICE_DT_GET(CHARGE_HICHG_PORT);
	if (!device_is_ready(port)) {
		LOG_WRN("charge-current GPIO not ready; staying at 50 mA");
		return;
	}

	const int rc = gpio_pin_configure(port, CHARGE_HICHG_PIN, GPIO_OUTPUT_LOW);
	if (rc < 0) {
		LOG_WRN("charge-current set failed: %d (staying at 50 mA)", rc);
		return;
	}

	LOG_INF("battery charge current set to 100 mA (P0.13 HICHG low)");
}

/* Low-power setup: enable the DC/DC regulators (more efficient than the LDO)
 * and put the unused onboard QSPI flash into deep-power-down. */
static void power_optimize(void)
{
	/* nRF52840 DC/DC: REG1 (and REG0 for the VDDH stage on XIAO). */
	NRF_POWER->DCDCEN = 1;
	NRF_POWER->DCDCEN0 = 1;

	const struct device *qspi_flash = DEVICE_DT_GET(DT_NODELABEL(p25q16h));
	if (device_is_ready(qspi_flash)) {
		const int rc = pm_device_action_run(qspi_flash,
						    PM_DEVICE_ACTION_SUSPEND);
		if (rc < 0) {
			LOG_WRN("QSPI flash suspend failed: %d", rc);
		} else {
			LOG_INF("QSPI flash suspended (deep power-down)");
		}
	} else {
		LOG_WRN("QSPI flash device not ready; not suspended");
	}
}

static bool take_format_sd_request(void)
{
	if (NRF_POWER->GPREGRET != WR_BOOT_FORMAT_SD_MAGIC) {
		return false;
	}

	NRF_POWER->GPREGRET = 0;
	return true;
}

static void run_requested_sd_format(void)
{
	LOG_WRN("Boot-time SD format requested");

	const int rc = wr_sd_format_destructive();
	if (rc < 0) {
		LOG_ERR("Boot-time SD format failed: %d", rc);
		return;
	}

	(void)wr_sd_ls("/SD:");
	(void)wr_sd_selftest();
}

static void sd_worker(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	LOG_INF("SD init worker started");
	if (wr_sd_mount() == 0) {
		(void)wr_sd_ls("/SD:");
		(void)wr_sd_selftest();
		if (wr_recorder_start() != 0) {
			LOG_WRN("Recorder failed to start");
		}
		(void)wr_sd_ls("/SD:");
	} else {
		LOG_WRN("SD mount failed - continuing without storage");
	}
}

static int wait_for_dtr(void)
{
	const struct device *uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	if (!device_is_ready(uart)) {
		return -ENODEV;
	}
	uint32_t dtr = 0;
	/* Wait up to 5 s for a host to assert DTR; otherwise continue
	 * unconnected so the firmware doesn't hang during a power-only
	 * boot (no USB host attached). */
	for (int i = 0; i < 50 && !dtr; i++) {
		(void)uart_line_ctrl_get(uart, UART_LINE_CTRL_DTR, &dtr);
		k_msleep(100);
	}
	return 0;
}

int main(void)
{
	/* Only bring up USB when VBUS is present. On battery (no VBUS) the USB
	 * peripheral + HFCLK would otherwise idle at ~1-3 mA for nothing — we
	 * read battery / measure over BLE, not the console. Console output and
	 * flashing (flash.ps1 sends 'boot' over CDC) require booting WITH USB
	 * attached; plug in then tap RESET to get a console on a battery boot. */
	const bool usb_vbus =
		(NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0U;
	if (usb_vbus) {
		int ret = usb_enable(NULL);
		if (ret) {
			/* USB might already be enabled by another subsystem; that's fine. */
			LOG_WRN("usb_enable returned %d (continuing)", ret);
		}
		(void)wait_for_dtr();
	} else {
		LOG_INF("No VBUS detected — skipping USB enable (battery power save)");
	}

	LOG_INF("=========================================");
	LOG_INF(" mojizo firmware (scratch v0)");
	LOG_INF("=========================================");
	LOG_INF("Build: " __DATE__ " " __TIME__);

	power_optimize();
	charge_current_set_high();

	const bool format_sd_requested = take_format_sd_request();

	if (wr_led_init() != 0) {
		LOG_ERR("LED init failed; halting");
		return 0;
	}

	(void)wr_boot_cmd_init();

	if (wr_button_init() != 0) {
		LOG_WRN("Button init failed — record toggle button disabled");
	}

	if (format_sd_requested) {
		run_requested_sd_format();
	}

	if (wr_ble_init() != 0) {
		LOG_WRN("BLE init failed — continuing without radio");
	}
	wr_storage_service_start();

	if (wr_battery_init() != 0) {
		LOG_WRN("Battery monitor failed to start");
	}

	if (wr_audio_start() != 0) {
		LOG_WRN("Audio pipeline failed to start");
	}

	(void)k_thread_create(&sd_thread, sd_thread_stack,
				      K_THREAD_STACK_SIZEOF(sd_thread_stack),
				      sd_worker, NULL, NULL, NULL,
				      SD_THREAD_PRIORITY, 0, K_NO_WAIT);

	/* Arm the watchdog only after init (SD mount/format can be slow). */
	watchdog_arm();

	uint32_t tick = 0;
	while (1) {
		watchdog_feed_now();
		/* Status indicator: a brief, dim flash every ~5 s.
		 *   recording -> WHITE flash, idle/paused -> GREEN flash. */
		wr_led_dim_flash(wr_recorder_is_recording());
		LOG_DBG("alive tick=%u recording=%d", tick,
			(int)wr_recorder_is_recording());
		tick++;
		k_msleep(STATUS_FLASH_PERIOD_MS);
	}
	return 0;
}
