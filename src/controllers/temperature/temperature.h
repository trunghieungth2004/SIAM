#ifndef TEMPERATURE_CONTROLLER_H
#define TEMPERATURE_CONTROLLER_H

#include <Adafruit_SH110X.h>

struct TemperatureMetrics {
    float current;
    float average;
    float min;
    float max;
    float rateOfChange;
    float standardDeviation;
    unsigned long timestamp;
};

void setupTemperatureSensor(Adafruit_SH1106G& display);
float readTemperature(Adafruit_SH1106G& display);
float readTemperature();
float getLastTemperature();
TemperatureMetrics getTemperatureMetrics();
float calculateTemperatureRate();
bool detectTemperatureAnomaly();
float predictTemperatureTrend();
void calibrateTemperatureSensor();

#endif