/* Battery voltage sensing for XIAO BLE Sense.
 *
 * The XIAO nRF52840 reads cell voltage on AIN7 (P0.31) through a ~1/3
 * resistor divider (1 MOhm : 0.51 MOhm). P0.14 (READ_BAT_ENABLE) gates the
 * divider: it MUST be driven LOW to read, and per Seeed it must NOT be left
 * HIGH — with the divider disengaged, P0.31 can exceed its 3.6 V limit
 * (notably while charging) and be damaged. We therefore drive P0.14 LOW at
 * init and keep it there (~2.3 uA), sample AIN7 periodically, and publish the
 * result via the BLE Battery Service.
 */
#include "wr_battery.h"

#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include <stdio.h>

LOG_MODULE_REGISTER(wr_battery, LOG_LEVEL_INF);

/* Vbat = Vadc * (full / output) = Vadc * 1510k / 510k (~x2.96). */
#define BATT_DIV_FULL_OHM   1510000U
#define BATT_DIV_OUTPUT_OHM  510000U

/* READ_BAT_ENABLE: P0.14, driven low (divider engaged) and held there. */
#define BATT_ENABLE_PORT DT_NODELABEL(gpio0)
#define BATT_ENABLE_PIN  14

/* 10 s (was 30 s): finer mV time-series so dV/dt power measurements over a
 * few minutes are precise. ADC cost of the extra samples is negligible. */
#define BATT_SAMPLE_INTERVAL_MS 10000
#define BATT_FIRST_SAMPLE_MS    3000
/* 4 KB (was 1 KB): the battlog SD writer calls FatFs fs_open/write/rename from
 * this thread, which overflows a 1 KB stack -> hard fault -> reboot loop. */
#define BATT_STACK_SIZE         4096
#define BATT_THREAD_PRIORITY    10

/* Raw cell mV exposed over BLE (read) for precise power measurement — much
 * finer than the 1%-quantised standard Battery Service level.
 *   Characteristic UUID: 19B10008-E8F2-537E-4F6C-D104768A1214, READ 2 bytes
 *   (uint16 little-endian millivolts). Updated every BATT_SAMPLE_INTERVAL_MS. */
#define WR_BATT_MV_UUID \
	BT_UUID_128_ENCODE(0x19B10008, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 batt_mv_svc_uuid = BT_UUID_INIT_128(WR_BATT_MV_UUID);
static struct bt_uuid_128 batt_mv_char_uuid = BT_UUID_INIT_128(WR_BATT_MV_UUID);

/* Latest sampled cell mV. 16-bit aligned access is atomic on Cortex-M; the
 * battery thread writes it and the BLE thread reads it. */
static uint16_t last_mv;

static ssize_t batt_mv_read(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			    void *buf, uint16_t len, uint16_t offset)
{
	uint8_t le[2];

	sys_put_le16(last_mv, le);
	return bt_gatt_attr_read(conn, attr, buf, len, offset, le, sizeof(le));
}

BT_GATT_SERVICE_DEFINE(wr_batt_mv_svc,
	BT_GATT_PRIMARY_SERVICE(&batt_mv_svc_uuid),
	BT_GATT_CHARACTERISTIC(&batt_mv_char_uuid.uuid, BT_GATT_CHRC_READ,
			       BT_GATT_PERM_READ, batt_mv_read, NULL, NULL),
);

/* --- Battery mV logger to SD (measurement instrument) --------------------
 * Logs "uptime_ms,mv,pct" every sample to /SD:/battlog.csv. The point is to
 * measure low-current states (e.g. VAD listening) WITHOUT any BLE polling —
 * BLE wake-ups sag the cell ~15 mV and swamp the slow drop. Samples are
 * buffered in RAM and flushed every BATTLOG_FLUSH_N samples to keep SD writes
 * sparse (so they barely add to the floor being measured). The file is reset
 * once per boot. Retrieve afterwards via the BLE storage-fetch service. */
/* .opus_sd suffix so the BLE storage-fetch filter (is_audio_file) allows it;
 * the content is plain CSV text. */
#define BATTLOG_PATH    "/SD:/battlog.opus_sd"
#define BATTLOG_FLUSH_N 12      /* ~120 s of samples per SD write */
#define BATTLOG_BUF_SZ  512

static char battlog_buf[BATTLOG_BUF_SZ];
static size_t battlog_len;
static uint8_t battlog_count;
static bool battlog_fresh = true;

static void battlog_flush(void)
{
	if (battlog_len == 0U) {
		return;
	}

	if (battlog_fresh) {
		/* One-time salvage: an earlier build logged to battlog.csv, which the
		 * BLE storage-fetch filter rejects (.opus_sd only). Rename it to a
		 * fetchable name so that data can still be pulled. Harmless if absent. */
		(void)fs_rename("/SD:/battlog.csv", "/SD:/battlog_prev.opus_sd");
		(void)fs_unlink(BATTLOG_PATH);   /* start a clean log this boot */
		battlog_fresh = false;
	}

	struct fs_file_t f;

	fs_file_t_init(&f);
	int rc = fs_open(&f, BATTLOG_PATH, FS_O_CREATE | FS_O_WRITE | FS_O_APPEND);
	if (rc < 0) {
		LOG_WRN("battlog fs_open failed: %d", rc);
		battlog_len = 0U;            /* drop; SD may not be mounted yet */
		battlog_fresh = true;
		return;
	}
	(void)fs_write(&f, battlog_buf, battlog_len);
	(void)fs_close(&f);
	battlog_len = 0U;
}

static void battlog_record(uint32_t t_ms, uint16_t mv, uint8_t pct)
{
	int n = snprintf(battlog_buf + battlog_len, BATTLOG_BUF_SZ - battlog_len,
			 "%u,%u,%u\n", t_ms, mv, pct);
	if (n <= 0 || (size_t)n >= BATTLOG_BUF_SZ - battlog_len) {
		battlog_flush();
		n = snprintf(battlog_buf, BATTLOG_BUF_SZ, "%u,%u,%u\n", t_ms, mv, pct);
		battlog_len = (n > 0) ? (size_t)n : 0U;
	} else {
		battlog_len += (size_t)n;
	}

	if (++battlog_count >= BATTLOG_FLUSH_N) {
		battlog_count = 0U;
		battlog_flush();
	}
}

static const struct adc_dt_spec vbatt =
	ADC_DT_SPEC_GET_BY_IDX(DT_PATH(zephyr_user), 0);

static K_THREAD_STACK_DEFINE(batt_stack, BATT_STACK_SIZE);
static struct k_thread batt_thread;

/* Single-cell Li-Po discharge curve, sorted high voltage to low. */
struct batt_point {
	uint16_t mv;
	uint8_t pct;
};

static const struct batt_point batt_curve[] = {
	{4200, 100}, {4100, 95}, {4000, 87}, {3900, 76}, {3800, 62},
	{3700, 47}, {3650, 38}, {3600, 28}, {3500, 16}, {3400, 7},
	{3300, 2}, {3000, 0},
};

static uint8_t batt_mv_to_pct(uint16_t mv)
{
	if (mv >= batt_curve[0].mv) {
		return batt_curve[0].pct;
	}
	for (size_t i = 1; i < ARRAY_SIZE(batt_curve); i++) {
		if (mv >= batt_curve[i].mv) {
			const struct batt_point *hi = &batt_curve[i - 1];
			const struct batt_point *lo = &batt_curve[i];

			/* Linear interpolation between lo and hi. */
			return lo->pct + (uint32_t)(hi->pct - lo->pct) *
				(mv - lo->mv) / (hi->mv - lo->mv);
		}
	}
	return batt_curve[ARRAY_SIZE(batt_curve) - 1].pct;
}

static int batt_sample_mv(uint16_t *out_mv)
{
	int16_t raw = 0;
	struct adc_sequence seq = {
		.buffer = &raw,
		.buffer_size = sizeof(raw),
	};

	int rc = adc_sequence_init_dt(&vbatt, &seq);
	if (rc < 0) {
		return rc;
	}
	seq.calibrate = true;

	rc = adc_read_dt(&vbatt, &seq);
	if (rc < 0) {
		return rc;
	}

	int32_t mv = raw;
	rc = adc_raw_to_millivolts_dt(&vbatt, &mv);
	if (rc < 0) {
		return rc;
	}
	if (mv < 0) {
		mv = 0;
	}

	*out_mv = (uint16_t)((uint64_t)mv * BATT_DIV_FULL_OHM / BATT_DIV_OUTPUT_OHM);
	return 0;
}

static void batt_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	/* Let BLE / the host settle before the first publish. */
	k_msleep(BATT_FIRST_SAMPLE_MS);

	for (;;) {
		uint16_t mv = 0;
		const int rc = batt_sample_mv(&mv);

		if (rc == 0) {
			const uint8_t pct = batt_mv_to_pct(mv);

			last_mv = mv;
			battlog_record(k_uptime_get_32(), mv, pct);
			LOG_INF("battery: %u mV -> %u%%", mv, pct);
			(void)bt_bas_set_battery_level(pct);
		} else {
			LOG_WRN("battery sample failed: %d", rc);
		}
		k_msleep(BATT_SAMPLE_INTERVAL_MS);
	}
}

int wr_battery_init(void)
{
	const struct device *en_port = DEVICE_DT_GET(BATT_ENABLE_PORT);

	if (!device_is_ready(en_port)) {
		LOG_ERR("battery enable GPIO port not ready");
		return -ENODEV;
	}

	/* Drive P0.14 low and keep it low: divider engaged, P0.31 kept safe. */
	int rc = gpio_pin_configure(en_port, BATT_ENABLE_PIN, GPIO_OUTPUT_INACTIVE);
	if (rc < 0) {
		LOG_ERR("battery enable GPIO config failed: %d", rc);
		return rc;
	}

	if (!adc_is_ready_dt(&vbatt)) {
		LOG_ERR("battery ADC not ready");
		return -ENODEV;
	}
	rc = adc_channel_setup_dt(&vbatt);
	if (rc < 0) {
		LOG_ERR("battery ADC channel setup failed: %d", rc);
		return rc;
	}

	k_thread_create(&batt_thread, batt_stack, K_THREAD_STACK_SIZEOF(batt_stack),
			batt_entry, NULL, NULL, NULL, BATT_THREAD_PRIORITY, 0,
			K_NO_WAIT);
	LOG_INF("battery monitor started (AIN7/P0.31, P0.14 held low)");
	return 0;
}
