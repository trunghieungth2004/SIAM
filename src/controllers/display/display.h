#ifndef DISPLAY_CONTROLLER_H
#define DISPLAY_CONTROLLER_H

#include <Adafruit_SH110X.h>

void setupDisplay(Adafruit_SH1106G& display);
void displaySensorData(Adafruit_SH1106G& display);
void displayStartupScreen(Adafruit_SH1106G& display);

#endif