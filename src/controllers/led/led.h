#ifndef LED_CONTROLLER_H
#define LED_CONTROLLER_H

#include <Arduino.h>

#define LED_RED_PIN 5
#define LED_GREEN_PIN 18
#define LED_BLUE_PIN 19

typedef enum {
    LED_OFF,
    LED_RED,
    LED_GREEN,
    LED_BLUE,
    LED_YELLOW,
    LED_PURPLE,
    LED_CYAN,
    LED_WHITE
} LEDColor;

typedef enum {
    STATUS_STARTING,
    STATUS_WIFI_CONNECTING,
    STATUS_WIFI_CONNECTED,
    STATUS_AWS_CONNECTING,
    STATUS_AWS_CONNECTED,
    STATUS_ERROR,
    STATUS_TEMPERATURE_ERROR
} ConnectionStatus;

void setupLED();
void setLEDColor(LEDColor color);
void setConnectionStatus(ConnectionStatus status);
void updateLEDStatus();
void blinkLED(LEDColor color, int times);

#endif