/*
 * External push-button — record on/off (short press) + deep sleep (long press).
 *
 * Wiring CONFIRMED on-device via a GPIO bridge scan (omi-standard 2-pin):
 *   D4 (P0.04) — driven HIGH as the switch's power rail
 *   D5 (P0.05) — input with internal pull-down
 * A press connects D4 -> D5 so D5 reads HIGH.
 *
 * We POLL D5 (40 ms) from a low-priority thread so we can measure press
 * duration:
 *   - short press (< LONG_PRESS_MS) -> toggle SD recording (pause/resume)
 *   - long  press (>= LONG_PRESS_MS) -> deep sleep (nRF System OFF); a later
 *     button press wakes the device (it resets and boots).
 * Deep sleep is also reachable from the app over BLE via
 * wr_button_request_sleep().
 */

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/poweroff.h>

#include "wr_button.h"
#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_button, LOG_LEVEL_INF);

#define GPIO0_NODE DT_NODELABEL(gpio0)
#define BTN_PWR_PIN 4 /* D4 / P0.04 — HIGH power rail for the switch */
#define BTN_IN_PIN 5  /* D5 / P0.05 — press input (pull-down) */
#define POLL_MS 40
#define SHORT_MIN_MS 40    /* ignore sub-40 ms bounce */
#define LONG_PRESS_MS 1500 /* hold this long -> deep sleep */

static const struct device *const gpio0 = DEVICE_DT_GET(GPIO0_NODE);
static K_THREAD_STACK_DEFINE(btn_stack, 1024);
static struct k_thread btn_thread;

static void enter_deep_sleep(void)
{
	LOG_INF("deep sleep: flushing SD and powering off (press button to wake)");

	/* Stop recording and give the recorder thread time to flush + close the
	 * SD file before we cut power. */
	wr_recorder_pause();
	k_sleep(K_MSEC(600));

	/* Keep D4 as the HIGH power rail and arm D5 as a System OFF wake source
	 * (level-high sense): a press pulls D5 high and wakes (resets) the chip. */
	(void)gpio_pin_configure(gpio0, BTN_PWR_PIN, GPIO_OUTPUT_HIGH);
	(void)gpio_pin_interrupt_configure(gpio0, BTN_IN_PIN,
					   GPIO_INT_LEVEL_ACTIVE);

	sys_poweroff(); /* does not return */
}

void wr_button_request_sleep(void)
{
	enter_deep_sleep();
}

static void toggle_recording(void)
{
	if (wr_recorder_is_recording()) {
		LOG_INF("button: stop recording");
		wr_recorder_pause();
	} else {
		LOG_INF("button: start recording");
		wr_recorder_resume();
	}
}

static void btn_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	int prev = 0;
	int64_t press_start = 0;

	for (;;) {
		const int cur = gpio_pin_get(gpio0, BTN_IN_PIN);
		const int64_t now = k_uptime_get();

		if (cur == 1 && prev == 0) {
			press_start = now; /* press began */
		} else if (cur == 0 && prev == 1) {
			const int64_t dur = now - press_start; /* released */

			if (dur >= LONG_PRESS_MS) {
				enter_deep_sleep(); /* does not return */
			} else if (dur >= SHORT_MIN_MS) {
				toggle_recording();
			}
		}
		prev = cur;
		k_msleep(POLL_MS);
	}
}

int wr_button_init(void)
{
	if (!device_is_ready(gpio0)) {
		LOG_ERR("gpio0 not ready");
		return -ENODEV;
	}

	int rc = gpio_pin_configure(gpio0, BTN_PWR_PIN, GPIO_OUTPUT_HIGH);

	if (rc < 0) {
		LOG_ERR("D4 (power) configure failed: %d", rc);
		return rc;
	}

	rc = gpio_pin_configure(gpio0, BTN_IN_PIN, GPIO_INPUT | GPIO_PULL_DOWN);
	if (rc < 0) {
		LOG_ERR("D5 (input) configure failed: %d", rc);
		return rc;
	}

	k_thread_create(&btn_thread, btn_stack,
			K_THREAD_STACK_SIZEOF(btn_stack), btn_entry, NULL, NULL,
			NULL, 7, 0, K_NO_WAIT);

	LOG_INF("button ready (D4 power / D5 input, polled): "
		"short=rec on/off, long=deep sleep");
	return 0;
}
