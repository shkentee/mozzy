/*
 * Mic gain control GATT characteristics (D10).
 *
 * Lets the phone adjust the capture gain over BLE. The app-facing endpoint
 * follows the current OMI settings service and maps levels to Nordic PDM gain.
 *
 * OMI-compatible app-facing endpoint:
 *   Service UUID:        19B10010-E8F2-537E-4F6C-D104768A1214
 *   Characteristic UUID: 19B10012-E8F2-537E-4F6C-D104768A1214
 *   READ/WRITE 1 byte: gain level 0..8
 *     0 Mute, 1 -20dB, 2 -10dB, 3 +0dB, 4 +6dB,
 *     5 +10dB, 6 +20dB, 7 +30dB, 8 +40dB.
 *
 * mojizo diagnostic endpoint:
 *   Service / Characteristic UUID: 19B10007-E8F2-537E-4F6C-D104768A1214
 *   READ  1 byte: current Nordic PDM gain byte.
 *   WRITE 1 byte: new Nordic PDM gain byte.
 */

#include <stdint.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "wr_audio.h"

LOG_MODULE_REGISTER(wr_gain_control, LOG_LEVEL_INF);

#define WR_GAIN_UUID \
	BT_UUID_128_ENCODE(0x19B10007, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define OMI_SETTINGS_UUID \
	BT_UUID_128_ENCODE(0x19B10010, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)
#define OMI_MIC_GAIN_UUID \
	BT_UUID_128_ENCODE(0x19B10012, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_gain_svc_uuid = BT_UUID_INIT_128(WR_GAIN_UUID);
static struct bt_uuid_128 wr_gain_char_uuid = BT_UUID_INIT_128(WR_GAIN_UUID);
static struct bt_uuid_128 omi_settings_svc_uuid =
	BT_UUID_INIT_128(OMI_SETTINGS_UUID);
static struct bt_uuid_128 omi_mic_gain_char_uuid =
	BT_UUID_INIT_128(OMI_MIC_GAIN_UUID);

/* OMI-style 0..8 dB levels, with DevKit2's fixed MIC_GAIN 64 as level 6. */
#define OMI_MIC_GAIN_DEFAULT_LEVEL 6U

static const uint8_t pdm_gain_by_omi_level[] = {
	0x00, /* 0: Mute */
	0x14, /* 1: -20dB */
	0x1E, /* 2: -10dB */
	0x28, /* 3: +0dB */
	0x2E, /* 4: +6dB */
	0x32, /* 5: +10dB */
	0x40, /* 6: +20dB, DevKit2 MIC_GAIN 64 */
	0x46, /* 7: +30dB */
	0x50, /* 8: +40dB */
};

static const char *const gain_label_by_omi_level[] = {
	"Mute", "-20dB", "-10dB", "+0dB", "+6dB",
	"+10dB", "+20dB", "+30dB", "+40dB",
};

static uint8_t current_omi_gain_level = OMI_MIC_GAIN_DEFAULT_LEVEL;

static uint8_t omi_level_to_pdm_gain(uint8_t level)
{
	if (level >= ARRAY_SIZE(pdm_gain_by_omi_level)) {
		level = ARRAY_SIZE(pdm_gain_by_omi_level) - 1U;
	}
	return pdm_gain_by_omi_level[level];
}

static uint8_t pdm_gain_to_omi_level(uint8_t gain)
{
	uint8_t best = 0;
	uint8_t best_delta = UINT8_MAX;

	for (uint8_t i = 0; i < ARRAY_SIZE(pdm_gain_by_omi_level); i++) {
		const uint8_t pdm_gain = pdm_gain_by_omi_level[i];
		const uint8_t delta =
			gain > pdm_gain ? gain - pdm_gain : pdm_gain - gain;

		if (delta < best_delta) {
			best = i;
			best_delta = delta;
		}
	}

	return best;
}

static ssize_t wr_gain_read(struct bt_conn *conn,
			    const struct bt_gatt_attr *attr, void *buf,
			    uint16_t len, uint16_t offset)
{
	const uint8_t g = wr_audio_get_mic_gain();

	return bt_gatt_attr_read(conn, attr, buf, len, offset, &g, sizeof(g));
}

static ssize_t wr_gain_write(struct bt_conn *conn,
			     const struct bt_gatt_attr *attr, const void *buf,
			     uint16_t len, uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len < 1) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	const uint8_t gain = ((const uint8_t *)buf)[0];

	current_omi_gain_level = pdm_gain_to_omi_level(gain);
	wr_audio_set_mic_gain(gain);
	return (ssize_t)len;
}

static ssize_t omi_gain_read(struct bt_conn *conn,
			     const struct bt_gatt_attr *attr, void *buf,
			     uint16_t len, uint16_t offset)
{
	const uint8_t level = current_omi_gain_level;

	return bt_gatt_attr_read(conn, attr, buf, len, offset, &level,
				 sizeof(level));
}

static ssize_t omi_gain_write(struct bt_conn *conn,
			      const struct bt_gatt_attr *attr, const void *buf,
			      uint16_t len, uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len < 1) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	uint8_t level = ((const uint8_t *)buf)[0];
	if (level >= ARRAY_SIZE(pdm_gain_by_omi_level)) {
		level = ARRAY_SIZE(pdm_gain_by_omi_level) - 1U;
	}
	const uint8_t gain = omi_level_to_pdm_gain(level);

	current_omi_gain_level = level;
	LOG_INF("OMI mic gain level %u (%s) -> pdm 0x%02x",
		(unsigned int)level, gain_label_by_omi_level[level],
		(unsigned int)gain);
	wr_audio_set_mic_gain(gain);
	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(omi_settings_svc,
	BT_GATT_PRIMARY_SERVICE(&omi_settings_svc_uuid),
	BT_GATT_CHARACTERISTIC(&omi_mic_gain_char_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE |
				       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       omi_gain_read, omi_gain_write, NULL),
);

BT_GATT_SERVICE_DEFINE(wr_gain_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_gain_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_gain_char_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE |
				       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       wr_gain_read, wr_gain_write, NULL),
);
