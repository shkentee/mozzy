#include "wr_audio.h"

#include <hal/nrf_pdm.h>
#include <string.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/util.h>

#include "wr_ble_audio.h"
#include "wr_codec.h"
#include "wr_recorder.h"

LOG_MODULE_REGISTER(wr_audio, LOG_LEVEL_INF);

#define SAMPLE_BIT_WIDTH 16
#define BYTES_PER_SAMPLE sizeof(int16_t)
#define PCM_FRAME_BYTES (WR_CODEC_FRAME_SAMPLES * BYTES_PER_SAMPLE)
#define READ_TIMEOUT_MS 1000
/* Long-uptime PDM stall recovery: dmic_read starts returning -EAGAIN ("No
 * audio data to be read") forever. After this many consecutive failures
 * (~seconds at READ_TIMEOUT_MS each) restart the DMIC; if that doesn't help
 * after a few more, cold-reboot so capture always self-recovers. */
#define DMIC_RESTART_AFTER 3
#define DMIC_REBOOT_AFTER 12
#define DMIC_BLOCK_COUNT 12
#define PCM_QUEUE_DEPTH 16
#define CAPTURE_STACK_SIZE 2048
#define CODEC_STACK_SIZE 32768
#define CAPTURE_THREAD_PRIORITY 5
#define CODEC_THREAD_PRIORITY 5

struct pcm_frame {
	int16_t samples[WR_CODEC_FRAME_SAMPLES];
};

K_MEM_SLAB_DEFINE_STATIC(dmic_slab, PCM_FRAME_BYTES, DMIC_BLOCK_COUNT, 4);
K_MSGQ_DEFINE(pcm_queue, sizeof(struct pcm_frame), PCM_QUEUE_DEPTH, 4);

static K_THREAD_STACK_DEFINE(capture_stack, CAPTURE_STACK_SIZE);
static K_THREAD_STACK_DEFINE(codec_stack, CODEC_STACK_SIZE);
static struct k_thread capture_thread;
static struct k_thread codec_thread;
static atomic_t pcm_dropped;
static atomic_t encode_errors;
static bool started;

/* OMI's saved default is level 6 (+20dB), which maps to 0x3C. */
static atomic_t pdm_gain = ATOMIC_INIT(0x3C);

static void apply_pdm_gain(uint8_t gain)
{
#if defined(NRF_PDM0_S)
	nrf_pdm_gain_set(NRF_PDM0_S, (nrf_pdm_gain_t)gain,
			 (nrf_pdm_gain_t)gain);
#elif defined(NRF_PDM0_NS)
	nrf_pdm_gain_set(NRF_PDM0_NS, (nrf_pdm_gain_t)gain,
			 (nrf_pdm_gain_t)gain);
#elif defined(NRF_PDM0)
	nrf_pdm_gain_set(NRF_PDM0, (nrf_pdm_gain_t)gain,
			 (nrf_pdm_gain_t)gain);
#elif defined(NRF_PDM)
	nrf_pdm_gain_set(NRF_PDM, (nrf_pdm_gain_t)gain,
			 (nrf_pdm_gain_t)gain);
#else
	ARG_UNUSED(gain);
#endif
}

void wr_audio_set_mic_gain(uint8_t gain)
{
	const uint8_t g =
		gain > NRF_PDM_GAIN_MAXIMUM ? NRF_PDM_GAIN_MAXIMUM : gain;

	atomic_set(&pdm_gain, g);
	apply_pdm_gain(g);
	LOG_INF("PDM mic gain set to 0x%02x (%u)", g, g);
}

uint8_t wr_audio_get_mic_gain(void)
{
	return (uint8_t)atomic_get(&pdm_gain);
}

/* Copy one PCM frame. Level 0 mutes in software too, so mute is deterministic. */
static void copy_with_gain(int16_t *dst, const int16_t *src)
{
	const int g = atomic_get(&pdm_gain);

	if (g == 0) {
		memset(dst, 0, PCM_FRAME_BYTES);
		return;
	}
	memcpy(dst, src, PCM_FRAME_BYTES);
}

static void packet_ready(const uint8_t *packet, size_t len, void *user_data)
{
	ARG_UNUSED(user_data);

	/* When recording is stopped (button / app / BLE), capture nothing: skip
	 * both the SD write and the BLE live stream so "stop" really stops — the
	 * phone's packet counter freezes and we stop spending radio power. */
	if (!wr_recorder_is_recording()) {
		return;
	}

	wr_recorder_submit_opus(packet, len, NULL);
	wr_ble_audio_submit_opus(packet, len, NULL);
}

static void codec_entry(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	struct pcm_frame frame;
	uint8_t packet[WR_CODEC_MAX_PACKET_BYTES];
	uint32_t encoded_frames = 0;
	uint32_t encoded_bytes = 0;

	for (;;) {
		(void)k_msgq_get(&pcm_queue, &frame, K_FOREVER);

		/* PoC (vad-poc): when not recording, skip Opus entirely so the CPU
		 * idles between PDM frames instead of encoding every 10 ms. This is
		 * the "low-power listening" floor we want to measure (and the basis
		 * for VAD gating: detect energy cheaply here, only encode on speech).
		 * NOTE: PoC only — full VAD adds energy detection + auto record gating. */
		if (!wr_recorder_is_recording()) {
			continue;
		}

		const int ret = wr_codec_encode_10ms(frame.samples, packet, sizeof(packet));
		if (ret < 0) {
			atomic_inc(&encode_errors);
			continue;
		}

		encoded_frames++;
		encoded_bytes += (uint32_t)ret;
		if ((encoded_frames % 100U) == 0U) {
			LOG_DBG("Opus encoded frames=%u avg=%uB last=%dB pcm_drop=%ld enc_err=%ld",
				encoded_frames, encoded_bytes / encoded_frames, ret,
				atomic_get(&pcm_dropped), atomic_get(&encode_errors));
		}
	}
}

static int configure_dmic(const struct device *dmic_dev)
{
	static struct pcm_stream_cfg stream = {
		.pcm_width = SAMPLE_BIT_WIDTH,
		.mem_slab = &dmic_slab,
	};
	static struct dmic_cfg cfg = {
		.io = {
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3500000,
			.min_pdm_clk_dc = 40,
			.max_pdm_clk_dc = 60,
		},
		.streams = &stream,
		.channel = {
			.req_num_streams = 1,
			.req_num_chan = WR_CODEC_CHANNELS,
		},
	};

	stream.pcm_rate = WR_CODEC_SAMPLE_RATE_HZ;
	stream.block_size = PCM_FRAME_BYTES;
	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);

	return dmic_configure(dmic_dev, &cfg);
}

static void capture_entry(void *arg1, void *arg2, void *arg3)
{
	ARG_UNUSED(arg1);
	ARG_UNUSED(arg2);
	ARG_UNUSED(arg3);

	const struct device *const dmic_dev = DEVICE_DT_GET(DT_NODELABEL(dmic_dev));
	struct pcm_frame frame;
	uint32_t captured_frames = 0;

	if (!device_is_ready(dmic_dev)) {
		LOG_ERR("%s is not ready", dmic_dev->name);
		return;
	}

	int ret = configure_dmic(dmic_dev);
	if (ret < 0) {
		LOG_ERR("dmic_configure failed: %d", ret);
		return;
	}
	wr_audio_set_mic_gain(wr_audio_get_mic_gain());

	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
	if (ret < 0) {
		LOG_ERR("DMIC start failed: %d", ret);
		return;
	}
	LOG_INF("PDM capture started: %u Hz mono, %u bytes per 10 ms",
		WR_CODEC_SAMPLE_RATE_HZ, PCM_FRAME_BYTES);

	uint32_t consecutive_fail = 0U;

	for (;;) {
		void *buffer = NULL;
		uint32_t size = 0;

		ret = dmic_read(dmic_dev, 0, &buffer, &size, READ_TIMEOUT_MS);
		if (ret < 0) {
			LOG_WRN("dmic_read failed: %d", ret);
			consecutive_fail++;
			if (consecutive_fail == DMIC_RESTART_AFTER) {
				LOG_WRN("DMIC stalled (%u fails) — restarting capture",
					consecutive_fail);
				(void)dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
				k_sleep(K_MSEC(50));
				const int rc =
					dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
				if (rc < 0) {
					LOG_ERR("DMIC restart failed: %d", rc);
				}
			} else if (consecutive_fail >= DMIC_REBOOT_AFTER) {
				LOG_ERR("DMIC unrecoverable (%u fails) — rebooting",
					consecutive_fail);
				sys_reboot(SYS_REBOOT_COLD);
			}
			continue;
		}
		consecutive_fail = 0U;

		if (size >= PCM_FRAME_BYTES) {
			copy_with_gain(frame.samples, (const int16_t *)buffer);
			ret = k_msgq_put(&pcm_queue, &frame, K_NO_WAIT);
			if (ret < 0) {
				atomic_inc(&pcm_dropped);
			} else {
				captured_frames++;
				if ((captured_frames % 100U) == 0U) {
					LOG_DBG("PCM captured frames=%u queue=%u drop=%ld",
						captured_frames,
						k_msgq_num_used_get(&pcm_queue),
						atomic_get(&pcm_dropped));
				}
			}
		} else {
			LOG_WRN("short DMIC block: %u bytes", size);
		}

		k_mem_slab_free(&dmic_slab, buffer);
	}
}

int wr_audio_start(void)
{
	if (started) {
		return 0;
	}

	int ret = wr_codec_init(packet_ready, NULL);
	if (ret < 0) {
		return ret;
	}

	k_thread_create(&codec_thread, codec_stack,
			K_THREAD_STACK_SIZEOF(codec_stack),
			codec_entry, NULL, NULL, NULL,
			CODEC_THREAD_PRIORITY, 0, K_NO_WAIT);

	k_thread_create(&capture_thread, capture_stack,
			K_THREAD_STACK_SIZEOF(capture_stack),
			capture_entry, NULL, NULL, NULL,
			CAPTURE_THREAD_PRIORITY, 0, K_NO_WAIT);

	started = true;
	return 0;
}
