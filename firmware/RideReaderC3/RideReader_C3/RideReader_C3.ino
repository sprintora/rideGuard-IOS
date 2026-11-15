// RideReader - ESP32-C3 version
// Lightweight RC522 card reader/writer module with BLE tap delivery.
// Requires: Arduino-ESP32 core 3.x, NimBLE-Arduino 2.x (h2zero), MFRC522 library.
// Board: "ESP32C3 Dev Module". Set "USB CDC On Boot: Enabled" only if DEBUG = 1.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <MFRC522.h>
#include <Preferences.h>
#include <SPI.h>
#include "config.h"

#if DEBUG
#define LOG(...) Serial.printf(__VA_ARGS__)
#else
#define LOG(...) do {} while (0)
#endif

#if BLE_REQUIRE_ENCRYPTION
#define WRITE_PROPS (NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC)
#else
#define WRITE_PROPS (NIMBLE_PROPERTY::WRITE)
#endif

struct Tap { uint32_t seq; uint8_t code[CARD_CODE_LENGTH]; uint32_t uptime; bool acknowledged; };

MFRC522 rfid(RC522_SS, RC522_RST);
Preferences prefs;
NimBLECharacteristic *tapCharacteristic = nullptr;
NimBLECharacteristic *statusCharacteristic = nullptr;

Tap buffer[TAP_BUFFER_SIZE];
uint8_t head = 0, tail = 0, count = 0;
uint32_t nextSequence = 1, lastTapAt = 0, lastReinit = 0, lastTapDelivery = 0;
uint8_t lastCode[CARD_CODE_LENGTH] = {};
volatile bool connected = false;
bool rc522Ready = false;
String deviceId;
bool enrollmentActive = false;
uint32_t enrollmentStartedAt = 0;
String enrollmentCode;
MFRC522::MIFARE_Key cardKey;

// The BLE host runs in its own FreeRTOS task, so shared state is guarded by a mutex
// (the C3 has one core, but tasks still preempt each other).
SemaphoreHandle_t stateMutex;
struct Lock {
  Lock() { xSemaphoreTake(stateMutex, portMAX_DELAY); }
  ~Lock() { xSemaphoreGive(stateMutex); }
};

// Requests coming from BLE callbacks are handled in loop() so GPIO/feedback stays single-threaded.
volatile int8_t pendingPattern = -1;
volatile bool pendingRestart = false;
volatile uint32_t restartAt = 0;

// ---------------- Feedback (non-blocking) ----------------
struct Beep { uint16_t freq; uint16_t onMs; uint16_t offMs; uint8_t reps; };
// 0 = success, 1 = warning/error, 2 = card error, 3 = buffer full / enroll ready
const Beep BEEPS[4] = {
  {2200, 100, 0, 1},
  {800, 300, 0, 1},
  {600, 150, 100, 2},
  {800, 80, 80, 3},
};
const Beep *curBeep = nullptr;
uint8_t beepLeft = 0;
bool beepOn = false;
uint32_t beepNextAt = 0;
uint32_t greenOffAt = 0, redOffAt = 0;
bool greenOn = false, redOn = false;

void statusLed(bool on) {
#if STATUS_LED_ACTIVE_LOW
  digitalWrite(STATUS_LED, on ? LOW : HIGH);
#else
  digitalWrite(STATUS_LED, on ? HIGH : LOW);
#endif
}

void buzzerWrite(bool on, uint16_t freq) {
#if BUZZER_ACTIVE
  (void)freq;
  digitalWrite(BUZZER, on ? HIGH : LOW);
#else
  if (on) tone(BUZZER, freq); else noTone(BUZZER);
#endif
}

void flashLed(uint8_t pin) {
  digitalWrite(pin, HIGH);
  if (pin == GREEN_LED) { greenOn = true; greenOffAt = millis() + LED_PULSE_MS; }
  else { redOn = true; redOffAt = millis() + LED_PULSE_MS; }
}

void pattern(uint8_t code) {
  if (code > 3) return;
  flashLed(code == 0 ? GREEN_LED : RED_LED);
  curBeep = &BEEPS[code];
  beepLeft = curBeep->reps;
  beepOn = true;
  buzzerWrite(true, curBeep->freq);
  beepNextAt = millis() + curBeep->onMs;
}

void requestPattern(uint8_t code) { pendingPattern = code; }

void updateFeedback(uint32_t now) {
  if (greenOn && (int32_t)(now - greenOffAt) >= 0) { digitalWrite(GREEN_LED, LOW); greenOn = false; }
  if (redOn && (int32_t)(now - redOffAt) >= 0) { digitalWrite(RED_LED, LOW); redOn = false; }
  if (!curBeep || (int32_t)(now - beepNextAt) < 0) return;
  if (beepOn) {
    buzzerWrite(false, 0);
    beepOn = false;
    if (--beepLeft == 0) { curBeep = nullptr; return; }
    beepNextAt = now + curBeep->offMs;
  } else {
    buzzerWrite(true, curBeep->freq);
    beepOn = true;
    beepNextAt = now + curBeep->onMs;
  }
}

void playStartupTone() {  // blocking, setup() only
  buzzerWrite(true, 1200); delay(100); buzzerWrite(false, 0); delay(30);
  buzzerWrite(true, 1800); delay(180); buzzerWrite(false, 0);
}

// ---------------- BLE helpers ----------------
String shortId() {
  const size_t n = deviceId.length();
  return n > 4 ? deviceId.substring(n - 4) : deviceId;
}

void sendTap(const Tap &tap) {
  if (!connected || tapCharacteristic == nullptr) return;
  uint8_t packet[8 + CARD_CODE_LENGTH];
  for (uint8_t i = 0; i < 4; ++i) packet[i] = (tap.seq >> (8 * i)) & 0xff;
  memcpy(packet + 4, tap.code, CARD_CODE_LENGTH);
  for (uint8_t i = 0; i < 4; ++i) packet[4 + CARD_CODE_LENGTH + i] = (tap.uptime >> (8 * i)) & 0xff;
  tapCharacteristic->setValue(packet, sizeof(packet));
  tapCharacteristic->notify();
}

void sendStatus(const String &status) {
  if (!connected || statusCharacteristic == nullptr) return;
  statusCharacteristic->setValue(reinterpret_cast<const uint8_t *>(status.c_str()), status.length());
  statusCharacteristic->notify();
}

// ---------------- Card access ----------------
void stopCard() {
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}

bool readCardCode(char *code) {
  byte block[18] = {};
  byte size = sizeof(block);
  if (rfid.PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A, CARD_DATA_BLOCK, &cardKey, &(rfid.uid)) != MFRC522::STATUS_OK) return false;
  if (rfid.MIFARE_Read(CARD_DATA_BLOCK, block, &size) != MFRC522::STATUS_OK) return false;
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) {
    const bool isLetter = block[i] >= 'A' && block[i] <= 'Z';
    const bool isDigit = block[i] >= '2' && block[i] <= '9';
    if (!isLetter && !isDigit) return false;
    code[i] = static_cast<char>(block[i]);
  }
  code[CARD_CODE_LENGTH] = '\0';
  return true;
}

bool writeAndVerifyCardCode(const String &code) {
  byte block[16];
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) block[i] = static_cast<byte>(code[i]);
  if (rfid.PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A, CARD_DATA_BLOCK, &cardKey, &(rfid.uid)) != MFRC522::STATUS_OK) {
    sendStatus("ENROLL_AUTH_FAILED");
    return false;
  }
  if (rfid.MIFARE_Write(CARD_DATA_BLOCK, block, sizeof(block)) != MFRC522::STATUS_OK) {
    sendStatus("ENROLL_WRITE_FAILED");
    return false;
  }
  byte verify[18] = {};
  byte size = sizeof(verify);
  if (rfid.MIFARE_Read(CARD_DATA_BLOCK, verify, &size) != MFRC522::STATUS_OK ||
      memcmp(verify, block, CARD_CODE_LENGTH) != 0) {
    sendStatus("ENROLL_VERIFY_FAILED");
    return false;
  }
  return true;
}

// ---------------- Tap buffer (call with stateMutex held) ----------------
void saveBuffer() {
  prefs.putBytes("buffer", buffer, sizeof(buffer));
  prefs.putUChar("head", head);
  prefs.putUChar("tail", tail);
  prefs.putUChar("count", count);
  prefs.putUInt("seq", nextSequence);
}

void acknowledge(uint32_t sequence) {
  Lock lock;
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

// ---------------- BLE callbacks ----------------
static String attToString(const NimBLEAttValue &v) {
  String s;
  s.reserve(v.size());
  for (size_t i = 0; i < v.size(); ++i) s += static_cast<char>(v.data()[i]);
  return s;
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &) override {
    connected = true;
    statusLed(true);
    requestPattern(0);
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    connected = false;
    statusLed(false);
    NimBLEDevice::getAdvertising()->start();
  }
};

class AckCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    const NimBLEAttValue v = c->getValue();
    if (v.size() != 4) return;
    const uint8_t *d = v.data();
    const uint32_t sequence = (uint32_t)d[0] | ((uint32_t)d[1] << 8) | ((uint32_t)d[2] << 16) | ((uint32_t)d[3] << 24);
    acknowledge(sequence);
  }
};

class FeedbackCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    const NimBLEAttValue v = c->getValue();
    if (v.size() != 1) return;
    const uint8_t code = v.data()[0];
    if (code <= 3) requestPattern(code);
  }
};

static bool validCardCode(const String &code) {
  if (code.length() != CARD_CODE_LENGTH) return false;
  for (uint8_t i = 0; i < CARD_CODE_LENGTH; ++i) {
    const char ch = code[i];
    if (!((ch >= 'A' && ch <= 'Z') || (ch >= '2' && ch <= '9'))) return false;
  }
  return true;
}

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    const String value = attToString(c->getValue());
    if (value == "PING") {
      requestPattern(0);
    } else if (value.startsWith("ENROLL:")) {
      const String code = value.substring(7);
      if (!validCardCode(code)) {
        sendStatus("ENROLL_INVALID_CODE");
        return;
      }
      {
        Lock lock;
        enrollmentCode = code;
        enrollmentActive = true;
        enrollmentStartedAt = millis();
      }
      sendStatus("ENROLL_READY");
      requestPattern(3);
    } else if (value.startsWith("NAME:")) {
      const String name = value.substring(5);
      if (name.length() < 4 || name.length() >= 32) {
        sendStatus("NAME_INVALID");
        return;
      }
      {
        Lock lock;
        deviceId = name;
        prefs.putString("device", deviceId);
      }
      restartAt = millis() + 300;
      pendingRestart = true;
    } else if (value == "FACTORY_RESET") {
      {
        Lock lock;
        prefs.clear();
      }
      restartAt = millis() + 300;
      pendingRestart = true;
    }
  }
};

void setupBle() {
  const String bleName = "RideReader-" + shortId();
  NimBLEDevice::init(bleName.c_str());
  NimBLEDevice::setMTU(BLE_MTU);
#if BLE_REQUIRE_ENCRYPTION
  NimBLEDevice::setSecurityAuth(true, false, true);  // bonding, no MITM, secure connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
#endif
  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService *service = server->createService(BLE_SERVICE_UUID);

  tapCharacteristic = service->createCharacteristic(BLE_TAP_UUID, NIMBLE_PROPERTY::NOTIFY);

  NimBLECharacteristic *ack = service->createCharacteristic(BLE_ACK_UUID, WRITE_PROPS);
  ack->setCallbacks(new AckCallbacks());

  NimBLECharacteristic *feedback = service->createCharacteristic(BLE_FEEDBACK_UUID, WRITE_PROPS);
  feedback->setCallbacks(new FeedbackCallbacks());

  NimBLECharacteristic *info = service->createCharacteristic(BLE_INFO_UUID, NIMBLE_PROPERTY::READ);
  const String infoText = deviceId + "," + FIRMWARE_VERSION + "," + String(lastTapAt);
  info->setValue(reinterpret_cast<const uint8_t *>(infoText.c_str()), infoText.length());

  NimBLECharacteristic *control = service->createCharacteristic(BLE_CONTROL_UUID, WRITE_PROPS);
  control->setCallbacks(new ControlCallbacks());

  statusCharacteristic = service->createCharacteristic(BLE_STATUS_UUID, NIMBLE_PROPERTY::NOTIFY);

  server->start();  // NimBLE 2.x: start after all services are created
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->enableScanResponse(true);
  advertising->start();
}

// ---------------- RC522 ----------------
bool initRc522() {
  rfid.PCD_Init();
  const byte version = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  if (version == 0x00 || version == 0xff) {
    LOG("RC522 not found - check wiring\n");
    return false;
  }
  LOG("RC522 OK, version 0x%02X\n", version);
  flashLed(GREEN_LED);
  return true;
}

void readCard() {
  if (!rc522Ready) return;
  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) return;
  if (rfid.uid.size == 0 || rfid.uid.size > 10) {
    stopCard(); pattern(1); return;
  }

  bool enrolling;
  String codeToWrite;
  {
    Lock lock;
    enrolling = enrollmentActive;
    codeToWrite = enrollmentCode;
  }

  if (enrolling) {
    sendStatus("ENROLL_WRITING");
    if (writeAndVerifyCardCode(codeToWrite)) {
      { Lock lock; enrollmentActive = false; }
      sendStatus("ENROLL_SUCCESS:" + codeToWrite);
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
  const bool duplicate = now - lastTapAt < DEBOUNCE_MS && memcmp(lastCode, code, CARD_CODE_LENGTH) == 0;
  if (!duplicate) {
    bool full = false;
    Tap tap;
    {
      Lock lock;
      if (count == TAP_BUFFER_SIZE) {
        full = true;
      } else {
        Tap &slot = buffer[head];
        slot.seq = nextSequence++;
        memcpy(slot.code, code, CARD_CODE_LENGTH);
        slot.uptime = now;
        slot.acknowledged = false;
        head = (head + 1) % TAP_BUFFER_SIZE;
        ++count;
        memcpy(lastCode, slot.code, CARD_CODE_LENGTH);
        lastTapAt = now;
        saveBuffer();
        tap = slot;
      }
    }
    if (full) {
      pattern(3);
    } else {
      sendTap(tap);
      pattern(0);
    }
  }
  stopCard();
}

void checkEnrollmentTimeout(uint32_t now) {
  bool timedOut = false;
  {
    Lock lock;
    if (enrollmentActive && now - enrollmentStartedAt >= ENROLLMENT_TIMEOUT_MS) {
      enrollmentActive = false;
      timedOut = true;
    }
  }
  if (timedOut) {
    sendStatus("ENROLL_TIMEOUT");
    pattern(1);
  }
}

// ---------------- Arduino entry points ----------------
void setup() {
  setCpuFrequencyMhz(CPU_FREQ_MHZ);
  stateMutex = xSemaphoreCreateMutex();

  pinMode(GREEN_LED, OUTPUT); pinMode(RED_LED, OUTPUT);
  pinMode(BUZZER, OUTPUT); pinMode(STATUS_LED, OUTPUT);
  digitalWrite(GREEN_LED, LOW); digitalWrite(RED_LED, LOW);
  buzzerWrite(false, 0); statusLed(false);
  playStartupTone();

#if DEBUG
  Serial.begin(115200);
#endif

  prefs.begin("ride-reader", false);
  const byte configuredKey[6] = CARD_KEY_A;
  memcpy(cardKey.keyByte, configuredKey, sizeof(configuredKey));
  deviceId = prefs.getString("device", DEVICE_ID_DEFAULT);
  nextSequence = prefs.getUInt("seq", 1);
  head = prefs.getUChar("head", 0);
  tail = prefs.getUChar("tail", 0);
  count = prefs.getUChar("count", 0);
  const bool bufferValid = prefs.getBytesLength("buffer") == sizeof(buffer) &&
                           head < TAP_BUFFER_SIZE && tail < TAP_BUFFER_SIZE && count <= TAP_BUFFER_SIZE;
  if (bufferValid) {
    prefs.getBytes("buffer", buffer, sizeof(buffer));
  } else {
    memset(buffer, 0, sizeof(buffer));
    head = tail = count = 0;
    saveBuffer();
  }

  SPI.begin(RC522_SCK, RC522_MISO, RC522_MOSI, RC522_SS);
  LOG("BLE name: RideReader-%s\n", shortId().c_str());
  rc522Ready = initRc522();
  lastReinit = millis();
  setupBle();
}

void loop() {
  static uint32_t lastCardRead = 0;
  const uint32_t now = millis();

  if (pendingPattern >= 0) {
    const int8_t p = pendingPattern;
    pendingPattern = -1;
    pattern(static_cast<uint8_t>(p));
  }
  if (pendingRestart && (int32_t)(now - restartAt) >= 0) ESP.restart();

  checkEnrollmentTimeout(now);

  if (now - lastCardRead >= CARD_POLL_MS) {
    lastCardRead = now;
    readCard();
  }

  if (connected && now - lastTapDelivery >= TAP_DELIVERY_INTERVAL_MS) {
    Tap pending;
    bool have = false;
    {
      Lock lock;
      if (count) { pending = buffer[tail]; have = true; }
    }
    lastTapDelivery = now;
    if (have) sendTap(pending);
  }

  if (!rc522Ready && now - lastReinit >= 5000) {
    lastReinit = now;
    rc522Ready = initRc522();
    if (!rc522Ready) pattern(1);
  }

  updateFeedback(millis());
  delay(2);  // yield to the BLE task / idle task; lets the C3 idle between polls
}
