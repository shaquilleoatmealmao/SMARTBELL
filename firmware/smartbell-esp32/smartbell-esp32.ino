// ============================================================================
//  smartbell-esp32.ino — SmartBell sensor firmware (ESP32 + BMX160 IMU)
//
//  What it does:
//    1. Reads the BMX160 accelerometer + gyroscope over I2C at 100 Hz.
//    2. Formats each reading as one CSV line:  ax,ay,az,gx,gy,gz,dt_s\n
//         ax..az  acceleration, m/s^2
//         gx..gz  angular rate, deg/s
//         dt_s    measured time since the previous read, s (nominally 0.010000)
//    3. Sends that line as a BLE notification on DATA_UUID, and echoes every
//       10th line to USB serial (115200 baud) for debugging.
//
//  The iOS app (SmartBell/Sensor/BLEManager.swift) scans for SERVICE_UUID,
//  subscribes to DATA_UUID, and parses lines with SensorSample.parse().
//  If you change the UUIDs or the CSV format, change them there too.
//
//  Wiring: BMX160 SDA -> GPIO 21, SCL -> GPIO 22, I2C address 0x69.
// ============================================================================

#include <Arduino.h>
#include <Wire.h>
#include <DFRobot_BMX160.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// BLE identity. Must match BLEManager.serviceUUID / dataUUID in the app.
static constexpr char DEVICE_NAME[] = "SmartBell";
static constexpr char SERVICE_UUID[] = "7b7e0001-9d8b-4f2a-a2b0-5c4e1a000001";
static constexpr char DATA_UUID[]    = "7b7e0002-9d8b-4f2a-a2b0-5c4e1a000001";

const int SDA_PIN = 21;
const int SCL_PIN = 22;
static constexpr uint32_t SAMPLE_PERIOD_US = 10000;  // 100 Hz target

// Timing state for the fixed-rate loop (microseconds, from micros()).
uint32_t nextSampleDueUs = 0;       // when the next read should happen
uint32_t previousSampleTimeUs = 0;  // when the last read actually happened (0 = none yet)

DFRobot_BMX160 bmx160(&Wire);
BLECharacteristic* dataCharacteristic = nullptr;

// When the phone disconnects, start advertising again so it can reconnect
// without power-cycling the ESP32.
class ServerCallbacks : public BLEServerCallbacks {
  void onDisconnect(BLEServer* server) override {
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(SDA_PIN, SCL_PIN);

  // Halt here (forever) if the IMU doesn't answer: nothing useful can be sent.
  if (!bmx160.begin(0x69)) {
    Serial.println("BMX160 not found. Check wiring and I2C address.");
    while (true) delay(1000);
  }

  // NOTE: smart-bell-v1's copy of this sketch calls
  //   bmx160.setGyroRange(eGyroRange_1000DPS);
  // right here. DFRobot's begin() leaves the chip at ±2000 °/s but the library
  // scales readings as if it were ±250 °/s, so without that call every gyro value
  // is 8x too small. This copy does not have the call; consider adding it back.

  // Set up the BLE GATT server: one service with one READ|NOTIFY characteristic.
  // MTU 100 so one ~60-byte CSV line fits in a single notification.
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(100);

  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);
  dataCharacteristic = service->createCharacteristic(
    DATA_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  // BLE2902 = Client Characteristic Configuration descriptor; required so the
  // phone can switch notifications on.
  dataCharacteristic->addDescriptor(new BLE2902());
  service->start();

  // Advertise the service UUID so the app's filtered scan can find us.
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();

  nextSampleDueUs = micros();

  Serial.println("Advertising as SmartBell. Scan from the app's Device tab.");
  Serial.println("ax,ay,az,gx,gy,gz,dt_s");
}

void loop() {
  // Schedule reads against a 10 ms clock instead of adding a fixed delay after BLE work.
  uint32_t nowUs = micros();
  int32_t waitUs = static_cast<int32_t>(nextSampleDueUs - nowUs);
  if (waitUs > 0) {
    delayMicroseconds(static_cast<uint32_t>(waitUs));
  }

  // Measure the real interval since the last read; the app uses this dt for
  // integration instead of assuming exactly 10 ms. (Unsigned subtraction also
  // handles micros() wrapping around every ~71 minutes.)
  const uint32_t sampleTimeUs = micros();
  const uint32_t deltaTimeUs = previousSampleTimeUs == 0
      ? SAMPLE_PERIOD_US
      : sampleTimeUs - previousSampleTimeUs;
  previousSampleTimeUs = sampleTimeUs;
  const float deltaTimeSeconds = deltaTimeUs / 1000000.0f;

  sBmx160SensorData_t accel;
  sBmx160SensorData_t gyro;

  // First argument is the magnetometer, which SmartBell doesn't use.
  bmx160.getAllData(nullptr, &gyro, &accel);

  // Acceleration: m/s^2; gyroscope: degrees/second; dt_s: measured sample interval.
  char row[100];
  snprintf(
    row, sizeof(row),
    "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.6f\n",
    accel.x, accel.y, accel.z,
    gyro.x, gyro.y, gyro.z,
    static_cast<double>(deltaTimeSeconds)
  );

  // Push the line to the phone (no-op if nobody is subscribed).
  dataCharacteristic->setValue((uint8_t*)row, strlen(row));
  dataCharacteristic->notify();

  // Throttle serial logging so diagnostics don't dominate the 100 Hz loop.
  static uint8_t serialDivider = 0;
  if (++serialDivider >= 10) {
    Serial.print(row);
    serialDivider = 0;
  }

  // Advance the schedule by exactly one period so the average rate stays at 100 Hz.
  nextSampleDueUs += SAMPLE_PERIOD_US;
  const uint32_t afterSendUs = micros();
  if (static_cast<int32_t>(afterSendUs - nextSampleDueUs) >= 0) {
    // If an I2C read or BLE notification overruns the next slot, resume from now and
    // report the longer measured interval in the next CSV row.
    nextSampleDueUs = afterSendUs + SAMPLE_PERIOD_US;
  }
}
