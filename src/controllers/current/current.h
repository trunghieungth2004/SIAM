#ifndef CURRENT_CONTROLLER_H
#define CURRENT_CONTROLLER_H

#include <Adafruit_SH110X.h>

struct CurrentMetrics {
    float busVoltageV;
    float shuntVoltagemV;
    float currentmA;
    float powermW;
    unsigned long timestamp;
};

void setupCurrentSensor(Adafruit_SH1106G& display);
CurrentMetrics readCurrentSensor(Adafruit_SH1106G& display);
float readBusVoltage();
float readCurrent();
float readPower();
float getLastCurrent();
CurrentMetrics getCurrentMetrics();

#endif
