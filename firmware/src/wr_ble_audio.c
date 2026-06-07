#include "wr_ble_audio.h"

#include <errno.h>
#include <stdbool.h>
#include <string.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include "config.h"
#include "wr_codec.h"

LOG_MODULE_REGISTER(wr_ble_audio, LOG_LEVEL_INF);

#define WR_AUDIO_SERVICE_UUID \
	BT_UUID_128_ENCODE(0x19b10000, 0xe8f2, 0x537e, 0x4f6c, 0xd104768a1214)
#define WR_AUDIO_STREAM_UUID \
	BT_UUID_128_ENCODE(0x19b10001, 0xe8f2, 0x537e, 0x4f6c, 0xd104768a1214)
#define WR_AUDIO_CODEC_UUID \
	BT_UUID_128_ENCODE(0x19b10002, 0xe8f2, 0x537e, 0x4f6c, 0xd104768a1214)

#define AUDIO_NOTIFY_HEADER_SIZE 3
#define AUDIO_NOTIFY_MAX_PAYLOAD 200
#define AUDIO_NOTIFY_MAX_SIZE (AUDIO_NOTIFY_HEADER_SIZE + AUDIO_NOTIFY_MAX_PAYLOAD)
#define AUDIO_LOG_INTERVAL_FRAMES 500

static const struct bt_uuid_128 audio_service_uuid =
	BT_UUID_INIT_128(WR_AUDIO_SERVICE_UUID);
static const struct bt_uuid_128 audio_stream_uuid =
	BT_UUID_INIT_128(WR_AUDIO_STREAM_UUID);
static const struct bt_uuid_128 audio_codec_uuid =
	BT_UUID_INIT_128(WR_AUDIO_CODEC_UUID);

static atomic_t audio_notify_enabled;
static atomic_t audio_frames_sent;
static atomic_t audio_notify_errors;
static atomic_t audio_notify_dropped;
static uint16_t notify_id;
static const uint8_t codec_id = CODEC_OPUS;

static void audio_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);

	const bool enabled = value == BT_GATT_CCC_NOTIFY;
	atomic_set(&audio_notify_enabled, enabled ? 1 : 0);
	LOG_INF("Live audio notifications %s", enabled ? "enabled" : "disabled");
}

static ssize_t read_codec_id(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			     void *buf, uint16_t len, uint16_t offset)
{
	const uint8_t *value = attr->user_data;

	return bt_gatt_attr_read(conn, attr, buf, len, offset, value,
				 sizeof(codec_id));
}

BT_GATT_SERVICE_DEFINE(wr_ble_audio_svc,
	BT_GATT_PRIMARY_SERVICE(&audio_service_uuid.uuid),
	BT_GATT_CHARACTERISTIC(&audio_stream_uuid.uuid, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(audio_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&audio_codec_uuid.uuid, BT_GATT_CHRC_READ,
			       BT_GATT_PERM_READ, read_codec_id, NULL,
			       (void *)&codec_id),
);

static int notify_chunk(const uint8_t *payload, size_t len, uint8_t chunk_index)
{
	uint8_t notify[AUDIO_NOTIFY_MAX_SIZE];

	sys_put_le16(notify_id++, notify);
	notify[2] = chunk_index;
	memcpy(&notify[AUDIO_NOTIFY_HEADER_SIZE], payload, len);

	const int rc = bt_gatt_notify(NULL, &wr_ble_audio_svc.attrs[1], notify,
				      len + AUDIO_NOTIFY_HEADER_SIZE);
	if (rc < 0 && rc != -ENOTCONN) {
		atomic_inc(&audio_notify_errors);
		return rc;
	}

	return 0;
}

void wr_ble_audio_submit_opus(const uint8_t *packet, size_t len, void *user_data)
{
	ARG_UNUSED(user_data);

	if (!atomic_get(&audio_notify_enabled) || packet == NULL || len == 0U) {
		return;
	}

	size_t offset = 0;
	uint8_t chunk_index = 0;

	while (offset < len) {
		const size_t chunk_len = MIN(len - offset, AUDIO_NOTIFY_MAX_PAYLOAD);
		const int rc = notify_chunk(&packet[offset], chunk_len, chunk_index);
		if (rc < 0) {
			atomic_inc(&audio_notify_dropped);
			return;
		}
		offset += chunk_len;
		chunk_index++;
	}

	const atomic_val_t frames = atomic_inc(&audio_frames_sent) + 1;
	if ((frames % AUDIO_LOG_INTERVAL_FRAMES) == 0) {
		LOG_DBG("Live audio frames=%ld dropped=%ld notify_err=%ld",
			frames, atomic_get(&audio_notify_dropped),
			atomic_get(&audio_notify_errors));
	}
}
