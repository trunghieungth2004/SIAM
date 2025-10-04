#ifndef VIBRATION_CONTROLLER_H
#define VIBRATION_CONTROLLER_H

#include <Adafruit_SH110X.h>

struct VibrationMetrics {
    float rms;
    float peak;
    float peakToPeak;
    float crestFactor;
    float kurtosis;
    float dominantFreq;
    float velocityRMS;
    float accelerationRMS;
    unsigned long timestamp;
};

enum MachineFault {
    NORMAL = 0,
    BEARING_WEAR = 1,
    MISALIGNMENT = 2, 
    UNBALANCE = 3,
    LOOSENESS = 4,
    CRITICAL_FAULT = 5
};

void setupVibrationSensor(Adafruit_SH1106G& display);
void readVibration(Adafruit_SH1106G& display);
float readVibration();
float getLastVibration();
bool isVibrationAlert();
float getVibrationMagnitude();
bool isVibrationDetected();
VibrationMetrics getVibrationMetrics();
float calculateRMSVibration();
float calculatePeakVibration();
float calculateCrestFactor();
float calculateKurtosis();
MachineFault classifyFault();
void performFFTAnalysis();
bool detectResonantFrequencies();
float predictRemainingUsefulLife();
void calibrateVibrationSensor();

#endif