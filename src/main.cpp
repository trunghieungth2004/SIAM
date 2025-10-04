#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <ESP32Ping.h>
#include <WiFiClientSecure.h>
#include <MQTTClient.h>
#include <ArduinoJson.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <Adafruit_ADXL345_U.h>

#include "../src/connection/internet/WiFi.h"
#include "../src/connection/secret/WiFi_KEY.h"

#include "../src/connection/aws/AWS.h"
#include "../src/connection/secret/AWS_KEY.h"

#include "../src/controllers/led/led.h"
#include "../src/controllers/temperature/temperature.h"
#include "../src/controllers/vibration/vibration.h"
#include "../src/controllers/display/display.h"
 
#define PUBLISH_INTERVAL 4000

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1

Adafruit_SH1106G display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

WiFiClientSecure net = WiFiClientSecure();
MQTTClient client = MQTTClient(256);

unsigned long lastPublishTime = 0;
unsigned long lastReconnectAttempt = 0;
unsigned long lastTempReading = 0;
unsigned long lastVibrationReading = 0;
const unsigned long reconnectInterval = 30000;
const unsigned long tempInterval = 3000; 
const unsigned long vibrationInterval = 1000; 

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("Serial monitor connected.");

  setupLED();
  setConnectionStatus(STATUS_STARTING);

  setupDisplay(display);
  setupTemperatureSensor(display);
  setupVibrationSensor(display);

  setConnectionStatus(STATUS_WIFI_CONNECTING);
  setupWiFi(display, WIFI_SSID, WIFI_PASSWORD);
  
  if (WiFi.status() == WL_CONNECTED) {
    setConnectionStatus(STATUS_WIFI_CONNECTED);
    blinkLED(LED_BLUE, 2);
    delay(1000);
    
    Serial.println("WiFi connected, attempting AWS connection...");
    setConnectionStatus(STATUS_AWS_CONNECTING);
    delay(2000);
    connectToAWS(display, net, client, THINGNAME, AWS_IOT_ENDPOINT, AWS_CERT_CA, AWS_CERT_CRT, AWS_CERT_PRIVATE);
    
    if (client.connected()) {
      setConnectionStatus(STATUS_AWS_CONNECTED);
      blinkLED(LED_GREEN, 3);
    } else {
      setConnectionStatus(STATUS_ERROR);
    }
  } else {
    setConnectionStatus(STATUS_ERROR);
  }
  
  Serial.println("Setup complete.");
}

void loop() {
  updateLEDStatus();
  
  if (WiFi.status() != WL_CONNECTED) {
    handleWiFi(display, WIFI_SSID, WIFI_PASSWORD);
  } else {
    handleAWS(display, net, client, THINGNAME, AWS_IOT_ENDPOINT, AWS_CERT_CA, AWS_CERT_CRT, AWS_CERT_PRIVATE);
  }
  
  if (millis() - lastTempReading > tempInterval) {
    float temperature = readTemperature();
    if (temperature == -999.0) {
      setConnectionStatus(STATUS_TEMPERATURE_ERROR);
    } else if (WiFi.status() == WL_CONNECTED && client.connected()) {
      setConnectionStatus(STATUS_AWS_CONNECTED);
    } else if (WiFi.status() == WL_CONNECTED) {
      setConnectionStatus(STATUS_WIFI_CONNECTED);
    }
    lastTempReading = millis();
  }
  
  if (millis() - lastVibrationReading > vibrationInterval) {
    float magnitude = readVibration();
    lastVibrationReading = millis();
  }
  
  static unsigned long lastDisplayUpdate = 0;
  if (millis() - lastDisplayUpdate > 2000) {
    displaySensorData(display);
    lastDisplayUpdate = millis();
  }
  
  /*
  if (millis() - lastPublishTime > PUBLISH_INTERVAL) {
    float temp = getLastTemperature();
    sendToAWS(client, temp);
    lastPublishTime = millis();
  }
  */
  delay(100);
}