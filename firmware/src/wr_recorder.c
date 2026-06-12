#include "wr_recorder.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "wr_codec.h"

LOG_MODULE_REGISTER(wr_recorder, LOG_LEVEL_INF);

#define RECORD_DIR "/SD:"
#define RECORD_PATH_MAX 32
#define RECORD_QUEUE_DEPTH 64
#define RECORD_WRITE_BUFFER_SIZE 1024
#define RECORD_STACK_SIZE 4096
#define RECORD_THREAD_PRIORITY 8
#define RECORD_IDLE_FLUSH_MS 250
#define RECORD_LOG_INTERVAL_PACKETS 100
#define RECORD_CHECKPOINT_INTERVAL_PACKETS 500
#define RECORD_MAX_STAT_ERRORS 8
/* Roll over to a new file on this interval so the phone can fetch + upload
 * ~10-minute chunks for near-real-time transcription. */
#define RECORD_ROTATE_MS (10 * 60 * 1000)

struct recorder_packet {
	uint8_t len;
	uint8_t data[WR_CODEC_MAX_PACKET_BYTES];
};

K_MSGQ_DEFINE(record_queue, sizeof(struct recorder_packet), RECORD_QUEUE_DEPTH, 4);
static K_THREAD_STACK_DEFINE(record_stack, RECORD_STACK_SIZE);
static struct k_thread record_thread;
static bool record_thread_started;

static struct fs_file_t record_file;
static char record_path[RECORD_PATH_MAX];
static uint8_t write_buffer[RECORD_WRITE_BUFFER_SIZE];
static size_t write_buffer_used;
static uint32_t written_packets;
static uint32_t written_bytes;
static uint32_t last_checkpoint_packet;
static atomic_t recording_active;
static atomic_t dropped_packets;
static atomic_t write_errors;

/* Time-sync (spec §10 / D7). The device has no RTC, so the phone writes the
 * current Unix time over BLE. Newly opened files use that wall-clock time in
 * their filename. If sync arrives while a file is already open, keep that file
 * open and leave its temporary rec_NNNN name; closing/renaming/reopening a live
 * SD file has proven too fragile on the XIAO + SPI-SD path. */
static int64_t file_open_uptime_ms;	/* k_uptime when current file opened */
static uint64_t sync_epoch_secs;	/* Unix time reported by the phone */
static int64_t sync_uptime_ms;		/* k_uptime captured at that report */
static atomic_t sync_pending;		/* BLE RX -> recorder thread signal */
static bool file_is_epoch_named;	/* current file already <epoch>-named */

/* Recording on/off (D9). The phone toggles SD recording over BLE; the actual
 * file close/open is deferred to the recorder thread (apply_pause_resume) so
 * regular filesystem access stays on one worker. */
static atomic_t pause_pending;		/* BLE RX -> recorder thread: stop */
static atomic_t resume_pending;		/* BLE RX -> recorder thread: start */
static bool time_synced;		/* phone has provided wall-clock time */

static int make_record_path(void)
{
	/* Once the phone has synced wall-clock time, name each file by its start
	 * epoch so chunks are timestamped (great for ordered transcription).
	 * Before sync, fall back to scanning for a free rec_NNNN name. */
	if (time_synced) {
		const int64_t delta_ms = k_uptime_get() - sync_uptime_ms;
		const uint64_t start = sync_epoch_secs +
			(delta_ms > 0 ? (uint64_t)(delta_ms / 1000) : 0);

		(void)snprintf(record_path, sizeof(record_path),
			       RECORD_DIR "/%010llu.opus_sd",
			       (unsigned long long)start);
		return 0;
	}

	uint32_t stat_errors = 0;
	int last_error = 0;

	for (uint32_t i = 1; i <= 9999; i++) {
		struct fs_dirent entry;
		(void)snprintf(record_path, sizeof(record_path),
			       RECORD_DIR "/rec_%04u.opus_sd", i);

		const int rc = fs_stat(record_path, &entry);
		if (rc == -ENOENT) {
			return 0;
		}
		if (rc < 0) {
			last_error = rc;
			stat_errors++;
			LOG_WRN("fs_stat(%s) failed: %d; trying next name",
				record_path, rc);
			if (stat_errors >= RECORD_MAX_STAT_ERRORS) {
				LOG_ERR("record filename scan stopped after %u stat errors",
					stat_errors);
				return last_error;
			}
			continue;
		}

		stat_errors = 0;
	}

	LOG_ERR("No free recording filename left");
	return -ENOSPC;
}

static int write_all(const uint8_t *data, size_t len)
{
	while (len > 0U) {
		const ssize_t written = fs_write(&record_file, data, len);
		if (written < 0) {
			return (int)written;
		}
		if (written == 0) {
			return -EIO;
		}

		data += written;
		len -= (size_t)written;
		written_bytes += (uint32_t)written;
	}

	return 0;
}

static int flush_write_buffer(void)
{
	if (write_buffer_used == 0U) {
		return 0;
	}

	const int rc = write_all(write_buffer, write_buffer_used);
	if (rc < 0) {
		atomic_inc(&write_errors);
		LOG_ERR("record write failed: %d", rc);
		return rc;
	}

	write_buffer_used = 0U;
	return 0;
}

static int append_packet(const struct recorder_packet *packet)
{
	const size_t record_len = sizeof(uint8_t) + packet->len;

	if (record_len > sizeof(write_buffer)) {
		return -EMSGSIZE;
	}

	if ((write_buffer_used + record_len) > sizeof(write_buffer)) {
		const int rc = flush_write_buffer();
		if (rc < 0) {
			return rc;
		}
	}

	write_buffer[write_buffer_used] = packet->len;
	write_buffer_used += sizeof(uint8_t);
	memcpy(&write_buffer[write_buffer_used], packet->data, packet->len);
	write_buffer_used += packet->len;

	return 0;
}

static int checkpoint_file(void)
{
	const int flush_rc = flush_write_buffer();
	if (flush_rc < 0) {
		return flush_rc;
	}

	const int sync_rc = fs_sync(&record_file);
	if (sync_rc < 0) {
		atomic_inc(&write_errors);
		LOG_WRN("record fs_sync returned %d", sync_rc);
	}

	return 0;
}

static void maybe_checkpoint_file(void)
{
	if (written_packets == 0U ||
	    (written_packets % RECORD_CHECKPOINT_INTERVAL_PACKETS) != 0U ||
	    last_checkpoint_packet == written_packets) {
		return;
	}

	const int rc = checkpoint_file();
	if (rc < 0) {
		return;
	}

	last_checkpoint_packet = written_packets;
	LOG_DBG("record checkpoint packets=%u bytes=%u", written_packets,
		written_bytes);
}

/* Apply a pending time-sync. Do not rename the active file anymore: keeping
 * the file open is more important than making the first file pretty. The next
 * recording session will get an epoch filename because time_synced is set. */
static void apply_sync_rename(void)
{
	if (!atomic_cas(&sync_pending, 1, 0)) {
		return;
	}
	if (file_is_epoch_named) {
		return;
	}

	file_is_epoch_named = true;
	LOG_INF("time sync received; keeping active file open as %s", record_path);
}

/* Open a fresh recording file and reset per-file state. Shared by start,
 * resume, and rotation so the open/reset sequence stays consistent. Must run
 * on the recorder thread (or before it starts), keeping FS access single-
 * threaded. */
static int open_new_record_file(void)
{
	int rc = make_record_path();

	if (rc < 0) {
		return rc;
	}

	fs_file_t_init(&record_file);
	rc = fs_open(&record_file, record_path, FS_O_CREATE | FS_O_WRITE);
	if (rc < 0) {
		LOG_ERR("fs_open(%s) failed: %d", record_path, rc);
		return rc;
	}

	k_msgq_purge(&record_queue);
	write_buffer_used = 0U;
	written_packets = 0U;
	written_bytes = 0U;
	last_checkpoint_packet = 0U;
	file_open_uptime_ms = k_uptime_get();
	/* Named by epoch when time is known -> already final; otherwise rec_NNNN
	 * stays open under that temporary name until the session ends. */
	file_is_epoch_named = time_synced;
	atomic_set(&sync_pending, 0);
	return 0;
}

/* File rotation is DISABLED: we use the omi-style single-file model. The
 * device records to one growing file per session; the phone reads it
 * incrementally by byte offset (CMD_STATUS + offset CMD_FETCH) instead of
 * fetching many ~10-minute chunk files. This keeps the device file count at
 * one per session. Kept as a no-op so the recorder loop is unchanged. */
static void maybe_rotate_file(void)
{
	(void)file_open_uptime_ms;
}

/* Apply a pending recording on/off request. Runs on the recorder thread so
 * file open/close stays single-threaded, reusing the same flush/close and
 * make_record_path/open sequence as the checkpoint and start paths. Pausing
 * closes the current file (keeping what was recorded); resuming opens a fresh
 * file. */
static void apply_pause_resume(void)
{
	if (atomic_cas(&pause_pending, 1, 0) && atomic_get(&recording_active)) {
		(void)flush_write_buffer();
		const int rc = fs_close(&record_file);

		if (rc < 0) {
			LOG_WRN("pause: fs_close returned %d", rc);
		}
		atomic_set(&recording_active, 0);
		LOG_INF("recording paused");
	}

	if (atomic_cas(&resume_pending, 1, 0) && !atomic_get(&recording_active)) {
		if (open_new_record_file() < 0) {
			LOG_ERR("resume: failed to open new file");
			return;
		}
		atomic_set(&recording_active, 1);
		LOG_INF("recording resumed -> %s", record_path);
	}
}

static void record_entry(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	struct recorder_packet packet;

	for (;;) {
		const int rc = k_msgq_get(&record_queue, &packet,
					  K_MSEC(RECORD_IDLE_FLUSH_MS));

		apply_pause_resume();

		if (rc == -EAGAIN) {
			if (atomic_get(&recording_active)) {
				(void)flush_write_buffer();
			}
			continue;
		}
		if (rc < 0) {
			continue;
		}
		if (!atomic_get(&recording_active)) {
			continue;
		}

		apply_sync_rename();

		if (append_packet(&packet) < 0) {
			continue;
		}

		written_packets++;
		if ((written_packets % RECORD_LOG_INTERVAL_PACKETS) == 0U) {
			LOG_DBG("recorded packets=%u bytes=%u drop=%ld err=%ld file=%s",
				written_packets, written_bytes,
				atomic_get(&dropped_packets),
				atomic_get(&write_errors), record_path);
		}
		maybe_checkpoint_file();
		maybe_rotate_file();
	}
}

static void start_record_thread_once(void)
{
	if (record_thread_started) {
		return;
	}

	k_thread_create(&record_thread, record_stack,
			K_THREAD_STACK_SIZEOF(record_stack),
			record_entry, NULL, NULL, NULL,
			RECORD_THREAD_PRIORITY, 0, K_NO_WAIT);
	record_thread_started = true;
}

int wr_recorder_start(void)
{
	if (atomic_get(&recording_active)) {
		return 0;
	}

	atomic_set(&dropped_packets, 0);
	atomic_set(&write_errors, 0);

	const int rc = open_new_record_file();

	if (rc < 0) {
		start_record_thread_once();
		return rc;
	}

	atomic_set(&recording_active, 1);
	start_record_thread_once();

	LOG_INF("Recording Opus packets to %s", record_path);
	return 0;
}

void wr_recorder_submit_opus(const uint8_t *packet, size_t len, void *user_data)
{
	ARG_UNUSED(user_data);

	if (!atomic_get(&recording_active) || packet == NULL || len == 0U) {
		return;
	}
	if (len > UINT8_MAX) {
		atomic_inc(&dropped_packets);
		return;
	}

	struct recorder_packet queued = {
		.len = (uint8_t)len,
	};
	memcpy(queued.data, packet, len);

	if (k_msgq_put(&record_queue, &queued, K_NO_WAIT) < 0) {
		atomic_inc(&dropped_packets);
	}
}

void wr_recorder_set_sync_time(uint64_t unix_secs)
{
	/* Record the phone's wall-clock and the uptime at which we learned it.
	 * Future files use these values to build epoch filenames. If a rec_NNNN
	 * file is already open, signal the recorder thread only to mark this file
	 * handled without closing it. */
	sync_epoch_secs = unix_secs;
	sync_uptime_ms = k_uptime_get();
	time_synced = true;

	if (atomic_get(&recording_active) && !file_is_epoch_named) {
		atomic_set(&sync_pending, 1);
	}
}

void wr_recorder_pause(void)
{
	/* Signalled from the BLE RX thread; the recorder thread does the close. */
	atomic_set(&resume_pending, 0);
	atomic_set(&pause_pending, 1);
}

void wr_recorder_resume(void)
{
	atomic_set(&pause_pending, 0);
	atomic_set(&resume_pending, 1);
}

bool wr_recorder_is_recording(void)
{
	return atomic_get(&recording_active) != 0;
}

bool wr_recorder_is_current_file(const char *filename)
{
	if (!atomic_get(&recording_active) || filename == NULL) {
		return false;
	}

	const char *base = strrchr(record_path, '/');
	base = base ? base + 1 : record_path;

	return strcmp(base, filename) == 0;
}

void wr_recorder_current_basename(char *out, size_t out_size)
{
	if (out == NULL || out_size == 0U) {
		return;
	}
	out[0] = '\0';
	if (!atomic_get(&recording_active)) {
		return;
	}

	const char *base = strrchr(record_path, '/');
	base = base ? base + 1 : record_path;
	strncpy(out, base, out_size - 1);
	out[out_size - 1] = '\0';
}
