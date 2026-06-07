/* Battery voltage sensing + BLE Battery Service publishing. */
#ifndef WR_BATTERY_H
#define WR_BATTERY_H

/* Configure the battery-sense path (P0.14 held low, AIN7 ADC channel) and
 * start a background thread that periodically samples the cell voltage and
 * publishes the level via the BLE Battery Service.
 *
 * Returns 0 on success or a negative errno if the GPIO/ADC could not be set
 * up (in which case no monitor thread is started).
 */
int wr_battery_init(void);

#endif /* WR_BATTERY_H */
