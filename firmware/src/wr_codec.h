#ifndef WR_CODEC_H
#define WR_CODEC_H

#include <stddef.h>
#include <stdint.h>

#define WR_CODEC_SAMPLE_RATE_HZ 16000
#define WR_CODEC_CHANNELS 1
#define WR_CODEC_FRAME_SAMPLES 160
#define WR_CODEC_MAX_PACKET_BYTES 320

typedef void (*wr_codec_packet_cb_t)(const uint8_t *packet, size_t len, void *user_data);

int wr_codec_init(wr_codec_packet_cb_t cb, void *user_data);
int wr_codec_encode_10ms(const int16_t *pcm, uint8_t *packet, size_t packet_cap);

#endif /* WR_CODEC_H */
