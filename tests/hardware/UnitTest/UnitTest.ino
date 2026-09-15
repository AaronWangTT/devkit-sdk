#include "Arduino.h"
#include "ArduinoUnit.h"
#include "OTAFirmwareUpdate.h"
#include "HTS221Sensor.h"
#include "lis2mdlSensor.h"
#include "LSM6DSLSensor.h"
#include "RGB_LED.h"
#include "AZ3166WiFi.h"
#include "SystemWiFi.h"
#include "PinNames.h"
#include "config.h"

extern "C" int OTAHeaderCLinkTest(void);
int OTAHeaderCppLinkTest();

test(ota_api_linkage)
{
    assertTrue(OTAHeaderCLinkTest());
    assertTrue(OTAHeaderCppLinkTest());
}

void setup() {
  I2CInit();
}

void loop() {
  Test::run();
}
