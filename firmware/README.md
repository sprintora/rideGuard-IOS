# Ride Reader firmware

The ESP32/RC522 reader uses firmware protocol version `2.0.0`.

## Card registration

The app sends `ENROLL:<16-character-code>` over CONTROL. The reader changes
to registration mode, waits for one card, authenticates MIFARE block 4, writes
the code, reads it back, and sends STATUS success only after an exact match.
Registration mode is disabled immediately after that one verified write.

Normal TAP notifications contain:

```text
seq uint32 LE, 16 ASCII card-code bytes, uptimeMs uint32 LE
```

Cards without a valid stored code are rejected. ACK, resend, and duplicate
suppression remain enabled.

`config.h` currently uses the factory MIFARE key
`FF FF FF FF FF FF` for pilot testing. Replace it with a deployment-specific
key before production because the default key permits cloning. Never write
block 0 or a sector trailer.

## Flashing

Select **ESP32 Dev Module**, install the MFRC522 and ESP32 BLE Arduino
libraries, open the folder containing both `RideReader.ino` and `config.h`,
and upload at 115200 baud. Verify the registration flow on real cards before
using the module in the pilot.
