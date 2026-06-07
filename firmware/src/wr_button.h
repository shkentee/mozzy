#ifndef WR_BUTTON_H
#define WR_BUTTON_H

/* Initialise the external push-button (D4 power / D5 input). Short press
 * toggles SD recording; long press enters deep sleep. Returns 0 on success. */
int wr_button_init(void);

/* Enter deep sleep (nRF System OFF) now; wakes on a button press. Used by the
 * app's BLE "sleep" command. Does not return. */
void wr_button_request_sleep(void);

#endif /* WR_BUTTON_H */
