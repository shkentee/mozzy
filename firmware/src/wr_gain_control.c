/*
 * Mic gain control GATT characteristic (D10).
 *
 * Lets the phone adjust the capture gain over BLE (the PDM mic is quiet, so a
 * software boost helps) without reflashing.
 *
 *   Service / Characteristic UUID: 19B10007-E8F2-537E-4F6C-D104768A1214
 *   READ  1 byte: current gain, Q4 fixed point (16 = 1.0x, 32 = 2.0x, ...).
 *   WRITE 1 byte: new gain (Q4); clamped to a sane range by the audio layer.
 *
 * Mirrors the app side: WrUuids.gainChar.
 */

#include <stdint.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>

#include "wr_audio.h"

LOG_MODULE_REGISTER(wr_gain_control, LOG_LEVEL_INF);

#define WR_GAIN_UUID \
	BT_UUID_128_ENCODE(0x19B10007, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_gain_svc_uuid = BT_UUID_INIT_128(WR_GAIN_UUID);
static struct bt_uuid_128 wr_gain_char_uuid = BT_UUID_INIT_128(WR_GAIN_UUID);

static ssize_t wr_gain_read(struct bt_conn *conn,
			    const struct bt_gatt_attr *attr, void *buf,
			    uint16_t len, uint16_t offset)
{
	const uint8_t g = wr_audio_get_gain_q4();

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

	wr_audio_set_gain_q4(((const uint8_t *)buf)[0]);
	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(wr_gain_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_gain_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_gain_char_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE |
				       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       wr_gain_read, wr_gain_write, NULL),
);
