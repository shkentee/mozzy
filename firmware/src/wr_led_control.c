/*
 * LED settings GATT characteristic.
 *
 * Service / Characteristic UUID: 19B10013-E8F2-537E-4F6C-D104768A1214
 * READ/WRITE 4 bytes:
 *   [0] mode: 0=off, 1=breathe
 *   [1] brightness peak duty percent: 1..30
 *   [2] interval seconds: 1..10
 *   [3] reserved, currently 0
 */

#include <stdint.h>

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "led.h"

LOG_MODULE_REGISTER(wr_led_control, LOG_LEVEL_INF);

#define WR_LED_SETTINGS_UUID \
	BT_UUID_128_ENCODE(0x19B10013, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_led_settings_svc_uuid =
	BT_UUID_INIT_128(WR_LED_SETTINGS_UUID);
static struct bt_uuid_128 wr_led_settings_char_uuid =
	BT_UUID_INIT_128(WR_LED_SETTINGS_UUID);

static void settings_to_payload(uint8_t out[4])
{
	struct wr_led_settings s;

	wr_led_get_settings(&s);
	out[0] = s.mode;
	out[1] = s.brightness_pct;
	out[2] = s.interval_sec;
	out[3] = 0U;
}

static ssize_t wr_led_settings_read(struct bt_conn *conn,
				    const struct bt_gatt_attr *attr, void *buf,
				    uint16_t len, uint16_t offset)
{
	uint8_t payload[4];

	ARG_UNUSED(attr);
	settings_to_payload(payload);
	return bt_gatt_attr_read(conn, attr, buf, len, offset, payload,
				 sizeof(payload));
}

static ssize_t wr_led_settings_write(struct bt_conn *conn,
				     const struct bt_gatt_attr *attr,
				     const void *buf, uint16_t len,
				     uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len < 3U) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	const uint8_t *payload = (const uint8_t *)buf;

	wr_led_apply_settings(payload[0], payload[1], payload[2]);
	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(wr_led_settings_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_led_settings_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_led_settings_char_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE |
				       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       wr_led_settings_read, wr_led_settings_write,
			       NULL),
);
