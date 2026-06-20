/* Status LED driver — XIAO BLE Sense on-board RGB LEDs (active low).
 *
 *   red   = led0 (P0.26)   green = led1 (P0.30)   blue = led2 (P0.06)
 *
 * Used as a status indicator: a brief, dim flash every few seconds —
 * white while recording, green while idle/paused. Dimming is done in software
 * (low-duty PWM by bit-banging) because the board's hardware PWM is wired to
 * P0.17, not to the LED pins.
 */
#include "led.h"

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

LOG_MODULE_REGISTER(wr_led, LOG_LEVEL_INF);

static const struct gpio_dt_spec led_red =
	GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct gpio_dt_spec led_green =
	GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);
static const struct gpio_dt_spec led_blue =
	GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios);

/* Breathing fade: software-PWM at FADE_PERIOD_US, duty ramped 0 -> peak -> 0
 * (triangle) over FADE_CYCLES periods (~1 s). Peak brightness = MAX_DUTY%.
 * The short ON pulse busy-waits; the OFF remainder k_sleeps so the CPU idles
 * (keeps the breathing effect cheap on battery). */
#define FADE_CYCLES 200 /* x FADE_PERIOD_US = ~1 s breathing fade */
#define FADE_PERIOD_US 5000
#define FADE_MAX_DUTY_PCT 6
/* Envelope: quick rise over the first ATTACK_FRAC of the fade, then a smooth
 * (eased) decay — a snappy attack with a sine-like tail. */
#define FADE_ATTACK_FRAC 0.20f

#define LED_DEFAULT_INTERVAL_SEC 4U
#define LED_DEFAULT_BRIGHTNESS_PCT FADE_MAX_DUTY_PCT
#define LED_MAX_BRIGHTNESS_PCT 30U

static struct wr_led_settings led_settings = {
	.mode = WR_LED_MODE_BREATHE,
	.brightness_pct = LED_DEFAULT_BRIGHTNESS_PCT,
	.interval_sec = LED_DEFAULT_INTERVAL_SEC,
	.recording_color = WR_LED_COLOR_WHITE,
	.idle_color = WR_LED_COLOR_GREEN,
};

int wr_led_init(void)
{
	if (!gpio_is_ready_dt(&led_red) || !gpio_is_ready_dt(&led_green)) {
		LOG_ERR("LED GPIO not ready");
		return -ENODEV;
	}

	int r = gpio_pin_configure_dt(&led_red, GPIO_OUTPUT_INACTIVE);

	if (r < 0) {
		LOG_ERR("red LED configure: %d", r);
		return r;
	}
	r = gpio_pin_configure_dt(&led_green, GPIO_OUTPUT_INACTIVE);
	if (r < 0) {
		LOG_ERR("green LED configure: %d", r);
		return r;
	}
	r = gpio_pin_configure_dt(&led_blue, GPIO_OUTPUT_INACTIVE);
	if (r < 0) {
		LOG_ERR("blue LED configure: %d", r);
		return r;
	}
	LOG_INF("LED initialised (RGB on P0.26/P0.30/P0.06)");
	return 0;
}

int wr_led_set(bool on)
{
	return gpio_pin_set_dt(&led_green, on ? 1 : 0);
}

int wr_led_toggle(void)
{
	return gpio_pin_toggle_dt(&led_green);
}

void wr_led_red(bool on)
{
	(void)gpio_pin_set_dt(&led_red, on ? 1 : 0);
}

void wr_led_green(bool on)
{
	(void)gpio_pin_set_dt(&led_green, on ? 1 : 0);
}

void wr_led_get_settings(struct wr_led_settings *out)
{
	if (out == NULL) {
		return;
	}
	*out = led_settings;
}

static uint8_t sanitize_color(uint8_t color, uint8_t fallback)
{
	switch (color) {
	case WR_LED_COLOR_GREEN:
	case WR_LED_COLOR_WHITE:
	case WR_LED_COLOR_BLUE:
	case WR_LED_COLOR_RED:
	case WR_LED_COLOR_CYAN:
	case WR_LED_COLOR_AMBER:
	case WR_LED_COLOR_MAGENTA:
		return color;
	default:
		return fallback;
	}
}

void wr_led_apply_settings(uint8_t mode, uint8_t brightness_pct,
			   uint8_t interval_sec, uint8_t recording_color,
			   uint8_t idle_color)
{
	if (mode != WR_LED_MODE_OFF) {
		mode = WR_LED_MODE_BREATHE;
	}
	led_settings.mode = mode;
	led_settings.brightness_pct =
		CLAMP(brightness_pct, 1U, LED_MAX_BRIGHTNESS_PCT);
	led_settings.interval_sec = CLAMP(interval_sec, 1U, 10U);
	led_settings.recording_color =
		sanitize_color(recording_color, WR_LED_COLOR_WHITE);
	led_settings.idle_color = sanitize_color(idle_color, WR_LED_COLOR_GREEN);
	LOG_INF("LED settings: mode=%u brightness=%u%% interval=%us rec=%u idle=%u",
		(unsigned int)led_settings.mode,
		(unsigned int)led_settings.brightness_pct,
		(unsigned int)led_settings.interval_sec,
		(unsigned int)led_settings.recording_color,
		(unsigned int)led_settings.idle_color);
}

uint32_t wr_led_status_interval_ms(void)
{
	return (uint32_t)led_settings.interval_sec * 1000U;
}

static void flash_pins(uint8_t color, int on)
{
	const bool red = color == WR_LED_COLOR_WHITE ||
			 color == WR_LED_COLOR_RED ||
			 color == WR_LED_COLOR_AMBER ||
			 color == WR_LED_COLOR_MAGENTA;
	const bool green = color == WR_LED_COLOR_GREEN ||
			   color == WR_LED_COLOR_WHITE ||
			   color == WR_LED_COLOR_CYAN ||
			   color == WR_LED_COLOR_AMBER;
	const bool blue = color == WR_LED_COLOR_WHITE ||
			  color == WR_LED_COLOR_BLUE ||
			  color == WR_LED_COLOR_CYAN ||
			  color == WR_LED_COLOR_MAGENTA;

	(void)gpio_pin_set_dt(&led_red, red ? on : 0);
	(void)gpio_pin_set_dt(&led_green, green ? on : 0);
	(void)gpio_pin_set_dt(&led_blue, blue ? on : 0);
}

void wr_led_dim_flash(bool recording)
{
	const uint8_t color = recording ? led_settings.recording_color :
					  led_settings.idle_color;

	if (led_settings.mode == WR_LED_MODE_OFF) {
		flash_pins(WR_LED_COLOR_WHITE, 0);
		return;
	}

	for (int i = 0; i < FADE_CYCLES; i++) {
		/* Brightness envelope 0..1: quick (linear) rise during the attack,
		 * then a smooth quadratic ease-out decay (sine-like tail). */
		const float t = (float)i / (float)(FADE_CYCLES - 1); /* 0..1 */
		float b;

		if (t < FADE_ATTACK_FRAC) {
			b = t / FADE_ATTACK_FRAC;
		} else {
			const float r = (t - FADE_ATTACK_FRAC) /
					(1.0f - FADE_ATTACK_FRAC);
			const float k = 1.0f - r;

			b = k * k;
		}

		uint32_t on_us = (uint32_t)(b * ((float)led_settings.brightness_pct / 100.0f) *
					    (float)FADE_PERIOD_US);

		if (on_us > FADE_PERIOD_US) {
			on_us = FADE_PERIOD_US;
		}
		if (on_us > 0) {
			flash_pins(color, 1);
			k_busy_wait(on_us);
			flash_pins(color, 0);
		}

		const uint32_t off_us = FADE_PERIOD_US - on_us;

		if (off_us > 0) {
			k_sleep(K_USEC(off_us)); /* idle the CPU between pulses */
		}
	}
	flash_pins(color, 0); /* ensure fully off */
}
