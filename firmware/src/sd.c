/* SD card / FATFS bring-up.
 *
 * SD card is wired to spi2 via the board overlay (D2 SCK / D8 CS /
 * D9 MOSI / D10 MISO, 1 MHz). FATFS auto-mounts at /SD:.
 *
 * This module exposes:
 *   wr_sd_mount()   — mount the FS at /SD:
 *   wr_sd_ls()      — log directory listing
 *   wr_sd_selftest() — write+read a sample file to verify FS works
 */
#include "sd.h"

#include <ff.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/disk_access.h>

LOG_MODULE_REGISTER(wr_sd, LOG_LEVEL_INF);

#define DISK_DRIVE_NAME  "SD"
#define DISK_MOUNT_PT    "/SD:"
#define DISK_FATFS_PATH  "SD:"
#define SD_INIT_ATTEMPTS 5
#define SD_INIT_RETRY_DELAY_MS 750

static FATFS fat_fs;
static struct fs_mount_t mp = {
	.type = FS_FATFS,
	.fs_data = &fat_fs,
	.mnt_point = DISK_MOUNT_PT,
};

static bool mounted;

int wr_sd_mount(void)
{
	if (mounted) {
		return 0;
	}
	int rc = 0;
	for (uint32_t attempt = 1; attempt <= SD_INIT_ATTEMPTS; attempt++) {
		rc = disk_access_init(DISK_DRIVE_NAME);
		if (rc == 0) {
			break;
		}

		LOG_WRN("disk_access_init(%s) failed: %d (attempt %u/%u)",
			DISK_DRIVE_NAME, rc, attempt, SD_INIT_ATTEMPTS);
		k_msleep(SD_INIT_RETRY_DELAY_MS);
	}
	if (rc) {
		LOG_ERR("disk_access_init(%s) failed after retries: %d",
			DISK_DRIVE_NAME, rc);
		return rc;
	}

	uint64_t blocks = 0, sec_size = 0;
	(void)disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_GET_SECTOR_COUNT, &blocks);
	(void)disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_GET_SECTOR_SIZE, &sec_size);
	LOG_INF("SD raw: %llu sectors of %llu bytes (%llu MB)",
		blocks, sec_size, (blocks * sec_size) >> 20);

	rc = fs_mount(&mp);
	if (rc != FR_OK) {
		LOG_ERR("fs_mount(%s) failed: %d", DISK_MOUNT_PT, rc);
		return rc;
	}
	LOG_INF("SD mounted at %s", DISK_MOUNT_PT);
	mounted = true;
	return 0;
}

int wr_sd_ls(const char *path)
{
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int count = 0;

	fs_dir_t_init(&dirp);
	int rc = fs_opendir(&dirp, path);
	if (rc) {
		LOG_ERR("fs_opendir(%s) failed: %d", path, rc);
		return rc;
	}

	LOG_INF("Listing %s ...", path);
	for (;;) {
		rc = fs_readdir(&dirp, &entry);
		if (rc) {
			LOG_WRN("fs_readdir(%s) stopped after %d entries: %d",
				path, count, rc);
			break;
		}
		if (entry.name[0] == 0) {
			break;
		}
		if (entry.type == FS_DIR_ENTRY_DIR) {
			LOG_INF("  [DIR ] %s", entry.name);
		} else {
			LOG_INF("  [FILE] %s (%zu bytes)", entry.name, entry.size);
		}
		count++;
	}
	fs_closedir(&dirp);
	LOG_INF("  -- %d entries --", count);
	return count;
}

int wr_sd_selftest(void)
{
	const char *path = "/SD:/wr_test.txt";
	const char *payload = "voice-recorder bring-up self-test\n";
	const size_t plen = strlen(payload);
	struct fs_file_t f;
	uint8_t buf[64] = {0};

	fs_file_t_init(&f);

	int rc = fs_open(&f, path, FS_O_CREATE | FS_O_WRITE);
	if (rc) {
		LOG_ERR("selftest: fs_open(write) failed: %d", rc);
		return rc;
	}
	ssize_t wr = fs_write(&f, payload, plen);
	if (wr != (ssize_t)plen) {
		LOG_ERR("selftest: fs_write returned %zd (expected %zu)", wr, plen);
		fs_close(&f);
		return -EIO;
	}
	rc = fs_sync(&f);
	if (rc) {
		LOG_WRN("selftest: fs_sync returned %d", rc);
	}
	rc = fs_close(&f);
	if (rc) {
		LOG_WRN("selftest: fs_close returned %d", rc);
	}

	fs_file_t_init(&f);
	rc = fs_open(&f, path, FS_O_READ);
	if (rc) {
		LOG_ERR("selftest: fs_open(read) failed: %d", rc);
		return rc;
	}
	ssize_t rd = fs_read(&f, buf, sizeof(buf) - 1);
	fs_close(&f);
	if (rd != (ssize_t)plen) {
		LOG_ERR("selftest: fs_read returned %zd (expected %zu)", rd, plen);
		return -EIO;
	}
	if (memcmp(buf, payload, plen) != 0) {
		LOG_ERR("selftest: read content mismatch");
		return -EIO;
	}
	LOG_INF("selftest: write+read OK (%zu bytes round-trip)", plen);
	return 0;
}

int wr_sd_format_destructive(void)
{
	LOG_WRN("Formatting SD card at %s; all files will be erased",
		DISK_MOUNT_PT);

	if (mounted) {
		const int unmount_rc = fs_unmount(&mp);
		if (unmount_rc < 0) {
			LOG_ERR("fs_unmount(%s) failed: %d", DISK_MOUNT_PT,
				unmount_rc);
			return unmount_rc;
		}
		mounted = false;
		memset(&fat_fs, 0, sizeof(fat_fs));
		LOG_INF("SD unmounted for format");
	}

	int rc = disk_access_init(DISK_DRIVE_NAME);
	if (rc < 0) {
		LOG_ERR("disk_access_init(%s) before format failed: %d",
			DISK_DRIVE_NAME, rc);
		return rc;
	}

	MKFS_PARM mkfs_opt = {
		.fmt = FM_FAT32 | FM_SFD,
		.n_fat = 1,
		.align = 0,
		.n_root = CONFIG_FS_FATFS_MAX_ROOT_ENTRIES,
		.au_size = 0,
	};

	rc = fs_mkfs(FS_FATFS, (uintptr_t)DISK_FATFS_PATH, &mkfs_opt, 0);
	if (rc < 0) {
		LOG_ERR("fs_mkfs(%s) failed: %d", DISK_FATFS_PATH, rc);
		return rc;
	}
	LOG_INF("SD format complete");

	memset(&fat_fs, 0, sizeof(fat_fs));
	rc = fs_mount(&mp);
	if (rc < 0) {
		LOG_ERR("fs_mount(%s) after format failed: %d", DISK_MOUNT_PT,
			rc);
		return rc;
	}

	mounted = true;
	LOG_INF("SD remounted at %s after format", DISK_MOUNT_PT);
	return 0;
}
