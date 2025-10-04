#include <Adafruit_ADXL345_U.h>
#include <Adafruit_SH110X.h>
#include "vibration.h"

#define SAMPLE_SIZE 512
#define HISTORY_SIZE 100
#define BEARING_FREQ_LOW 10.0
#define BEARING_FREQ_HIGH 1000.0
#define MISALIGN_FREQ_LOW 1.0
#define MISALIGN_FREQ_HIGH 10.0

Adafruit_ADXL345_Unified accel = Adafruit_ADXL345_Unified(12345);

static float lastVibration = 0.0;
static bool vibrationAlert = false;
static float vibrationSamples[SAMPLE_SIZE];
static float vibrationHistory[HISTORY_SIZE];
static int sampleIndex = 0;
static int historyIndex = 0;
static float calibrationX = 0.0, calibrationY = 0.0, calibrationZ = 0.0;
static unsigned long lastSampleTime = 0;
const float VIBRATION_THRESHOLD = 2.0;

void setupVibrationSensor(Adafruit_SH1106G& display) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SH110X_WHITE);
  display.setCursor(0, 0);
  display.println("Initializing ADXL345...");
  display.display();
  
  if (!accel.begin()) {
    display.setCursor(0, 10);
    display.println("No ADXL345 detected!");
    display.setCursor(0, 20);
    display.println("Check wiring:");
    display.setCursor(0, 30);
    display.println("SDA->27, SCL->26");
    display.display();
    
    Serial.println("No ADXL345 sensor detected");
    Serial.println("Check I2C wiring:");
    Serial.println("- SDA: GPIO 27");
    Serial.println("- SCL: GPIO 26");
    Serial.println("- VCC: 3.3V");
    Serial.println("- GND: GND");
    delay(3000);
    return;
  }
  
  accel.setRange(ADXL345_RANGE_2_G);
  accel.setDataRate(ADXL345_DATARATE_3200_HZ);
  
  display.setCursor(0, 10);
  display.println("ADXL345 ready!");
  display.setCursor(0, 20);
  display.println("Range: +/-2G");
  display.setCursor(0, 30);
  display.println("Rate: 3200Hz");
  display.display();
  
  Serial.println("ADXL345 accelerometer initialized");
  Serial.println("Range set to +/-2G for maximum sensitivity");
  Serial.println("Data rate set to 3200Hz");
  
  calibrateVibrationSensor();
  
  delay(2000);
}

void readVibration(Adafruit_SH1106G& display) {
  sensors_event_t event;
  accel.getEvent(&event);
  
  float magnitude = sqrt(event.acceleration.x * event.acceleration.x + 
                        event.acceleration.y * event.acceleration.y + 
                        event.acceleration.z * event.acceleration.z);
  
  lastVibration = magnitude;
  
  if (magnitude > VIBRATION_THRESHOLD) {
    vibrationAlert = true;
    Serial.println("VIBRATION ALERT!");
  } else {
    vibrationAlert = false;
  }
  
  Serial.print("Vibration magnitude: ");
  Serial.print(magnitude, 2);
  Serial.print(" m/s² (X:");
  Serial.print(event.acceleration.x, 2);
  Serial.print(", Y:");
  Serial.print(event.acceleration.y, 2);
  Serial.print(", Z:");
  Serial.print(event.acceleration.z, 2);
  Serial.println(")");
}

float readVibration() {
  sensors_event_t event;
  accel.getEvent(&event);
  
  float x = event.acceleration.x - calibrationX;
  float y = event.acceleration.y - calibrationY;
  float z = event.acceleration.z - calibrationZ;
  
  float magnitude = sqrt(x*x + y*y + z*z);
  
  vibrationSamples[sampleIndex] = magnitude;
  sampleIndex = (sampleIndex + 1) % SAMPLE_SIZE;
  
  lastVibration = magnitude;
  lastSampleTime = millis();
  
  if (sampleIndex % 64 == 0) {
    float rms = calculateRMSVibration();
    vibrationHistory[historyIndex] = rms;
    historyIndex = (historyIndex + 1) % HISTORY_SIZE;
    
    if (rms > VIBRATION_THRESHOLD) {
      vibrationAlert = true;
    } else {
      vibrationAlert = false;
    }
  }
  
  return magnitude;
}

VibrationMetrics getVibrationMetrics() {
  VibrationMetrics metrics;
  metrics.rms = calculateRMSVibration();
  metrics.peak = calculatePeakVibration();
  metrics.peakToPeak = metrics.peak - (-metrics.peak);
  metrics.crestFactor = calculateCrestFactor();
  metrics.kurtosis = calculateKurtosis();
  metrics.timestamp = lastSampleTime;
  
  performFFTAnalysis();
  
  return metrics;
}

float calculateRMSVibration() {
  float sum = 0.0;
  for (int i = 0; i < SAMPLE_SIZE; i++) {
    sum += vibrationSamples[i] * vibrationSamples[i];
  }
  return sqrt(sum / SAMPLE_SIZE);
}

float calculatePeakVibration() {
  float peak = 0.0;
  for (int i = 0; i < SAMPLE_SIZE; i++) {
    if (abs(vibrationSamples[i]) > peak) {
      peak = abs(vibrationSamples[i]);
    }
  }
  return peak;
}

float calculateCrestFactor() {
  float rms = calculateRMSVibration();
  float peak = calculatePeakVibration();
  return (rms > 0) ? (peak / rms) : 0.0;
}

float calculateKurtosis() {
  float mean = 0.0, variance = 0.0, kurtosis = 0.0;
  
  for (int i = 0; i < SAMPLE_SIZE; i++) {
    mean += vibrationSamples[i];
  }
  mean /= SAMPLE_SIZE;
  
  for (int i = 0; i < SAMPLE_SIZE; i++) {
    float diff = vibrationSamples[i] - mean;
    variance += diff * diff;
    kurtosis += diff * diff * diff * diff;
  }
  variance /= SAMPLE_SIZE;
  kurtosis /= SAMPLE_SIZE;
  
  if (variance > 0) {
    return (kurtosis / (variance * variance)) - 3.0;
  }
  return 0.0;
}

MachineFault classifyFault() {
  VibrationMetrics metrics = getVibrationMetrics();
  
  if (metrics.rms > 10.0) {
    return CRITICAL_FAULT;
  }
  
  if (metrics.crestFactor > 6.0 && metrics.kurtosis > 3.0) {
    return BEARING_WEAR;
  }
  
  if (metrics.rms > 5.0 && metrics.crestFactor < 3.0) {
    return UNBALANCE;
  }
  
  if (metrics.rms > 3.0 && metrics.kurtosis < -1.0) {
    return MISALIGNMENT;
  }
  
  if (metrics.crestFactor > 4.0 && metrics.rms > 2.0) {
    return LOOSENESS;
  }
  
  return NORMAL;
}

void performFFTAnalysis() {
  float maxAmplitude = 0.0;
  float dominantFreq = 0.0;
  
  for (int k = 1; k < SAMPLE_SIZE/2; k++) {
    float real = 0.0, imag = 0.0;
    
    for (int n = 0; n < SAMPLE_SIZE; n++) {
      float angle = -2.0 * PI * k * n / SAMPLE_SIZE;
      real += vibrationSamples[n] * cos(angle);
      imag += vibrationSamples[n] * sin(angle);
    }
    
    float amplitude = sqrt(real*real + imag*imag);
    if (amplitude > maxAmplitude) {
      maxAmplitude = amplitude;
      dominantFreq = (float)k * 3200.0 / SAMPLE_SIZE;
    }
  }
}

bool detectResonantFrequencies() {
  return false;
}

float predictRemainingUsefulLife() {
  float trend = 0.0;
  int validSamples = 0;
  
  for (int i = 1; i < HISTORY_SIZE; i++) {
    if (vibrationHistory[i] > 0 && vibrationHistory[i-1] > 0) {
      trend += (vibrationHistory[i] - vibrationHistory[i-1]);
      validSamples++;
    }
  }
  
  if (validSamples > 0 && trend > 0) {
    float avgTrend = trend / validSamples;
    float currentLevel = calculateRMSVibration();
    float failureLevel = 15.0;
    
    return (failureLevel - currentLevel) / avgTrend;
  }
  
  return 10000.0;
}

void calibrateVibrationSensor() {
  float sumX = 0.0, sumY = 0.0, sumZ = 0.0;
  int samples = 100;
  
  for (int i = 0; i < samples; i++) {
    sensors_event_t event;
    accel.getEvent(&event);
    sumX += event.acceleration.x;
    sumY += event.acceleration.y;
    sumZ += event.acceleration.z;
    delay(10);
  }
  
  calibrationX = sumX / samples;
  calibrationY = sumY / samples;
  calibrationZ = (sumZ / samples) - 9.81;
}

float getLastVibration() {
  return lastVibration;
}

bool isVibrationAlert() {
  return vibrationAlert;
}

float getVibrationMagnitude() {
  return lastVibration;
}

bool isVibrationDetected() {
  return vibrationAlert;
}