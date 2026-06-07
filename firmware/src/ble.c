/* BLE peripheral bring-up.
 *
 * Advertises as "mojizo". Brings up
 * Battery Service (0x180F) and Device Information Service (0x180A);
 * audio + storage services are added by ble_audio.c / ble_storage.c.
 */
#include "ble.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gap.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(wr_ble, LOG_LEVEL_INF);

static struct bt_conn *current_conn;

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID16_ALL,
		      BT_UUID_16_ENCODE(BT_UUID_BAS_VAL),
		      BT_UUID_16_ENCODE(BT_UUID_DIS_VAL)),
};

static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
		sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

/* Slow connectable advertising (1.0-1.2 s) instead of the default fast
 * 100-150 ms (BT_LE_ADV_CONN). The recorder buffers audio to SD and is
 * fetched periodically over BLE, so it needn't be discoverable within
 * 100 ms; a ~1 s interval cuts the always-on advertising radio current
 * (part of the idle baseline). Discovery just takes a second or two longer. */
static const struct bt_le_adv_param adv_param_slow = BT_LE_ADV_PARAM_INIT(
	BT_LE_ADV_OPT_CONNECTABLE,
	BT_GAP_ADV_SLOW_INT_MIN, BT_GAP_ADV_SLOW_INT_MAX, NULL);

static int start_advertising(void)
{
	return bt_le_adv_start(&adv_param_slow, ad, ARRAY_SIZE(ad),
			       sd, ARRAY_SIZE(sd));
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	char addr[BT_ADDR_LE_STR_LEN];
	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	if (err) {
		LOG_ERR("Connect failed (err 0x%02x) addr=%s", err, addr);
		return;
	}
	LOG_INF("Connected addr=%s", addr);
	current_conn = bt_conn_ref(conn);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("Disconnected (reason 0x%02x)", reason);
	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}

	/* Advertising stops once a central connects; restart it on disconnect
	 * so the device is rediscoverable without a reboot. */
	const int err = start_advertising();
	if (err) {
		LOG_ERR("re-advertise after disconnect failed: %d", err);
	} else {
		LOG_INF("Advertising restarted");
	}
}

static void mtu_updated(struct bt_conn *conn, uint16_t tx, uint16_t rx)
{
	LOG_INF("MTU updated tx=%u rx=%u", tx, rx);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
};

static struct bt_gatt_cb gatt_callbacks = {
	.att_mtu_updated = mtu_updated,
};

int wr_ble_init(void)
{
	int err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable failed: %d", err);
		return err;
	}
	LOG_INF("Bluetooth initialised");

	bt_gatt_cb_register(&gatt_callbacks);

	err = start_advertising();
	if (err) {
		LOG_ERR("bt_le_adv_start failed: %d", err);
		return err;
	}
	LOG_INF("Advertising as '%s'", CONFIG_BT_DEVICE_NAME);
	return 0;
}

bool wr_ble_is_connected(void)
{
	return current_conn != NULL;
}
