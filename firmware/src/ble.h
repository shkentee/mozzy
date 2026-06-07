#ifndef WR_BLE_H
#define WR_BLE_H

#include <stdbool.h>

/* Initialise BLE peripheral: enable controller, register conn callbacks,
 * start advertising as "mojizo". Battery + DIS run automatically via
 * Kconfig (CONFIG_BT_BAS / CONFIG_BT_DIS).
 *
 * Returns 0 on success, negative errno on failure.
 */
int wr_ble_init(void);

/* Are we currently connected to a central? */
bool wr_ble_is_connected(void);

#endif /* WR_BLE_H */
