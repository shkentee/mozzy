/* Status LED driver — XIAO BLE Sense on-board RGB LEDs (active low).
 *
 *   red   = led0 (P0.26)   green = led1 (P0.30)   blue = led2 (P0.06)
 *
 * Used as a status indicator: a brief, dim flash every few seconds —
 * red while recording, green while idle/paused. Dimming is done in software
 * (low-duty PWM by bit-banging) because the board's hardware PWM is wired to
 * P0.17, not to the LED pins.
 */
#include "led.h"

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

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

/* Set the active colour's pins. recording = WHITE (red+green+blue), idle = GREEN. */
static void flash_pins(bool recording, int on)
{
	(void)gpio_pin_set_dt(&led_green, on);
	if (recording) {
		(void)gpio_pin_set_dt(&led_red, on);
		(void)gpio_pin_set_dt(&led_blue, on);
	}
}

void wr_led_dim_flash(bool recording)
{
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

		uint32_t on_us = (uint32_t)(b * ((float)FADE_MAX_DUTY_PCT / 100.0f) *
					    (float)FADE_PERIOD_US);

		if (on_us > FADE_PERIOD_US) {
			on_us = FADE_PERIOD_US;
		}
		if (on_us > 0) {
			flash_pins(recording, 1);
			k_busy_wait(on_us);
			flash_pins(recording, 0);
		}

		const uint32_t off_us = FADE_PERIOD_US - on_us;

		if (off_us > 0) {
			k_sleep(K_USEC(off_us)); /* idle the CPU between pulses */
		}
	}
	flash_pins(recording, 0); /* ensure fully off */
}
