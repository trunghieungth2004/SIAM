#include "led.h"

static ConnectionStatus currentStatus = STATUS_STARTING;
static LEDColor blinkColor = LED_OFF;

void setupLED() {
  pinMode(LED_RED_PIN, OUTPUT);
  pinMode(LED_GREEN_PIN, OUTPUT);
  pinMode(LED_BLUE_PIN, OUTPUT);
  setLEDColor(LED_OFF);
}

void setLEDColor(LEDColor color) {
  digitalWrite(LED_RED_PIN, LOW);
  digitalWrite(LED_GREEN_PIN, LOW);
  digitalWrite(LED_BLUE_PIN, LOW);
  
  switch(color) {
    case LED_RED:
      digitalWrite(LED_RED_PIN, HIGH);
      break;
    case LED_GREEN:
      digitalWrite(LED_GREEN_PIN, HIGH);
      break;
    case LED_BLUE:
      digitalWrite(LED_BLUE_PIN, HIGH);
      break;
    case LED_YELLOW:
      digitalWrite(LED_RED_PIN, HIGH);
      digitalWrite(LED_GREEN_PIN, HIGH);
      break;
    case LED_PURPLE:
      digitalWrite(LED_RED_PIN, HIGH);
      digitalWrite(LED_BLUE_PIN, HIGH);
      break;
    case LED_CYAN:
      digitalWrite(LED_GREEN_PIN, HIGH);
      digitalWrite(LED_BLUE_PIN, HIGH);
      break;
    case LED_WHITE:
      digitalWrite(LED_RED_PIN, HIGH);
      digitalWrite(LED_GREEN_PIN, HIGH);
      digitalWrite(LED_BLUE_PIN, HIGH);
      break;
    default:
      break;
  }
}

void setConnectionStatus(ConnectionStatus status) {
  currentStatus = status;
}

void updateLEDStatus() {
  static unsigned long lastBlink = 0;
  static bool blinkState = false;
  
  if (blinkColor != LED_OFF) {
    if (millis() - lastBlink > 300) {
      blinkState = !blinkState;
      setLEDColor(blinkState ? blinkColor : LED_OFF);
      lastBlink = millis();
    }
    return;
  }
  
  switch (currentStatus) {
    case STATUS_STARTING:
      if (millis() % 1000 < 500) {
        setLEDColor(LED_WHITE);
      } else {
        setLEDColor(LED_OFF);
      }
      break;
      
    case STATUS_WIFI_CONNECTING:
      if (millis() % 1000 < 500) {
        setLEDColor(LED_BLUE);
      } else {
        setLEDColor(LED_OFF);
      }
      break;
      
    case STATUS_WIFI_CONNECTED:
      setLEDColor(LED_BLUE);
      break;
      
    case STATUS_AWS_CONNECTING:
      if (millis() % 800 < 400) {
        setLEDColor(LED_YELLOW);
      } else {
        setLEDColor(LED_OFF);
      }
      break;
      
    case STATUS_AWS_CONNECTED:
      setLEDColor(LED_GREEN);
      break;
      
    case STATUS_ERROR:
      if (millis() % 600 < 300) {
        setLEDColor(LED_RED);
      } else {
        setLEDColor(LED_OFF);
      }
      break;
      
    case STATUS_TEMPERATURE_ERROR:
      if (millis() % 400 < 200) {
        setLEDColor(LED_PURPLE);
      } else {
        setLEDColor(LED_OFF);
      }
      break;
  }
}

void blinkLED(LEDColor color, int times) {
  for (int i = 0; i < times; i++) {
    setLEDColor(color);
    delay(200);
    setLEDColor(LED_OFF);
    delay(200);
  }
}
