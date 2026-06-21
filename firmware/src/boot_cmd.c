/* USB CDC command listener.
 *
 * Existing commands:
 *   boot       -> enter UF2 bootloader
 *   format-sd  -> reboot into destructive SD formatter
 *
 * Wired rescue commands for the mobile app:
 *   wr-ping
 *   wr-pause
 *   wr-resume
 *   wr-list
 *   wr-fetch <basename.opus_sd> [offset]
 *   wr-bench <bytes>
 *
 * The rescue protocol uses text control lines plus binary chunks with CRC32.
 * The same CDC port is also the Zephyr console, so WR-prefixed control lines
 * let the Android side find protocol boundaries while per-chunk CRC prevents
 * mixed console output from being queued as a valid recording.
 */
#include "boot_cmd.h"

#include <errno.h>
#include <hal/nrf_power.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_boot, LOG_LEVEL_INF);

/* DFU_MAGIC_UF2_RESET from Adafruit_nRF52_Bootloader. */
#define ADAFRUIT_UF2_MAGIC 0x57

#define BOOT_RX_BUF_LEN 96
#define BOOT_CMD_QUEUE_DEPTH 4
#define BOOT_CMD_STACK_SIZE 4096
#define BOOT_CMD_PRIORITY 7
#define STORAGE_MOUNT_POINT "/SD:"
#define STORAGE_MAX_FILENAME 63
#define STORAGE_MAX_PATH 80
#define WIRED_IO_BYTES 65536
#define WIRED_FRAME_BYTES (1024U * 1024U)

static char rx_buf[BOOT_RX_BUF_LEN];
static size_t rx_idx;
static const struct device *console_uart;
static bool boot_cmd_thread_started;
static uint8_t wired_fetch_chunk[WIRED_IO_BYTES];
static volatile bool wired_fetch_cancel_requested;
static bool wired_fetch_dtr_seen;
static const uint8_t *wired_tx_data;
static size_t wired_tx_len;
static size_t wired_tx_offset;
static bool wired_tx_irq_usable = true;

K_MSGQ_DEFINE(boot_cmd_queue, BOOT_RX_BUF_LEN, BOOT_CMD_QUEUE_DEPTH, 4);
K_SEM_DEFINE(wired_tx_done, 0, 1);
K_MUTEX_DEFINE(wired_tx_lock);
static K_THREAD_STACK_DEFINE(boot_cmd_stack, BOOT_CMD_STACK_SIZE);
static struct k_thread boot_cmd_thread;

static void uart_send(const uint8_t *data, size_t len)
{
	if (console_uart == NULL) {
		return;
	}
	if (len == 0U) {
		return;
	}
	if (!wired_tx_irq_usable) {
		for (size_t i = 0; i < len; i++) {
			uart_poll_out(console_uart, data[i]);
		}
		return;
	}

	k_mutex_lock(&wired_tx_lock, K_FOREVER);
	k_sem_reset(&wired_tx_done);
	wired_tx_data = data;
	wired_tx_len = len;
	wired_tx_offset = 0U;
	uart_irq_tx_enable(console_uart);
	if (k_sem_take(&wired_tx_done, K_SECONDS(2)) != 0) {
		uart_irq_tx_disable(console_uart);
		wired_tx_irq_usable = false;
		while (wired_tx_offset < wired_tx_len) {
			uart_poll_out(console_uart, wired_tx_data[wired_tx_offset]);
			wired_tx_offset++;
		}
		wired_tx_data = NULL;
		wired_tx_len = 0U;
		wired_tx_offset = 0U;
	}
	k_mutex_unlock(&wired_tx_lock);
}

static void uart_send_str(const char *s)
{
	uart_send((const uint8_t *)s, strlen(s));
}

static void uart_sendf(const char *fmt, ...)
{
	char line[160];
	va_list args;

	va_start(args, fmt);
	const int n = vsnprintk(line, sizeof(line), fmt, args);
	va_end(args);

	if (n <= 0) {
		return;
	}
	uart_send((const uint8_t *)line,
		  n < (int)sizeof(line) ? (size_t)n : sizeof(line));
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t len)
{
	for (size_t i = 0; i < len; i++) {
		crc ^= data[i];
		for (int bit = 0; bit < 8; bit++) {
			const uint32_t mask = 0U - (crc & 1U);
			crc = (crc >> 1) ^ (0xEDB88320U & mask);
		}
	}

	return crc;
}

static uint32_t crc32_finish(uint32_t crc)
{
	return ~crc;
}

static bool wired_fetch_should_cancel(void)
{
	if (wired_fetch_cancel_requested) {
		return true;
	}
	if (console_uart == NULL) {
		return false;
	}

	uint32_t dtr = 0U;
	const int rc = uart_line_ctrl_get(console_uart, UART_LINE_CTRL_DTR, &dtr);
	if (rc < 0) {
		return false;
	}
	if (dtr != 0U) {
		wired_fetch_dtr_seen = true;
		return false;
	}
	return wired_fetch_dtr_seen;
}

static bool filename_allowed(const char *filename)
{
	if (filename == NULL || filename[0] == '\0') {
		return false;
	}
	for (size_t i = 0; filename[i] != '\0'; i++) {
		if (filename[i] == '/' || filename[i] == '\\' ||
		    filename[i] == ':') {
			return false;
		}
	}
	return true;
}

static bool is_audio_file(const char *filename)
{
	const char *suffix = ".opus_sd";
	const size_t name_len = strlen(filename);
	const size_t suffix_len = strlen(suffix);

	return name_len > suffix_len &&
	       strcmp(&filename[name_len - suffix_len], suffix) == 0;
}

static int build_path(char *path, size_t path_size, const char *filename)
{
	if (!filename_allowed(filename) || !is_audio_file(filename)) {
		return -EINVAL;
	}
	const int written = snprintk(path, path_size, STORAGE_MOUNT_POINT "/%s",
				     filename);
	if (written < 0 || written >= (int)path_size) {
		return -ENAMETOOLONG;
	}
	return 0;
}

static void handle_wired_list(void)
{
	struct fs_dir_t dir;
	struct fs_dirent entry;
	uint32_t count = 0;

	fs_dir_t_init(&dir);
	int rc = fs_opendir(&dir, STORAGE_MOUNT_POINT);
	if (rc < 0) {
		uart_sendf("WR-ERR list-open %d\n", rc);
		return;
	}

	uart_send_str("WR-LIST-BEGIN\n");
	for (;;) {
		rc = fs_readdir(&dir, &entry);
		if (rc < 0) {
			uart_sendf("WR-ERR list-read %d\n", rc);
			break;
		}
		if (entry.name[0] == '\0') {
			break;
		}
		if (entry.type == FS_DIR_ENTRY_DIR) {
			continue;
		}
		if (!is_audio_file(entry.name) ||
		    wr_recorder_is_current_file(entry.name)) {
			continue;
		}
		uart_sendf("WR-FILE %s %zu\n", entry.name, entry.size);
		count++;
	}
	(void)fs_closedir(&dir);
	uart_sendf("WR-END %u\n", count);
}

static bool parse_fetch_args(const char *args, char *filename,
			     size_t filename_size, uint32_t *offset)
{
	if (args == NULL || filename == NULL || offset == NULL) {
		return false;
	}

	*offset = 0;
	const char *space = strchr(args, ' ');
	const size_t name_len = space == NULL ? strlen(args) : (size_t)(space - args);
	if (name_len == 0 || name_len >= filename_size) {
		return false;
	}
	memcpy(filename, args, name_len);
	filename[name_len] = '\0';

	if (space == NULL) {
		return true;
	}
	while (*space == ' ') {
		space++;
	}
	if (*space == '\0') {
		return true;
	}

	char *end = NULL;
	const unsigned long parsed = strtoul(space, &end, 10);
	while (end != NULL && *end == ' ') {
		end++;
	}
	if (end == NULL || *end != '\0' || parsed > UINT32_MAX) {
		return false;
	}
	*offset = (uint32_t)parsed;
	return true;
}

static void handle_wired_fetch(const char *filename, uint32_t offset)
{
	char path[STORAGE_MAX_PATH];
	struct fs_file_t file;
	struct fs_dirent entry;
	uint32_t sent = offset;

	int rc = build_path(path, sizeof(path), filename);
	if (rc < 0) {
		uart_sendf("WR-ERR bad-name %d\n", rc);
		return;
	}
	if (wr_recorder_is_current_file(filename)) {
		uart_send_str("WR-ERR active-file\n");
		return;
	}

	rc = fs_stat(path, &entry);
	if (rc < 0) {
		uart_sendf("WR-ERR stat %d\n", rc);
		return;
	}
	if (offset > entry.size) {
		uart_sendf("WR-ERR offset %u %zu\n", offset, entry.size);
		return;
	}

	fs_file_t_init(&file);
	rc = fs_open(&file, path, FS_O_READ);
	if (rc < 0) {
		uart_sendf("WR-ERR open %d\n", rc);
		return;
	}
	if (offset > 0) {
		rc = fs_seek(&file, offset, FS_SEEK_SET);
		if (rc < 0) {
			uart_sendf("WR-ERR seek %d\n", rc);
			(void)fs_close(&file);
			return;
		}
	}

	wired_fetch_cancel_requested = false;
	wired_fetch_dtr_seen = false;
	uart_sendf("WR-FETCH-BEGIN %s %zu binary-stream-crc32 %u %u\n",
		   filename, entry.size, offset, WIRED_FRAME_BYTES);
	while (sent < entry.size) {
		const uint32_t frame_offset = sent;
		uint32_t frame_len = (uint32_t)(entry.size - sent);
		if (frame_len > WIRED_FRAME_BYTES) {
			frame_len = WIRED_FRAME_BYTES;
		}

		if (wired_fetch_should_cancel()) {
			(void)fs_close(&file);
			uart_sendf("WR-CANCELLED %u\n", sent);
			return;
		}
		uart_sendf("WR-DATA2 %u %u\n", frame_offset, frame_len);

		uint32_t frame_sent = 0U;
		uint32_t crc = 0xFFFFFFFFU;
		while (frame_sent < frame_len) {
			size_t want = sizeof(wired_fetch_chunk);
			if ((frame_len - frame_sent) < want) {
				want = frame_len - frame_sent;
			}
			const ssize_t rd = fs_read(&file, wired_fetch_chunk, want);
			if (rd < 0) {
				uart_sendf("\nWR-ERR read %zd\n", rd);
				(void)fs_close(&file);
				return;
			}
			if (rd == 0) {
				uart_sendf("\nWR-ERR short-read %u %u\n",
					   frame_offset, frame_sent);
				(void)fs_close(&file);
				return;
			}
			crc = crc32_update(crc, wired_fetch_chunk, (size_t)rd);
			uart_send(wired_fetch_chunk, (size_t)rd);
			frame_sent += (uint32_t)rd;
			sent += (uint32_t)rd;
		}
		uart_sendf("\nWR-CRC %u %u %08x\n",
			   frame_offset, frame_len, crc32_finish(crc));
	}
	(void)fs_close(&file);
	uart_sendf("WR-END %u\n", sent);
}

static bool parse_read_bench_args(const char *args, char *filename,
				  size_t filename_size, uint32_t *bytes)
{
	if (args == NULL || filename == NULL || bytes == NULL) {
		return false;
	}

	const char *space = strchr(args, ' ');
	const size_t name_len = space == NULL ? strlen(args) : (size_t)(space - args);
	if (name_len == 0 || name_len >= filename_size || space == NULL) {
		return false;
	}
	memcpy(filename, args, name_len);
	filename[name_len] = '\0';
	while (*space == ' ') {
		space++;
	}
	char *end = NULL;
	const unsigned long parsed = strtoul(space, &end, 10);
	while (end != NULL && *end == ' ') {
		end++;
	}
	if (end == NULL || *end != '\0' || parsed == 0 || parsed > UINT32_MAX) {
		return false;
	}
	*bytes = (uint32_t)parsed;
	return true;
}

static void handle_wired_read_bench(const char *filename, uint32_t bytes)
{
	char path[STORAGE_MAX_PATH];
	struct fs_file_t file;
	struct fs_dirent entry;

	int rc = build_path(path, sizeof(path), filename);
	if (rc < 0) {
		uart_sendf("WR-ERR bad-name %d\n", rc);
		return;
	}
	rc = fs_stat(path, &entry);
	if (rc < 0) {
		uart_sendf("WR-ERR stat %d\n", rc);
		return;
	}

	fs_file_t_init(&file);
	rc = fs_open(&file, path, FS_O_READ);
	if (rc < 0) {
		uart_sendf("WR-ERR open %d\n", rc);
		return;
	}

	uint32_t read_total = 0U;
	const int64_t start_ms = k_uptime_get();
	while (read_total < bytes) {
		size_t want = sizeof(wired_fetch_chunk);
		if ((bytes - read_total) < want) {
			want = bytes - read_total;
		}
		const ssize_t rd = fs_read(&file, wired_fetch_chunk, want);
		if (rd < 0) {
			uart_sendf("WR-ERR read %zd\n", rd);
			(void)fs_close(&file);
			return;
		}
		if (rd == 0) {
			break;
		}
		read_total += (uint32_t)rd;
	}
	const uint32_t elapsed_ms = (uint32_t)(k_uptime_get() - start_ms);
	(void)fs_close(&file);
	uart_sendf("WR-READ-BENCH %s %u %u %u\n",
		   filename, read_total, elapsed_ms,
		   (uint32_t)sizeof(wired_fetch_chunk));
}

static void handle_wired_bench(uint32_t bytes)
{
	if (bytes == 0U) {
		uart_send_str("WR-ERR bad-bench-size\n");
		return;
	}

	for (size_t i = 0; i < sizeof(wired_fetch_chunk); i++) {
		wired_fetch_chunk[i] = (uint8_t)(i & 0xFF);
	}

	uart_sendf("WR-BENCH-BEGIN %u binary\n", bytes);
	uint32_t sent = 0;
	while (sent < bytes) {
		size_t n = sizeof(wired_fetch_chunk);
		if ((bytes - sent) < n) {
			n = bytes - sent;
		}
		uart_send(wired_fetch_chunk, n);
		sent += (uint32_t)n;
	}
	uart_sendf("\nWR-BENCH-END %u\n", sent);
}

static void wait_recording_state(bool recording)
{
	for (int i = 0; i < 40; i++) {
		if (wr_recorder_is_recording() == recording) {
			return;
		}
		k_sleep(K_MSEC(50));
	}
}

static void handle_line(const char *line)
{
	if (strcmp(line, "boot") == 0) {
		LOG_INF("'boot' received - entering UF2 bootloader");
		k_sleep(K_MSEC(50));
		NRF_POWER->GPREGRET = ADAFRUIT_UF2_MAGIC;
		sys_reboot(SYS_REBOOT_COLD);
	} else if (strcmp(line, "format-sd") == 0) {
		LOG_WRN("'format-sd' received - rebooting into SD formatter");
		k_sleep(K_MSEC(50));
		NRF_POWER->GPREGRET = WR_BOOT_FORMAT_SD_MAGIC;
		sys_reboot(SYS_REBOOT_COLD);
	} else if (strcmp(line, "wr-ping") == 0) {
		uart_send_str("WR-OK mozzy\n");
	} else if (strcmp(line, "wr-pause") == 0) {
		wr_recorder_pause();
		wait_recording_state(false);
		uart_send_str(wr_recorder_is_recording() ?
			"WR-ERR pause-timeout\n" : "WR-OK paused\n");
	} else if (strcmp(line, "wr-resume") == 0) {
		wr_recorder_resume();
		wait_recording_state(true);
		uart_send_str(wr_recorder_is_recording() ?
			"WR-OK recording\n" : "WR-ERR resume-timeout\n");
	} else if (strcmp(line, "wr-list") == 0) {
		handle_wired_list();
	} else if (strncmp(line, "wr-fetch ", 9) == 0) {
		char filename[BOOT_RX_BUF_LEN];
		uint32_t offset = 0;
		if (!parse_fetch_args(&line[9], filename, sizeof(filename), &offset)) {
			uart_send_str("WR-ERR bad-fetch-args\n");
			return;
		}
		handle_wired_fetch(filename, offset);
	} else if (strncmp(line, "wr-bench ", 9) == 0) {
		char *end = NULL;
		const unsigned long bytes = strtoul(&line[9], &end, 10);
		if (end == &line[9] || *end != '\0' || bytes > UINT32_MAX) {
			uart_send_str("WR-ERR bad-bench-args\n");
			return;
		}
		handle_wired_bench((uint32_t)bytes);
	} else if (strncmp(line, "wr-read-bench ", 14) == 0) {
		char filename[STORAGE_MAX_FILENAME + 1];
		uint32_t bytes = 0U;
		if (!parse_read_bench_args(&line[14], filename,
					   sizeof(filename), &bytes)) {
			uart_send_str("WR-ERR bad-read-bench-args\n");
			return;
		}
		handle_wired_read_bench(filename, bytes);
	}
}

static void boot_cmd_entry(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	char line[BOOT_RX_BUF_LEN];
	for (;;) {
		(void)k_msgq_get(&boot_cmd_queue, line, K_FOREVER);
		handle_line(line);
	}
}

static void boot_cmd_uart_cb(const struct device *dev, void *user_data)
{
	ARG_UNUSED(user_data);

	if (!uart_irq_update(dev)) {
		return;
	}

	if (uart_irq_tx_ready(dev) && wired_tx_data != NULL) {
		while (wired_tx_offset < wired_tx_len) {
			const int n = uart_fifo_fill(
				dev,
				&wired_tx_data[wired_tx_offset],
				wired_tx_len - wired_tx_offset);
			if (n <= 0) {
				break;
			}
			wired_tx_offset += (size_t)n;
		}
		if (wired_tx_offset >= wired_tx_len) {
			uart_irq_tx_disable(dev);
			wired_tx_data = NULL;
			wired_tx_len = 0U;
			wired_tx_offset = 0U;
			k_sem_give(&wired_tx_done);
		}
	}

	while (uart_irq_rx_ready(dev)) {
		uint8_t c;

		if (uart_fifo_read(dev, &c, 1) <= 0) {
			break;
		}

		if (c == '\n' || c == '\r') {
			rx_buf[rx_idx] = '\0';
			if (rx_idx > 0U) {
				if (strcmp(rx_buf, "wr-cancel") == 0) {
					wired_fetch_cancel_requested = true;
				} else {
					(void)k_msgq_put(&boot_cmd_queue, rx_buf,
							 K_NO_WAIT);
				}
			}
			rx_idx = 0;
		} else if (c == 0x03) {
			wired_fetch_cancel_requested = true;
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
	console_uart = console;
	if (!boot_cmd_thread_started) {
		k_thread_create(&boot_cmd_thread, boot_cmd_stack,
				K_THREAD_STACK_SIZEOF(boot_cmd_stack),
				boot_cmd_entry, NULL, NULL, NULL,
				BOOT_CMD_PRIORITY, 0, K_NO_WAIT);
		boot_cmd_thread_started = true;
	}
	int rc = uart_irq_callback_user_data_set(console, boot_cmd_uart_cb, NULL);
	if (rc) {
		LOG_WRN("uart_irq_callback_user_data_set: %d", rc);
		return rc;
	}
	uart_irq_rx_enable(console);
	LOG_INF("USB command listener armed (boot/format-sd/wr-pause/wr-list/wr-fetch)");
	return 0;
}
