#ifndef WR_LED_H
#define WR_LED_H

#include <stdbool.h>

/* Initialise the status LEDs (red = led0/P0.26, green = led1/P0.30). */
int wr_led_init(void);

/* Drive the GREEN LED on/off / toggle (kept for bring-up compatibility). */
int wr_led_set(bool on);
int wr_led_toggle(void);

/* Drive individual colours. */
void wr_led_red(bool on);
void wr_led_green(bool on);

/* A dim, fade-in/out "breathing" pulse used as the status indicator:
 * recording = WHITE (R+G+B), idle/paused = GREEN. Software-PWM; ~1 s breathe
 * (quick rise + eased decay). */
void wr_led_dim_flash(bool recording);

#endif /* WR_LED_H */
