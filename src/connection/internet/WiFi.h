#ifndef WIFI_CONNECTION_H
#define WIFI_CONNECTION_H

#include <Adafruit_SH110X.h>

void connectToWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password);
void setupWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password);
void handleWiFi(Adafruit_SH1106G& display, const char* ssid, const char* password);

#endif