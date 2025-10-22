#include <Wire.h>
#include <Adafruit_SH110X.h>
#include <Adafruit_INA219.h>
#include "current.h"

#define CURRENT_HISTORY 100

Adafruit_INA219 ina219_current;
static float lastCurrent_mA_current = 0.0;
static CurrentMetrics currentHistory[CURRENT_HISTORY];
static int currentIndex = 0;
static unsigned long lastCurrentRead = 0;

void setupCurrentSensor(Adafruit_SH1106G& display) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SH110X_WHITE);
  display.setCursor(0, 0);
  display.println("Initializing Current sensor...");
  display.display();

  if (!ina219_current.begin()) {
    display.setCursor(0, 10);
    display.println("INA219 not found!");
    display.display();
    Serial.println("INA219 sensor not detected");
    delay(2000);
    return;
  }

  display.setCursor(0, 10);
  display.println("Current sensor ready!");
  display.display();
  Serial.println("Current sensor initialized");
  delay(1000);
}

CurrentMetrics readCurrentSensor(Adafruit_SH1106G& display) {
  CurrentMetrics m;
  float shuntV = ina219_current.getShuntVoltage_mV();
  float busV = ina219_current.getBusVoltage_V();
  float current = ina219_current.getCurrent_mA();
  float power = ina219_current.getPower_mW();

  m.busVoltageV = busV;
  m.shuntVoltagemV = shuntV;
  m.currentmA = current;
  m.powermW = power;
  m.timestamp = millis();

  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0,0);
  display.print("Bus V: "); display.print(busV); display.println(" V");
  display.print("Shunt mV: "); display.print(shuntV); display.println(" mV");
  display.print("Current mA: "); display.print(current); display.println(" mA");
  display.display();

  lastCurrent_mA_current = current;
  currentHistory[currentIndex] = m;
  currentIndex = (currentIndex + 1) % CURRENT_HISTORY;
  lastCurrentRead = millis();

  return m;
}

float readBusVoltage() {
  return ina219_current.getBusVoltage_V();
}

float readCurrent() {
  return lastCurrent_mA_current;
}

float readPower() {
  return ina219_current.getPower_mW();
}

float getLastCurrent() {
  return lastCurrent_mA_current;
}

CurrentMetrics getCurrentMetrics() {
  CurrentMetrics metrics;
  if (currentIndex == 0) {
    metrics = currentHistory[CURRENT_HISTORY-1];
  } else {
    metrics = currentHistory[(currentIndex-1+CURRENT_HISTORY)%CURRENT_HISTORY];
  }
  return metrics;
}
