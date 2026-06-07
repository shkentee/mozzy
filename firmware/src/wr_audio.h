#ifndef WR_AUDIO_H
#define WR_AUDIO_H

#include <stdint.h>

int wr_audio_start(void);

/* Software capture gain, Q4 fixed point (16 = 1.0x). Adjustable from the phone
 * over BLE; clamped to a sane range. Applied to PCM before Opus encoding. */
void wr_audio_set_gain_q4(uint8_t gain_q4);
uint8_t wr_audio_get_gain_q4(void);

#endif /* WR_AUDIO_H */
