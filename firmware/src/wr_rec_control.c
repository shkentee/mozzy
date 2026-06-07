/*
 * Recording on/off control GATT characteristic (spec §10 / D9).
 *
 * Lets the phone turn the device's SD recording on or off over BLE (the mic /
 * BLE audio stream keep running; only writing to the SD card is gated).
 *
 *   Service / Characteristic UUID: 19B10006-E8F2-537E-4F6C-D104768A1214
 *   WRITE [WITHOUT RESPONSE], 1 byte: 0 = pause recording, non-zero = resume.
 *   READ, 1 byte: current state (1 = recording, 0 = paused) so the app can
 *   reflect the real state on connect.
 *
 * Mirrors the app side: WrUuids.recControlChar. Zephyr allows multiple
 * BT_GATT_SERVICE_DEFINE across translation units, so this lives on its own.
 */

#include <stdint.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "wr_button.h"
#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_rec_control, LOG_LEVEL_INF);

/* Deep sleep is requested from the GATT write callback but run on the system
 * workqueue so the write response goes out before the device powers off. */
static void sleep_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	wr_button_request_sleep();
}
static K_WORK_DEFINE(sleep_work, sleep_work_handler);

#define WR_REC_CONTROL_UUID \
	BT_UUID_128_ENCODE(0x19B10006, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_rec_control_svc_uuid =
	BT_UUID_INIT_128(WR_REC_CONTROL_UUID);
static struct bt_uuid_128 wr_rec_control_char_uuid =
	BT_UUID_INIT_128(WR_REC_CONTROL_UUID);

static ssize_t wr_rec_control_read(struct bt_conn *conn,
				   const struct bt_gatt_attr *attr, void *buf,
				   uint16_t len, uint16_t offset)
{
	const uint8_t state = wr_recorder_is_recording() ? 1U : 0U;

	return bt_gatt_attr_read(conn, attr, buf, len, offset, &state,
				 sizeof(state));
}

static ssize_t wr_rec_control_write(struct bt_conn *conn,
				    const struct bt_gatt_attr *attr,
				    const void *buf, uint16_t len,
				    uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len < 1) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	const uint8_t v = ((const uint8_t *)buf)[0];

	if (v == 0U) {
		LOG_INF("recording control: pause");
		wr_recorder_pause();
	} else if (v == 1U) {
		LOG_INF("recording control: resume");
		wr_recorder_resume();
	} else {
		/* v >= 2: deep sleep. Defer to a work item so this GATT write
		 * returns its response before the device powers off. */
		LOG_INF("recording control: deep sleep requested");
		k_work_submit(&sleep_work);
	}

	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(wr_rec_control_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_rec_control_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_rec_control_char_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE |
				       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       wr_rec_control_read, wr_rec_control_write, NULL),
);
