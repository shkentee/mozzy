#ifndef WR_AUDIO_H
#define WR_AUDIO_H

#include <stdint.h>

int wr_audio_start(void);

/* PDM microphone gain byte. OMI DevKit2 uses fixed MIC_GAIN 64 (0x40);
 * mojizo writes the selected value to both mic channels. */
void wr_audio_set_mic_gain(uint8_t gain);
uint8_t wr_audio_get_mic_gain(void);

#endif /* WR_AUDIO_H */
