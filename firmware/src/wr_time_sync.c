/*
 * Time-sync GATT characteristic (spec §10 / D7).
 *
 * Registers a small secondary BLE GATT service so the phone can hand the
 * device the current wall-clock time on connect. The device has no RTC of
 * its own, so this is how recordings get a real timestamp:
 *
 *   Service / Characteristic UUID: 19B10005-E8F2-537E-4F6C-D104768A1214
 *   Characteristic: WRITE WITHOUT RESPONSE, 8 bytes = LE64 Unix time (seconds)
 *
 * On write we forward the value to wr_recorder_set_sync_time(), which renames
 * the active recording to its real <epoch>.opus_sd start time.
 *
 * Mirrors the app side: WrBleDevice._trySendTimeSync() / WrUuids.timeSyncChar.
 * Zephyr allows multiple BT_GATT_SERVICE_DEFINE across translation units, so
 * this lives in its own file and touches nothing else.
 */

#include <inttypes.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>

#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_time_sync, LOG_LEVEL_INF);

#define WR_TIME_SYNC_UUID \
	BT_UUID_128_ENCODE(0x19B10005, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214)

static struct bt_uuid_128 wr_time_sync_svc_uuid =
	BT_UUID_INIT_128(WR_TIME_SYNC_UUID);
static struct bt_uuid_128 wr_time_sync_char_uuid =
	BT_UUID_INIT_128(WR_TIME_SYNC_UUID);

static ssize_t wr_time_sync_write(struct bt_conn *conn,
				  const struct bt_gatt_attr *attr,
				  const void *buf, uint16_t len,
				  uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);
	ARG_UNUSED(offset);
	ARG_UNUSED(flags);

	if (len != sizeof(uint64_t)) {
		LOG_WRN("expected 8 bytes, got %u", len);
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	uint64_t unix_secs;

	memcpy(&unix_secs, buf, sizeof(unix_secs));
	LOG_INF("received epoch %" PRIu64 " s", unix_secs);

	wr_recorder_set_sync_time(unix_secs);

	return (ssize_t)len;
}

BT_GATT_SERVICE_DEFINE(wr_time_sync_svc,
	BT_GATT_PRIMARY_SERVICE(&wr_time_sync_svc_uuid),
	BT_GATT_CHARACTERISTIC(&wr_time_sync_char_uuid.uuid,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE,
			       NULL, wr_time_sync_write, NULL),
);
