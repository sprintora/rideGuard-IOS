#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLESecurity.h>
#include <MFRC522.h>
#include <Preferences.h>
#include <SPI.h>
#include <vector>
#include "config.h"

struct Tap { uint32_t seq; uint8_t code[CARD_CODE_LENGTH]; uint32_t uptime; bool acknowledged; };
MFRC522 rfid(RC522_SS, RC522_RST);
Preferences prefs;
BLECharacteristic *tapCharacteristic = nullptr;
BLECharacteristic *ackCharacteristic = nullptr;
BLECharacteristic *feedbackCharacteristic = nullptr;
BLECharacteristic *infoCharacteristic = nullptr;
BLECharacteristic *controlCharacteristic = nullptr;
BLECharacteristic *statusCharacteristic = nullptr;
Tap buffer[TAP_BUFFER_SIZE];
uint8_t head = 0, tail = 0, count = 0;
uint32_t nextSequence = 1, lastTapAt = 0, lastReinit = 0;
uint32_t lastTapDelivery = 0;
uint8_t lastCode[CARD_CODE_LENGTH] = {};
bool connected = false;
bool rc522Ready = false;
String deviceId;
bool enrollmentActive = false;
bool enrollmentComplete = false;
uint32_t enrollmentStartedAt = 0;
String enrollmentCode;
MFRC522::MIFARE_Key cardKey;

void logLine(const String &line) {
#if DEBUG
  Serial.println(line);
#else
  (void)line;
#endif
}

void playStartupTone() {
  tone(BUZZER, 1200, 100);
  delay(130);
  tone(BUZZER, 1800, 180);
}

void pattern(uint8_t code) {
  const uint8_t pin = code == 0 ? GREEN_LED : RED_LED;
  digitalWrite(pin, HIGH);
  if (code == 0) {
    tone(BUZZER, 2200, 100);
  } else if (code == 1) {
    tone(BUZZER, 800, 300);
  } else if (code == 2) {
    tone(BUZZER, 600, 300);
  } else {
    tone(BUZZER, 800, 100);
  }
  digitalWrite(STATUS_LED, code == 0 ? HIGH : LOW);
}

void sendTap(const Tap &tap) {
  if (!connected || tapCharacteristic == nullptr) return;
  std::vector<uint8_t> packet;
  packet.reserve(24);
  for (uint8_t i = 0; i < 4; ++i) packet.push_back((tap.seq >> (8 * i)) & 0xff);
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) packet.push_back(tap.code[i]);
  for (uint8_t i = 0; i < 4; ++i) packet.push_back((tap.uptime >> (8 * i)) & 0xff);
  tapCharacteristic->setValue(packet.data(), packet.size());
  tapCharacteristic->notify();
}

void sendStatus(const String &status) {
  if (statusCharacteristic == nullptr) return;
  statusCharacteristic->setValue(status.c_str());
  statusCharacteristic->notify();
}

void stopCard() {
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}

bool readCardCode(char *code) {
  byte block[18] = {};
  byte size = sizeof(block);
  if (rfid.PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A,
                            CARD_DATA_BLOCK, &cardKey, &(rfid.uid)) !=
      MFRC522::STATUS_OK) {
    return false;
  }
  if (rfid.MIFARE_Read(CARD_DATA_BLOCK, block, &size) != MFRC522::STATUS_OK) {
    return false;
  }
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) {
    const bool isLetter = block[i] >= 'A' && block[i] <= 'Z';
    const bool isDigit = block[i] >= '2' && block[i] <= '9';
    if (!isLetter && !isDigit) {
      return false;
    }
    code[i] = static_cast<char>(block[i]);
  }
  code[CARD_CODE_LENGTH] = '\0';
  return true;
}

bool writeAndVerifyCardCode() {
  byte block[16];
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) {
    block[i] = static_cast<byte>(enrollmentCode[i]);
  }
  if (rfid.PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A,
                            CARD_DATA_BLOCK, &cardKey, &(rfid.uid)) !=
      MFRC522::STATUS_OK) {
    sendStatus("ENROLL_AUTH_FAILED");
    return false;
  }
  if (rfid.MIFARE_Write(CARD_DATA_BLOCK, block, sizeof(block)) !=
      MFRC522::STATUS_OK) {
    sendStatus("ENROLL_WRITE_FAILED");
    return false;
  }
  byte verify[18] = {};
  byte size = sizeof(verify);
  if (rfid.MIFARE_Read(CARD_DATA_BLOCK, verify, &size) !=
      MFRC522::STATUS_OK ||
      memcmp(verify, block, CARD_CODE_LENGTH) != 0) {
    sendStatus("ENROLL_VERIFY_FAILED");
    return false;
  }
  return true;
}

void saveBuffer() {
  prefs.putBytes("buffer", buffer, sizeof(buffer));
  prefs.putUChar("head", head);
  prefs.putUChar("tail", tail);
  prefs.putUChar("count", count);
  prefs.putUInt("seq", nextSequence);
}

void acknowledge(uint32_t sequence) {
  for (uint8_t i = 0, p = tail; i < count; ++i, p = (p + 1) % TAP_BUFFER_SIZE) {
    if (buffer[p].seq == sequence) {
      buffer[p].acknowledged = true;
      while (count && buffer[tail].acknowledged) {
        tail = (tail + 1) % TAP_BUFFER_SIZE;
        --count;
      }
      saveBuffer();
      return;
    }
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { connected = true; pattern(0); }
  void onDisconnect(BLEServer *) override {
    connected = false;
    digitalWrite(STATUS_LED, LOW);
    BLEDevice::startAdvertising();
  }
};

class AckCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String value = c->getValue();
    if (value.length() == 4) {
      uint32_t sequence = static_cast<uint8_t>(value[0]) |
                          (static_cast<uint8_t>(value[1]) << 8) |
                          (static_cast<uint8_t>(value[2]) << 16) |
                          (static_cast<uint8_t>(value[3]) << 24);
      acknowledge(sequence);
    }
  }
};

class FeedbackCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String value = c->getValue();
    if (value.length() != 1) return;
    uint8_t code = static_cast<uint8_t>(value[0]);
    if (code <= 3) pattern(code);
  }
};

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String value = c->getValue();
    if (value == "PING") pattern(0);
    if (value.startsWith("ENROLL:")) {
      const String code = value.substring(7);
      if (code.length() != CARD_CODE_LENGTH) {
        sendStatus("ENROLL_INVALID_CODE");
        return;
      }
      enrollmentCode = code;
      enrollmentActive = true;
      enrollmentComplete = false;
      enrollmentStartedAt = millis();
      sendStatus("ENROLL_READY");
      pattern(3);
    }
    if (value.startsWith("NAME:") && value.length() < 32) {
      deviceId = value.substring(5);
      prefs.putString("device", deviceId);
      ESP.restart();
    }
    if (value == "FACTORY_RESET") {
      prefs.clear();
      ESP.restart();
    }
  }
};

void setupBle() {
  const String bleName =
      "RideReader-" + deviceId.substring(deviceId.length() - 4);
  BLEDevice::init(bleName.c_str());
  BLESecurity::setEncryptionLevel(ESP_BLE_SEC_ENCRYPT);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(BLE_SERVICE_UUID);
  tapCharacteristic = service->createCharacteristic(BLE_TAP_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  tapCharacteristic->addDescriptor(new BLE2902());
  ackCharacteristic = service->createCharacteristic(BLE_ACK_UUID, BLECharacteristic::PROPERTY_WRITE);
  ackCharacteristic->setCallbacks(new AckCallbacks());
  feedbackCharacteristic = service->createCharacteristic(BLE_FEEDBACK_UUID, BLECharacteristic::PROPERTY_WRITE);
  feedbackCharacteristic->setCallbacks(new FeedbackCallbacks());
  infoCharacteristic = service->createCharacteristic(BLE_INFO_UUID, BLECharacteristic::PROPERTY_READ);
  infoCharacteristic->setValue((deviceId + "," + FIRMWARE_VERSION + "," + String(lastTapAt)).c_str());
  controlCharacteristic = service->createCharacteristic(BLE_CONTROL_UUID, BLECharacteristic::PROPERTY_WRITE);
  controlCharacteristic->setCallbacks(new ControlCallbacks());
  statusCharacteristic = service->createCharacteristic(
      BLE_STATUS_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  statusCharacteristic->addDescriptor(new BLE2902());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
}

bool initRc522() {
  rfid.PCD_Init();
  const byte version = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  if (version == 0x00 || version == 0xff) {
    Serial.println("RC522 not found - check wiring");
    return false;
  }
  Serial.printf("RC522 OK, version 0x%02X\n", version);
  digitalWrite(GREEN_LED, HIGH);
  digitalWrite(STATUS_LED, HIGH);
  return true;
}

void readCard() {
  if (!rc522Ready) return;
  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) return;
  if (rfid.uid.size == 0 || rfid.uid.size > 10) {
    stopCard(); pattern(1); return;
  }
  if (enrollmentActive) {
    sendStatus("ENROLL_WRITING");
    if (writeAndVerifyCardCode()) {
      enrollmentActive = false;
      enrollmentComplete = true;
      sendStatus("ENROLL_SUCCESS:" + enrollmentCode);
      pattern(0);
    } else {
      pattern(2);
    }
    stopCard();
    return;
  }
  char code[CARD_CODE_LENGTH + 1] = {};
  if (!readCardCode(code)) {
    sendStatus("CARD_CODE_MISSING");
    pattern(2);
    stopCard();
    return;
  }
  const uint32_t now = millis();
  if (enrollmentActive &&
      now - enrollmentStartedAt >= ENROLLMENT_TIMEOUT_MS) {
    enrollmentActive = false;
    sendStatus("ENROLL_TIMEOUT");
    pattern(1);
  }
  bool duplicate = now - lastTapAt < DEBOUNCE_MS &&
                   memcmp(lastCode, code, CARD_CODE_LENGTH) == 0;
  if (!duplicate) {
    if (count == TAP_BUFFER_SIZE) {
      pattern(3);
    } else {
      Tap &tap = buffer[head];
      tap.seq = nextSequence++;
      memcpy(tap.code, code, CARD_CODE_LENGTH);
      tap.uptime = now;
      tap.acknowledged = false;
      head = (head + 1) % TAP_BUFFER_SIZE;
      ++count;
      memcpy(lastCode, tap.code, CARD_CODE_LENGTH);
      lastTapAt = now;
      saveBuffer();
      sendTap(tap);
      pattern(0);
    }
  }
  stopCard();
}

void setup() {
  pinMode(GREEN_LED, OUTPUT); pinMode(RED_LED, OUTPUT);
  pinMode(BUZZER, OUTPUT); pinMode(STATUS_LED, OUTPUT);
  playStartupTone();
  Serial.begin(115200);
  prefs.begin("ride-reader", false);
  const byte configuredKey[6] = CARD_KEY_A;
  memcpy(cardKey.keyByte, configuredKey, sizeof(configuredKey));
  deviceId = prefs.getString("device", DEVICE_ID_DEFAULT);
  head = prefs.getUChar("head", 0); tail = prefs.getUChar("tail", 0);
  count = prefs.getUChar("count", 0); nextSequence = prefs.getUInt("seq", 1);
  if (prefs.getBytesLength("buffer") == sizeof(buffer)) {
    prefs.getBytes("buffer", buffer, sizeof(buffer));
  } else {
    memset(buffer, 0, sizeof(buffer));
    saveBuffer();
  }
  SPI.begin(RC522_SCK, RC522_MISO, RC522_MOSI, RC522_SS);
  const uint64_t mac = ESP.getEfuseMac();
  char macSuffix[5];
  snprintf(macSuffix, sizeof(macSuffix), "%04X", (uint16_t)(mac & 0xffff));
  Serial.printf("BLE name: RideReader-%s\n", deviceId.substring(deviceId.length() - 4).c_str());
  Serial.printf("MAC suffix: %s\n", macSuffix);
  rc522Ready = initRc522();
  lastReinit = millis();
  setupBle();
}

void loop() {
  static uint32_t lastCardRead = 0;
  const uint32_t now = millis();
  if (now - lastCardRead >= 5) {
    lastCardRead = now;
    readCard();
  }
  if (connected && count && now - lastTapDelivery >= TAP_DELIVERY_INTERVAL_MS) {
    lastTapDelivery = now;
    sendTap(buffer[tail]);
  }
  if (!rc522Ready && now - lastReinit >= 5000) {
    lastReinit = now;
    rc522Ready = initRc522();
    if (!rc522Ready) pattern(1);
  }
}
