#ifndef WR_SD_H
#define WR_SD_H

#include <stddef.h>
#include <stdint.h>

/* Mount the SD card at /SD:.
 * Returns 0 on success, negative errno on failure. */
int wr_sd_mount(void);

/* Diagnostic: log directory listing of /SD:.
 * Returns count of entries, or negative errno. */
int wr_sd_ls(const char *path);

/* Bring-up self-test: write a known file, read it back, verify content.
 * Returns 0 on success, negative errno on failure. */
int wr_sd_selftest(void);

/* Destructively format the SD card as FAT, remount it at /SD:, and leave it
 * ready for normal recorder/storage use. Returns 0 on success. */
int wr_sd_format_destructive(void);

#endif /* WR_SD_H */
