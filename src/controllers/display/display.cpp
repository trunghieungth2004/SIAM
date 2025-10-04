#include <Adafruit_SH110X.h>
#include <WiFi.h>
#include "display.h"
#include "../led/led.h"
#include "../temperature/temperature.h"
#include "../vibration/vibration.h"

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_SDA 27
#define I2C_SCL 26
#define OLED_ADDR 0x3C
#define OLED_RESET -1

void setupDisplay(Adafruit_SH1106G& display) {
  setupLED();
  setConnectionStatus(STATUS_STARTING);
  
  Serial.println("Initializing I2C...");
  Wire.begin(I2C_SDA, I2C_SCL);

  Serial.println("Attempting to initialize SH1106 display...");
  if (!display.begin(OLED_ADDR, true)) {
    Serial.println(F("SH1106 allocation failed"));
    Serial.println(F("Please check:"));
    Serial.println(F("- Wiring: SDA, SCL, VCC, GND"));
    Serial.println(F("- I2C Address: Try 0x3D if 0x3C doesn't work"));

    while (true) {
      delay(1000);
    }
  }

  Serial.println("Display initialized successfully!");
  display.clearDisplay();
}

void displaySensorData(Adafruit_SH1106G& display) {
  float temperature = getLastTemperature();
  float vibration = getLastVibration();
  bool vibAlert = isVibrationAlert();
  
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SH110X_WHITE);
  
  display.setCursor(0, 0);
  display.println("IoT Sensor Monitor");
  
  display.setCursor(0, 12);
  display.print("Temp: ");
  if (temperature != -999.0) {
    display.print(temperature, 1);
    display.println("C");
  } else {
    display.println("ERROR");
  }
  
  display.setCursor(0, 24);
  display.print("Vibr: ");
  if (vibration != -999.0) {
    display.print(vibration, 1);
    display.println(" m/s2");
  } else {
    display.println("ERROR");
  }
  
  display.setCursor(0, 40);
  if (WiFi.status() == WL_CONNECTED) {
    display.print("WiFi: OK");
  } else {
    display.print("WiFi: --");
  }
  
  display.setCursor(0, 52);
  display.print("AWS: ");
  if (WiFi.status() == WL_CONNECTED && temperature != -999.0) {
    display.print("OK");
  } else {
    display.print("--");
  }
  
  if (vibAlert) {
    display.setCursor(80, 24);
    display.println("ALERT");
  }
  
  display.display();
}

void displayStartupScreen(Adafruit_SH1106G& display) {
  display.clearDisplay();
  display.setTextSize(2);
  display.setTextColor(SH110X_WHITE);
  display.setCursor(0, 10);
  display.println("IoT Device");
  display.setTextSize(1);
  display.setCursor(0, 35);
  display.println("Starting sensors...");
  display.display();
  delay(2000);
}