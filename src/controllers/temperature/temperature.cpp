#include <OneWire.h>
#include <DallasTemperature.h>
#include <Adafruit_SH110X.h>
#include "temperature.h"

#define ONE_WIRE_BUS 25
#define TEMPERATURE_PRECISION 12
#define HISTORY_SIZE 100
#define ANOMALY_THRESHOLD 2.0
#define RATE_THRESHOLD 0.5

OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature sensors(&oneWire);
DeviceAddress tempDeviceAddress;
static float lastTemperature = 0.0;
static float temperatureHistory[HISTORY_SIZE];
static int historyIndex = 0;
static float calibrationOffset = 0.0;
static unsigned long lastReadTime = 0;

void setupTemperatureSensor(Adafruit_SH1106G& display) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SH110X_WHITE);
  display.setCursor(0, 0);
  display.println("Initializing DS18B20...");
  display.display();
  
  sensors.begin();
  
  int deviceCount = sensors.getDeviceCount();
  
  display.setCursor(0, 10);
  display.print("Found ");
  display.print(deviceCount);
  display.println(" sensors");
  
  Serial.print("Found ");
  Serial.print(deviceCount, DEC);
  Serial.println(" DS18B20 devices");
  
  if (deviceCount > 0) {
    if (sensors.getAddress(tempDeviceAddress, 0)) {
      sensors.setResolution(tempDeviceAddress, TEMPERATURE_PRECISION);
      display.setCursor(0, 20);
      display.println("Sensor ready!");
      Serial.println("DS18B20 sensor initialized successfully");
    } else {
      display.setCursor(0, 20);
      display.println("Sensor error!");
      Serial.println("Unable to find address for Device 0");
    }
  } else {
    display.setCursor(0, 20);
    display.println("No sensors found!");
    Serial.println("No DS18B20 sensors found");
  }
  
  display.display();
  delay(2000);
}

float readTemperature(Adafruit_SH1106G& display) {
  sensors.requestTemperatures();
  
  float tempC = sensors.getTempCByIndex(0);
  
  if (tempC != DEVICE_DISCONNECTED_C) {
    display.clearDisplay();
    display.setTextSize(2);
    display.setTextColor(SH110X_WHITE);
    display.setCursor(0, 0);
    display.print("Temp:");
    display.setCursor(0, 20);
    display.print(tempC);
    display.println("C");
    
    float tempF = sensors.getTempFByIndex(0);
    display.setTextSize(1);
    display.setCursor(0, 45);
    display.print("(");
    display.print(tempF);
    display.println("F)");
    display.display();
    
    return tempC;
  } else {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SH110X_WHITE);
    display.setCursor(0, 0);
    display.println("Temperature");
    display.println("sensor error!");
    display.display();
    
    Serial.println("Error: Could not read temperature data");
    return -999.0;
  }
}

float getLastTemperature() {
  return lastTemperature;
}

float readTemperature() {
  sensors.requestTemperatures();
  delay(100);
  
  float tempSum = 0.0;
  int validReadings = 0;
  
  for (int i = 0; i < 5; i++) {
    sensors.requestTemperatures();
    delay(20);
    float tempC = sensors.getTempCByIndex(0);
    
    if (tempC != DEVICE_DISCONNECTED_C && tempC > -55.0 && tempC < 125.0) {
      tempSum += tempC;
      validReadings++;
    }
  }
  
  if (validReadings > 0) {
    float avgTemp = (tempSum / validReadings) + calibrationOffset;
    
    temperatureHistory[historyIndex] = avgTemp;
    historyIndex = (historyIndex + 1) % HISTORY_SIZE;
    
    lastTemperature = avgTemp;
    lastReadTime = millis();
    return avgTemp;
  } else {
    Serial.println("Error: Could not read temperature data");
    return -999.0;
  }
}

TemperatureMetrics getTemperatureMetrics() {
  TemperatureMetrics metrics;
  metrics.current = lastTemperature;
  metrics.timestamp = lastReadTime;
  
  float sum = 0.0, min = 999.0, max = -999.0;
  int validSamples = 0;
  
  for (int i = 0; i < HISTORY_SIZE; i++) {
    if (temperatureHistory[i] != 0.0) {
      sum += temperatureHistory[i];
      if (temperatureHistory[i] < min) min = temperatureHistory[i];
      if (temperatureHistory[i] > max) max = temperatureHistory[i];
      validSamples++;
    }
  }
  
  if (validSamples > 0) {
    metrics.average = sum / validSamples;
    metrics.min = min;
    metrics.max = max;
    
    float variance = 0.0;
    for (int i = 0; i < HISTORY_SIZE; i++) {
      if (temperatureHistory[i] != 0.0) {
        float diff = temperatureHistory[i] - metrics.average;
        variance += diff * diff;
      }
    }
    metrics.standardDeviation = sqrt(variance / validSamples);
  }
  
  metrics.rateOfChange = calculateTemperatureRate();
  return metrics;
}

float calculateTemperatureRate() {
  if (historyIndex < 10) return 0.0;
  
  int recentStart = (historyIndex - 10 + HISTORY_SIZE) % HISTORY_SIZE;
  float recentSum = 0.0, olderSum = 0.0;
  
  for (int i = 0; i < 5; i++) {
    recentSum += temperatureHistory[(recentStart + i + 5) % HISTORY_SIZE];
    olderSum += temperatureHistory[(recentStart + i) % HISTORY_SIZE];
  }
  
  return (recentSum / 5.0) - (olderSum / 5.0);
}

bool detectTemperatureAnomaly() {
  TemperatureMetrics metrics = getTemperatureMetrics();
  
  if (abs(metrics.current - metrics.average) > (ANOMALY_THRESHOLD * metrics.standardDeviation)) {
    return true;
  }
  
  if (abs(metrics.rateOfChange) > RATE_THRESHOLD) {
    return true;
  }
  
  return false;
}

float predictTemperatureTrend() {
  if (historyIndex < 20) return lastTemperature;
  
  float slope = 0.0, sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;
  int n = min(20, HISTORY_SIZE);
  
  for (int i = 0; i < n; i++) {
    int idx = (historyIndex - n + i + HISTORY_SIZE) % HISTORY_SIZE;
    if (temperatureHistory[idx] != 0.0) {
      sumX += i;
      sumY += temperatureHistory[idx];
      sumXY += i * temperatureHistory[idx];
      sumX2 += i * i;
    }
  }
  
  slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
  return lastTemperature + (slope * 10);
}

void calibrateTemperatureSensor() {
  float sum = 0.0;
  int readings = 0;
  
  for (int i = 0; i < 50; i++) {
    sensors.requestTemperatures();
    delay(50);
    float temp = sensors.getTempCByIndex(0);
    if (temp != DEVICE_DISCONNECTED_C) {
      sum += temp;
      readings++;
    }
  }
  
  if (readings > 0) {
    float measured = sum / readings;
    calibrationOffset = 25.0 - measured;
  }
}
