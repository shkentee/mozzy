#ifndef WR_BOOT_CMD_H
#define WR_BOOT_CMD_H

#define WR_BOOT_FORMAT_SD_MAGIC 0xA6

/* Initialise the USB CDC console listener.
 *
 * Spawns a thread that reads lines from the console UART (usb_cdc_acm
 * via DT_CHOSEN(zephyr_console)) and, on receiving "boot", sets the
 * GPREGRET magic for the Adafruit UF2 bootloader and resets the SoC.
 * Receiving "format-sd" sets WR_BOOT_FORMAT_SD_MAGIC and resets; main()
 * performs the destructive SD format early in the next boot, before audio
 * capture starts.
 *
 * This lets `flash.ps1` drop the board into UF2 mode without a physical
 * reset double-tap.
 *
 * Returns 0 on success.
 */
int wr_boot_cmd_init(void);

#endif /* WR_BOOT_CMD_H */
