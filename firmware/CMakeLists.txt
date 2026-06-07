# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(mozzy)
enable_language(C ASM)

add_subdirectory(src/lib/opus-1.2.1)

target_sources(app PRIVATE
    src/main.c
    src/led.c
    src/sd.c
    src/ble.c
    src/wr_ble_audio.c
    src/wr_storage_service.c
    src/boot_cmd.c
    src/wr_audio.c
    src/wr_codec.c
    src/wr_recorder.c
    src/wr_battery.c
    src/wr_time_sync.c
    src/wr_rec_control.c
    src/wr_button.c
    src/wr_gain_control.c
)
target_include_directories(app PRIVATE src src/lib/opus-1.2.1)
target_link_libraries(app PRIVATE opus_codec)
