/* USB CDC "boot" listener — soft trigger for UF2 bootloader entry.
 *
 * The Adafruit UF2 bootloader on XIAO BLE Sense reads NRF_POWER->GPREGRET
 * at startup. Writing 0x57 (DFU_MAGIC_UF2_RESET) before sys_reboot(COLD)
 * drops the board into UF2 mass-storage mode where a UF2 file can be
 * copy-pasted onto the resulting USB drive.
 *
 * Listener: register a UART RX IRQ on the console (CDC ACM), buffer
 * incoming bytes, match "boot" line → arm magic + reboot.
 *
 * Replaces the manual reset-button double-tap during bring-up; flash.ps1
 * sends `boot\n` over the COM port and gets a UF2 drive in seconds.
 */
#include "boot_cmd.h"

#include <hal/nrf_power.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>

LOG_MODULE_REGISTER(wr_boot, LOG_LEVEL_INF);

/* DFU_MAGIC_UF2_RESET from Adafruit_nRF52_Bootloader. */
#define ADAFRUIT_UF2_MAGIC 0x57

#define BOOT_RX_BUF_LEN 16

static char rx_buf[BOOT_RX_BUF_LEN];
static size_t rx_idx;

static void boot_cmd_uart_cb(const struct device *dev, void *user_data)
{
	ARG_UNUSED(user_data);

	if (!uart_irq_update(dev)) {
		return;
	}

	while (uart_irq_rx_ready(dev)) {
		uint8_t c;

		if (uart_fifo_read(dev, &c, 1) <= 0) {
			break;
		}

		if (c == '\n' || c == '\r') {
			rx_buf[rx_idx] = '\0';
			if (strcmp(rx_buf, "boot") == 0) {
				LOG_INF("'boot' received — entering UF2 bootloader");
				/* Let the LOG_INF flush before USB session dies. */
				k_sleep(K_MSEC(50));
				NRF_POWER->GPREGRET = ADAFRUIT_UF2_MAGIC;
				sys_reboot(SYS_REBOOT_COLD);
			} else if (strcmp(rx_buf, "format-sd") == 0) {
				LOG_WRN("'format-sd' received - rebooting into SD formatter");
				k_sleep(K_MSEC(50));
				NRF_POWER->GPREGRET = WR_BOOT_FORMAT_SD_MAGIC;
				sys_reboot(SYS_REBOOT_COLD);
			}
			rx_idx = 0;
		} else if (rx_idx < (BOOT_RX_BUF_LEN - 1)) {
			rx_buf[rx_idx++] = (char)c;
		} else {
			rx_idx = 0;
		}
	}
}

int wr_boot_cmd_init(void)
{
	const struct device *console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	if (!device_is_ready(console)) {
		LOG_WRN("console UART not ready; boot-listener inactive");
		return -ENODEV;
	}
	int rc = uart_irq_callback_user_data_set(console, boot_cmd_uart_cb, NULL);
	if (rc) {
		LOG_WRN("uart_irq_callback_user_data_set: %d", rc);
		return rc;
	}
	uart_irq_rx_enable(console);
	LOG_INF("boot-cmd listener armed (send 'boot\\n' to trigger UF2 entry)");
	return 0;
}
