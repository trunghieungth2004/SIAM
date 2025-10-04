#include <WiFiClientSecure.h>
#include <Adafruit_SH110X.h>
#include "WiFi.h"
#include "../../controllers/led/led.h"

void connectToWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SH110X_WHITE);
  display.setCursor(0, 0);
  display.println("Connecting to WiFi...");
  display.display();

  Serial.print("ESP32 connecting to Wi-Fi: ");
  Serial.println(ssid);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);

  int retries = 0;
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    
    if (retries++ > 20) {
      display.clearDisplay();
      display.setCursor(0,0);
      display.println("WiFi connection");
      display.println("failed. Retrying...");
      display.display();
      Serial.println("\nWiFi connection failed. Retrying...");
      delay(2000); 
      retries = 0;
      WiFi.begin(ssid, password);
    }
  }
  
  Serial.println();
  display.clearDisplay();
  display.setCursor(0,0);
  display.println("WiFi connected!");
  display.print("IP: ");
  display.println(WiFi.localIP());
  display.display();
  
  Serial.println("WiFi connected!");
  Serial.print("IP address: ");
  Serial.println(WiFi.localIP());
}

void setupWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password) {
    connectToWiFi(display, ssid, password); 
}

void handleWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password) {
  static unsigned long lastAttempt = 0;
  static int retryCount = 0;
  
  if (WiFi.status() != WL_CONNECTED) {
    if (millis() - lastAttempt > 500) {
      if (retryCount == 0) {
        Serial.println("\nWiFi disconnected. Reconnecting...");
        setConnectionStatus(STATUS_WIFI_CONNECTING);
        WiFi.mode(WIFI_STA);
        WiFi.begin(ssid, password);
      }
      
      Serial.print(".");
      retryCount++;
      lastAttempt = millis();
      
      if (retryCount >= 10) {
        if (WiFi.status() == WL_CONNECTED) {
          Serial.println("\nWiFi reconnected!");
          Serial.print("IP address: ");
          Serial.println(WiFi.localIP());
          setConnectionStatus(STATUS_WIFI_CONNECTED);
        } else {
          Serial.println("\nWiFi reconnection failed, will retry later");
          setConnectionStatus(STATUS_ERROR);
        }
        retryCount = 0;
      }
    }
  } else {
    retryCount = 0;
  }
}