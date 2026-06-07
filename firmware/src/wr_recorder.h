#ifndef WR_RECORDER_H
#define WR_RECORDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Start writing Opus packets to a new file on the mounted SD card.
 * Returns 0 on success, negative errno on failure. */
int wr_recorder_start(void);

/* Codec packet callback. Safe to call from the codec thread; packets are
 * copied into an internal queue and written by a lower-priority worker. */
void wr_recorder_submit_opus(const uint8_t *packet, size_t len, void *user_data);

/* Provide the current wall-clock Unix time (seconds), as received from the
 * phone over the BLE time-sync characteristic. The device has no RTC, so this
 * is what gives a recording a real timestamp: the active recording is renamed
 * to its computed <epoch>.opus_sd start time. Safe to call from the BLE RX
 * thread (the actual rename happens later on the recorder thread). */
void wr_recorder_set_sync_time(uint64_t unix_secs);

/* True when filename is the file currently being appended by the recorder.
 * filename is a basename, e.g. "rec_0001.opus_sd". */
bool wr_recorder_is_current_file(const char *filename);

/* Copy the basename of the file currently being recorded into out (empty
 * string if not recording). Used by the storage service so the phone can read
 * the single growing session file incrementally by offset (omi-style). */
void wr_recorder_current_basename(char *out, size_t out_size);

/* Recording on/off (D9), driven from the phone over BLE. Pause flushes and
 * closes the current SD file; resume opens a fresh rec_NNNN file. Safe to call
 * from the BLE RX thread — the filesystem work runs on the recorder thread. */
void wr_recorder_pause(void);
void wr_recorder_resume(void);

/* True while the recorder is actively writing to the SD card. */
bool wr_recorder_is_recording(void);

#endif /* WR_RECORDER_H */
