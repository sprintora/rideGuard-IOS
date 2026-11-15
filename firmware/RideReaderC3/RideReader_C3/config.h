#pragma once

// ---- Target: ESP32-C3 (single-core RISC-V, 160 MHz max, ~400KB SRAM, BLE 5 only) ----
#define CPU_FREQ_MHZ 80            // reader is I/O-bound; 80 MHz is plenty (use 160 if you need more headroom)

// ---- RC522 (SPI) ----
#define RC522_SCK 4
#define RC522_MISO 5
#define RC522_MOSI 6
#define RC522_SS 7
#define RC522_RST 3

// ---- Feedback ----
#define GREEN_LED 0
#define RED_LED 1
#define BUZZER 10
#define BUZZER_ACTIVE 1            // 1 = active buzzer (plain on/off), 0 = passive buzzer (tone())
#define STATUS_LED 8               // GPIO8 is a strapping pin: keep the LED circuit light. Shows BLE connected.
#define STATUS_LED_ACTIVE_LOW 0    // set 1 if your LED is wired active-low (many C3 SuperMini boards)
#define LED_PULSE_MS 300UL         // how long green/red flashes last

#define DEBUG 0                    // 1 = serial logging (enable "USB CDC On Boot" in Arduino IDE)
#define DEBOUNCE_MS 3000UL
#define CARD_POLL_MS 20UL
#define TAP_DELIVERY_INTERVAL_MS 250UL
#define TAP_BUFFER_SIZE 32         // reduced from 64 for the C3's smaller RAM / NVS blob
#define DEVICE_ID_DEFAULT "RR-0001"

#define FIRMWARE_VERSION "2.0.0"

#define CARD_DATA_BLOCK 4
#define CARD_CODE_LENGTH 16
#define ENROLLMENT_TIMEOUT_MS 30000UL
#define CARD_KEY_A {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

// ---- BLE ----
#define BLE_REQUIRE_ENCRYPTION 0   // 1 = bonded/encrypted link required for write characteristics
#define BLE_MTU 64                 // app must also request an MTU >= 27 (tap packet is 24 bytes)

#define BLE_SERVICE_UUID "7f4b0001-6f4a-4f4a-9b2b-524944455231"
#define BLE_TAP_UUID "7f4b0002-6f4a-4f4a-9b2b-524944455231"
#define BLE_ACK_UUID "7f4b0003-6f4a-4f4a-9b2b-524944455231"
#define BLE_FEEDBACK_UUID "7f4b0004-6f4a-4f4a-9b2b-524944455231"
#define BLE_INFO_UUID "7f4b0005-6f4a-4f4a-9b2b-524944455231"
#define BLE_CONTROL_UUID "7f4b0006-6f4a-4f4a-9b2b-524944455231"
#define BLE_STATUS_UUID "7f4b0007-6f4a-4f4a-9b2b-524944455231"
