#ifndef WR_BLE_AUDIO_H
#define WR_BLE_AUDIO_H

#include <stddef.h>
#include <stdint.h>

/* Codec packet callback. Sends Opus packets through the live-audio GATT
 * characteristic when a central has enabled notifications. */
void wr_ble_audio_submit_opus(const uint8_t *packet, size_t len, void *user_data);

#endif /* WR_BLE_AUDIO_H */
