#ifndef WR_LED_H
#define WR_LED_H

#include <stdbool.h>
#include <stdint.h>

#define WR_LED_MODE_OFF     0U
#define WR_LED_MODE_BREATHE 1U

struct wr_led_settings {
	uint8_t mode;
	uint8_t brightness_pct;
	uint8_t interval_sec;
};

/* Initialise the status LEDs (red = led0/P0.26, green = led1/P0.30). */
int wr_led_init(void);

/* Drive the GREEN LED on/off / toggle (kept for bring-up compatibility). */
int wr_led_set(bool on);
int wr_led_toggle(void);

/* Drive individual colours. */
void wr_led_red(bool on);
void wr_led_green(bool on);

/* Runtime status-indicator settings controlled by the mobile app.
 * Defaults match the original firmware: breathing enabled, 6% peak duty,
 * 4 second interval. */
void wr_led_get_settings(struct wr_led_settings *out);
void wr_led_apply_settings(uint8_t mode, uint8_t brightness_pct,
			   uint8_t interval_sec);
uint32_t wr_led_status_interval_ms(void);

/* A dim, fade-in/out "breathing" pulse used as the status indicator:
 * recording = WHITE (R+G+B), idle/paused = GREEN. Software-PWM; ~1 s breathe
 * (quick rise + eased decay). */
void wr_led_dim_flash(bool recording);

#endif /* WR_LED_H */
