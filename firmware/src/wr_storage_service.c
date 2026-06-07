#include "wr_storage_service.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_storage_service, LOG_LEVEL_INF);

#define STORAGE_SERVICE_UUID \
	BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xeabd, 0x2904, 0x2849adfeae43)
#define STORAGE_STREAM_UUID \
	BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xeabd, 0x2904, 0x2849adfeae43)
#define STORAGE_CONTROL_UUID \
	BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xeabd, 0x2904, 0x2849adfeae43)

#define STORAGE_MOUNT_POINT "/SD:"
#define STORAGE_MAX_FILENAME 63
#define STORAGE_MAX_PATH 80
#define STORAGE_NOTIFY_PAYLOAD_MAX 240
#define STORAGE_NOTIFY_MAX (1 + STORAGE_NOTIFY_PAYLOAD_MAX)
#define STORAGE_NOTIFY_RETRY_SLEEP_MS 10
#define STORAGE_NOTIFY_MAX_ENOMEM_RETRIES 500
#define STORAGE_NOTIFY_COMPLETE_TIMEOUT_MS 5000
/* Keep this many notifications in flight so the controller can pack several
 * into one connection event — far higher throughput than waiting for each to
 * complete (which serialised the transfer to one packet per interval). */
#define STORAGE_NOTIFY_PIPELINE 16
#define STORAGE_CMD_QUEUE_DEPTH 4
#define STORAGE_STACK_SIZE 4096
#define STORAGE_THREAD_PRIORITY 8

#define CMD_LIST 0x00
#define CMD_FETCH 0x01    /* [0x01][4B offset LE][4B length LE][filename]
			   * length 0 = to EOF. Read in bounded windows (e.g.
			   * 64 KB) for reliability — large single fetches can
			   * stall the BLE link. */
#define CMD_STATUS 0x02   /* [0x02]; reply NOTIF_STATUS with current file+size */
#define CMD_ABORT 0xFF

#define NOTIF_FILE_ENTRY 0x01
#define NOTIF_DATA 0x02
#define NOTIF_END 0x03
#define NOTIF_FILE_SIZE 0x04
#define NOTIF_STATUS 0x05 /* [4B committed size LE][current basename] */
#define NOTIF_ERROR 0xFF

struct storage_cmd {
	uint8_t type;
	uint32_t offset;
	uint32_t length; /* 0 = to EOF */
	char filename[STORAGE_MAX_FILENAME + 1];
};

static const struct bt_uuid_128 storage_service_uuid =
	BT_UUID_INIT_128(STORAGE_SERVICE_UUID);
static const struct bt_uuid_128 storage_stream_uuid =
	BT_UUID_INIT_128(STORAGE_STREAM_UUID);
static const struct bt_uuid_128 storage_control_uuid =
	BT_UUID_INIT_128(STORAGE_CONTROL_UUID);

static void storage_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t write_control(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			     const void *buf, uint16_t len, uint16_t offset,
			     uint8_t flags);

BT_GATT_SERVICE_DEFINE(wr_storage_svc,
	BT_GATT_PRIMARY_SERVICE(&storage_service_uuid.uuid),
	BT_GATT_CHARACTERISTIC(&storage_stream_uuid.uuid, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(storage_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&storage_control_uuid.uuid,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE, NULL, write_control, NULL),
);

K_MSGQ_DEFINE(storage_cmd_queue, sizeof(struct storage_cmd),
	      STORAGE_CMD_QUEUE_DEPTH, 4);
static K_THREAD_STACK_DEFINE(storage_stack, STORAGE_STACK_SIZE);
static struct k_thread storage_thread;
static atomic_t storage_notify_enabled;
static atomic_t storage_abort_requested;
static bool storage_started;

/* Counting semaphore = number of free in-flight slots; a ring of buffers backs
 * the params (freed FIFO, matching the in-order completion of notifications on
 * a single characteristic). */
K_SEM_DEFINE(storage_notify_credits, STORAGE_NOTIFY_PIPELINE,
	     STORAGE_NOTIFY_PIPELINE);
static uint8_t notify_pool[STORAGE_NOTIFY_PIPELINE][STORAGE_NOTIFY_MAX];
static uint32_t notify_idx;

static void storage_notify_complete(struct bt_conn *conn, void *user_data)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(user_data);

	/* A notification finished sending: free its in-flight slot. */
	k_sem_give(&storage_notify_credits);
}

static int storage_notify(uint8_t tag, const void *payload, size_t len)
{
	if (!atomic_get(&storage_notify_enabled)) {
		return 0;
	}
	if (len > STORAGE_NOTIFY_PAYLOAD_MAX) {
		return -EMSGSIZE;
	}

	/* Wait for a free in-flight slot (blocks only once PIPELINE are queued). */
	if (k_sem_take(&storage_notify_credits,
		       K_MSEC(STORAGE_NOTIFY_COMPLETE_TIMEOUT_MS)) < 0) {
		return -ETIMEDOUT;
	}

	uint8_t *buf = notify_pool[notify_idx % STORAGE_NOTIFY_PIPELINE];
	notify_idx++;
	buf[0] = tag;
	if (len > 0U && payload != NULL) {
		memcpy(&buf[1], payload, len);
	}

	struct bt_gatt_notify_params params = {
		.attr = &wr_storage_svc.attrs[1],
		.data = buf,
		.len = len + 1U,
		.func = storage_notify_complete,
		.user_data = NULL,
	};

	int rc;
	int enomem_retries = 0;
	do {
		rc = bt_gatt_notify_cb(NULL, &params);
		if (rc == -ENOMEM) {
			if (++enomem_retries > STORAGE_NOTIFY_MAX_ENOMEM_RETRIES) {
				LOG_WRN("storage notify ENOMEM gave up");
				k_sem_give(&storage_notify_credits);
				return -ENOMEM;
			}
			k_msleep(STORAGE_NOTIFY_RETRY_SLEEP_MS);
		}
	} while (rc == -ENOMEM);

	if (rc < 0) {
		/* No completion callback will fire — release the slot ourselves. */
		k_sem_give(&storage_notify_credits);
		return (rc == -ENOTCONN) ? 0 : rc;
	}

	/* Success: the slot is released by storage_notify_complete(). */
	return 0;
}

/* Block until all in-flight notifications have completed (buffers free, send
 * order flushed) before the next command reuses the pool. */
static void storage_notify_drain(void)
{
	for (int i = 0; i < STORAGE_NOTIFY_PIPELINE; i++) {
		(void)k_sem_take(&storage_notify_credits,
				 K_MSEC(STORAGE_NOTIFY_COMPLETE_TIMEOUT_MS));
	}
	for (int i = 0; i < STORAGE_NOTIFY_PIPELINE; i++) {
		k_sem_give(&storage_notify_credits);
	}
}

static void notify_end(void)
{
	(void)storage_notify(NOTIF_END, NULL, 0);
}

static void notify_error(void)
{
	(void)storage_notify(NOTIF_ERROR, NULL, 0);
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

static void handle_list(void)
{
	struct fs_dir_t dir;
	struct fs_dirent entry;

	fs_dir_t_init(&dir);
	int rc = fs_opendir(&dir, STORAGE_MOUNT_POINT);
	if (rc < 0) {
		LOG_WRN("storage LIST fs_opendir failed: %d", rc);
		notify_error();
		return;
	}

	uint32_t count = 0;
	for (;;) {
		if (atomic_get(&storage_abort_requested)) {
			break;
		}

		rc = fs_readdir(&dir, &entry);
		if (rc < 0) {
			LOG_WRN("storage LIST fs_readdir stopped after %u files: %d",
				count, rc);
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

		(void)storage_notify(NOTIF_FILE_ENTRY, entry.name,
				      strlen(entry.name));
		count++;
	}

	(void)fs_closedir(&dir);
	LOG_INF("storage LIST sent %u files", count);
	notify_end();
	storage_notify_drain();
}

static int build_path(char *path, size_t path_size, const char *filename)
{
	if (!filename_allowed(filename)) {
		return -EINVAL;
	}

	const int written = snprintf(path, path_size, STORAGE_MOUNT_POINT "/%s",
				     filename);
	if (written < 0 || written >= (int)path_size) {
		return -ENAMETOOLONG;
	}

	return 0;
}

static void handle_fetch(const char *filename, uint32_t offset, uint32_t length)
{
	char path[STORAGE_MAX_PATH];
	uint8_t chunk[STORAGE_NOTIFY_PAYLOAD_MAX];
	struct fs_file_t file;
	struct fs_dirent entry;
	uint32_t bytes_sent = 0;
	uint32_t chunks_sent = 0;
	const uint32_t want = length; /* 0 = to EOF */

	int rc = build_path(path, sizeof(path), filename);
	if (rc < 0) {
		LOG_WRN("storage FETCH rejected filename '%s': %d", filename, rc);
		notify_error();
		return;
	}
	/* The current (growing) recording file IS allowed here: the phone reads
	 * it incrementally by offset (omi-style). We open a separate read handle
	 * and read up to the committed (flushed) size reported by fs_stat. */
	if (!is_audio_file(filename)) {
		LOG_WRN("storage FETCH rejected non-audio file '%s'", filename);
		notify_error();
		return;
	}

	rc = fs_stat(path, &entry);
	if (rc < 0) {
		LOG_WRN("storage FETCH fs_stat(%s) failed: %d", path, rc);
		notify_error();
		return;
	}

	fs_file_t_init(&file);
	rc = fs_open(&file, path, FS_O_READ);
	if (rc < 0) {
		LOG_WRN("storage FETCH fs_open(%s) failed: %d", path, rc);
		notify_error();
		return;
	}

	if (offset > (uint32_t)entry.size) {
		offset = (uint32_t)entry.size;
	}
	if (offset > 0U) {
		rc = fs_seek(&file, (off_t)offset, FS_SEEK_SET);
		if (rc < 0) {
			LOG_WRN("storage FETCH fs_seek(%u) failed: %d", offset, rc);
			(void)fs_close(&file);
			notify_error();
			return;
		}
	}

	/* Report the total committed size so the phone knows the new high-water
	 * mark; it requested bytes [offset, size). */
	uint8_t size_payload[sizeof(uint32_t)];
	sys_put_le32((uint32_t)entry.size, size_payload);
	rc = storage_notify(NOTIF_FILE_SIZE, size_payload, sizeof(size_payload));
	if (rc < 0) {
		LOG_WRN("storage FETCH size notify failed: %d", rc);
		(void)fs_close(&file);
		notify_error();
		return;
	}

	for (;;) {
		if (atomic_get(&storage_abort_requested)) {
			LOG_INF("storage FETCH aborted after %u bytes", bytes_sent);
			(void)fs_close(&file);
			return;
		}

		if (want != 0U && bytes_sent >= want) {
			break; /* requested window fully sent */
		}

		size_t to_read = sizeof(chunk);
		if (want != 0U && (want - bytes_sent) < to_read) {
			to_read = want - bytes_sent;
		}

		const ssize_t rd = fs_read(&file, chunk, to_read);
		if (rd < 0) {
			LOG_WRN("storage FETCH fs_read(%s) failed: %zd", path, rd);
			(void)fs_close(&file);
			notify_error();
			return;
		}
		if (rd == 0) {
			break;
		}

		rc = storage_notify(NOTIF_DATA, chunk, (size_t)rd);
		if (rc < 0) {
			LOG_WRN("storage FETCH notify failed: %d", rc);
			(void)fs_close(&file);
			notify_error();
			return;
		}

		bytes_sent += (uint32_t)rd;
		chunks_sent++;
	}

	(void)fs_close(&file);
	notify_end();
	storage_notify_drain(); /* flush all in-flight before reusing the pool */
	LOG_INF("storage FETCH %s @%u sent %u bytes in %u chunks", filename,
		offset, bytes_sent, chunks_sent);
}

/* Report the current (growing) recording file and its committed size so the
 * phone can read it incrementally by offset. Payload: [4B size LE][basename].
 * Size 0 / empty name means "not recording / nothing to read yet". */
static void handle_status(void)
{
	char name[STORAGE_MAX_FILENAME + 1];
	uint8_t payload[sizeof(uint32_t) + STORAGE_MAX_FILENAME + 1];
	uint32_t size = 0;

	wr_recorder_current_basename(name, sizeof(name));

	if (name[0] != '\0') {
		char path[STORAGE_MAX_PATH];
		struct fs_dirent entry;

		if (build_path(path, sizeof(path), name) == 0 &&
		    fs_stat(path, &entry) == 0) {
			size = (uint32_t)entry.size;
		}
	}

	const size_t name_len = strlen(name);
	sys_put_le32(size, payload);
	memcpy(&payload[sizeof(uint32_t)], name, name_len);

	(void)storage_notify(NOTIF_STATUS, payload, sizeof(uint32_t) + name_len);
	storage_notify_drain();
	LOG_INF("storage STATUS %s size=%u", name[0] ? name : "(none)", size);
}

static void storage_entry(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	struct storage_cmd cmd;

	for (;;) {
		(void)k_msgq_get(&storage_cmd_queue, &cmd, K_FOREVER);

		switch (cmd.type) {
		case CMD_LIST:
			atomic_set(&storage_abort_requested, 0);
			handle_list();
			break;
		case CMD_FETCH:
			atomic_set(&storage_abort_requested, 0);
			handle_fetch(cmd.filename, cmd.offset, cmd.length);
			break;
		case CMD_STATUS:
			atomic_set(&storage_abort_requested, 0);
			handle_status();
			break;
		default:
			break;
		}
	}
}

static void storage_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);

	const bool enabled = value == BT_GATT_CCC_NOTIFY;
	atomic_set(&storage_notify_enabled, enabled ? 1 : 0);
	LOG_INF("Storage notifications %s", enabled ? "enabled" : "disabled");
}

static ssize_t write_control(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			     const void *buf, uint16_t len, uint16_t offset,
			     uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len == 0U || buf == NULL) {
		return len;
	}

	const uint8_t *data = buf;
	if (data[0] == CMD_ABORT) {
		atomic_set(&storage_abort_requested, 1);
		k_msgq_purge(&storage_cmd_queue);
		return len;
	}

	struct storage_cmd cmd = {
		.type = data[0],
		.offset = 0,
		.length = 0,
	};

	if (cmd.type == CMD_FETCH) {
		/* [0x01][4B offset LE][4B length LE][filename]. */
		if (len < 9U) {
			notify_error();
			return len;
		}
		cmd.offset = sys_get_le32(&data[1]);
		cmd.length = sys_get_le32(&data[5]);
		const size_t name_len = MIN((size_t)len - 9U,
					    (size_t)STORAGE_MAX_FILENAME);
		memcpy(cmd.filename, &data[9], name_len);
		cmd.filename[name_len] = '\0';
	} else if (cmd.type != CMD_LIST && cmd.type != CMD_STATUS) {
		notify_error();
		return len;
	}

	if (k_msgq_put(&storage_cmd_queue, &cmd, K_NO_WAIT) < 0) {
		LOG_WRN("storage command queue full");
		notify_error();
	}

	return len;
}

void wr_storage_service_start(void)
{
	if (storage_started) {
		return;
	}

	k_thread_create(&storage_thread, storage_stack,
			K_THREAD_STACK_SIZEOF(storage_stack),
			storage_entry, NULL, NULL, NULL,
			STORAGE_THREAD_PRIORITY, 0, K_NO_WAIT);
	storage_started = true;
}
