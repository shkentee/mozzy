#include "wr_codec.h"

#include <errno.h>
#include <stdbool.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "config.h"
#include "lib/opus-1.2.1/opus.h"

LOG_MODULE_REGISTER(wr_codec, LOG_LEVEL_INF);

#define OPUS_ENCODER_SIZE 7180

static uint8_t opus_encoder_mem[OPUS_ENCODER_SIZE] __aligned(4);
static OpusEncoder *const opus_state = (OpusEncoder *)opus_encoder_mem;
static wr_codec_packet_cb_t packet_cb;
static void *packet_cb_user_data;
static bool codec_ready;

int wr_codec_init(wr_codec_packet_cb_t cb, void *user_data)
{
	const int required = opus_encoder_get_size(WR_CODEC_CHANNELS);

	if (required > (int)sizeof(opus_encoder_mem)) {
		LOG_ERR("Opus encoder buffer too small: need=%d have=%u",
			required, (unsigned int)sizeof(opus_encoder_mem));
		return -ENOMEM;
	}

	int ret = opus_encoder_init(opus_state, WR_CODEC_SAMPLE_RATE_HZ,
				    WR_CODEC_CHANNELS,
				    OPUS_APPLICATION_RESTRICTED_LOWDELAY);
	if (ret != OPUS_OK) {
		LOG_ERR("opus_encoder_init failed: %d", ret);
		return -EIO;
	}

	(void)opus_encoder_ctl(opus_state, OPUS_SET_BITRATE(CODEC_OPUS_BITRATE));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_VBR(CODEC_OPUS_VBR));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_VBR_CONSTRAINT(0));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_COMPLEXITY(CODEC_OPUS_COMPLEXITY));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_LSB_DEPTH(16));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_DTX(0));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_INBAND_FEC(0));
	(void)opus_encoder_ctl(opus_state, OPUS_SET_PACKET_LOSS_PERC(0));

	packet_cb = cb;
	packet_cb_user_data = user_data;
	codec_ready = true;

	LOG_INF("Opus ready: %u Hz mono, %u samples/frame, bitrate=%u",
		WR_CODEC_SAMPLE_RATE_HZ, WR_CODEC_FRAME_SAMPLES,
		CODEC_OPUS_BITRATE);
	return 0;
}

int wr_codec_encode_10ms(const int16_t *pcm, uint8_t *packet, size_t packet_cap)
{
	if (!codec_ready) {
		return -EACCES;
	}
	if (pcm == NULL || packet == NULL) {
		return -EINVAL;
	}

	const int ret = opus_encode(opus_state, pcm, WR_CODEC_FRAME_SAMPLES,
				    packet, packet_cap);
	if (ret < 0) {
		LOG_WRN("opus_encode failed: %d", ret);
		return -EIO;
	}

	if (packet_cb) {
		packet_cb(packet, (size_t)ret, packet_cb_user_data);
	}
	return ret;
}
