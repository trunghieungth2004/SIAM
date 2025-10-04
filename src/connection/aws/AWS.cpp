#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <MQTTClient.h>
#include <WiFiClientSecure.h>
#include <ESP32Ping.h>
#include <ArduinoJson.h>
#include "AWS.h"
#include "../../controllers/led/led.h"

#define AWS_IOT_PUBLISH_TOPIC "esp32/esp32-to-aws"
#define AWS_IOT_SUBSCRIBE_TOPIC "esp32/aws-to-esp32"
#define PUBLISH_INTERVAL 4000
#define MAX_QUEUE_SIZE 50

struct DataPoint {
  unsigned long timestamp;
  float temperature;
  float data;
};

static DataPoint dataQueue[MAX_QUEUE_SIZE];
static int queueHead = 0;
static int queueTail = 0;
static int queueCount = 0;

void queueData(float temperature, float data);
void syncQueuedData(MQTTClient& client);

void messageHandler(String &topic, String &payload) {
  Serial.println("received:");
  Serial.println("- topic: " + topic);
  Serial.println("- payload:");
  Serial.println(payload);
}

void connectToAWS(Adafruit_SH110X& display, WiFiClientSecure& net, MQTTClient& client, const char* THINGNAME, const char* AWS_IOT_ENDPOINT, const char* AWS_CERT_CA, const char* AWS_CERT_CRT, const char* AWS_CERT_PRIVATE) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi not connected, cannot connect to AWS");
    return;
  }
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println("Connecting to AWS...");
  display.display();
  net.setCACert(AWS_CERT_CA);
  net.setCertificate(AWS_CERT_CRT);
  net.setPrivateKey(AWS_CERT_PRIVATE);

  client.begin(AWS_IOT_ENDPOINT, 8883, net);
  client.onMessage(messageHandler);
  client.setKeepAlive(60);  // Send keepalive every 60 seconds
  client.setTimeout(5000);   // 5 second timeout

  Serial.print("ESP32 connecting to AWS IOT");

  int attempts = 0;
  const int maxAttempts = 30;
  
  while (!client.connect(THINGNAME) && attempts < maxAttempts) {
    Serial.print(".");
    delay(200);
    attempts++;
  }
  Serial.println();

  if (!client.connected()) {
    Serial.println("ESP32 - AWS IoT Timeout!");
    Serial.print("Last error: ");
    Serial.println(client.lastError());
    return;
  }

  client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
  Serial.println("ESP32 - AWS IoT Connected!");
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println("AWS IoT Connected!");
  display.display();
}

void pingAWS(const char* AWS_IOT_ENDPOINT) {
  bool success = Ping.ping(AWS_IOT_ENDPOINT, 3);
  Serial.print("Pinging AWS IoT endpoint... ");

  if(!success){
    Serial.println("Ping failed");
    return;
  }
  Serial.println("Ping successful.");
}

void handleAWS(Adafruit_SH110X& display, WiFiClientSecure& net, MQTTClient& client, const char* THINGNAME, const char* AWS_IOT_ENDPOINT, const char* AWS_CERT_CA, const char* AWS_CERT_CRT, const char* AWS_CERT_PRIVATE) {
  static unsigned long lastAttempt = 0;
  static int retryCount = 0;
  static bool connecting = false;
  
  if (WiFi.status() != WL_CONNECTED) {
    connecting = false;
    retryCount = 0;
    return;
  }
  
  if (!client.connected()) {
    if (millis() - lastAttempt > 500) {
      if (retryCount == 0) {
        Serial.print("AWS disconnected. Error: ");
        Serial.print(client.lastError());
        Serial.println(". Reconnecting...");
        connecting = true;
        net.setCACert(AWS_CERT_CA);
        net.setCertificate(AWS_CERT_CRT);
        net.setPrivateKey(AWS_CERT_PRIVATE);
        client.begin(AWS_IOT_ENDPOINT, 8883, net);
        client.onMessage(messageHandler);
        client.setKeepAlive(60);
        client.setTimeout(5000);
      }
      
      if (connecting) {
        if (client.connect(THINGNAME)) {
          Serial.println("AWS IoT reconnected!");
          client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
          connecting = false;
          retryCount = 0;
          setConnectionStatus(STATUS_AWS_CONNECTED);
          return;
        }
        Serial.print(".");
        retryCount++;
        lastAttempt = millis();
        
        if (retryCount >= 30) {
          Serial.print("AWS reconnection failed. Last error: ");
          Serial.println(client.lastError());
          connecting = false;
          retryCount = 0;
          setConnectionStatus(STATUS_ERROR);
        } else if (retryCount == 1) {
          setConnectionStatus(STATUS_AWS_CONNECTING);
        }
      }
    }
  } else {
    connecting = false;
    retryCount = 0;
    client.loop();
  }
}

void queueData(float temperature, float data) {
  if (queueCount < MAX_QUEUE_SIZE) {
    dataQueue[queueTail].timestamp = millis();
    dataQueue[queueTail].temperature = temperature;
    dataQueue[queueTail].data = data;
    queueTail = (queueTail + 1) % MAX_QUEUE_SIZE;
    queueCount++;
  } else {
    queueHead = (queueHead + 1) % MAX_QUEUE_SIZE;
    dataQueue[queueTail].timestamp = millis();
    dataQueue[queueTail].temperature = temperature;
    dataQueue[queueTail].data = data;
    queueTail = (queueTail + 1) % MAX_QUEUE_SIZE;
  }
}

void sendToAWS(MQTTClient& client, float temperature) {
  StaticJsonDocument<512> message;
  message["timestamp"] = millis();
  message["temperature"] = temperature;
  message["data"] = analogRead(A0);
  char messageBuffer[512];
  serializeJson(message, messageBuffer);

  if (client.connected()) {
    client.publish(AWS_IOT_PUBLISH_TOPIC, messageBuffer);
    Serial.println("sent:");
    Serial.print("- topic: ");
    Serial.println(AWS_IOT_PUBLISH_TOPIC);
    Serial.print("- payload:");
    Serial.println(messageBuffer);
  } else {
    queueData(temperature, analogRead(A0));
    Serial.println("AWS disconnected, data queued");
  }
}

void syncQueuedData(MQTTClient& client) {
  if (!client.connected() || queueCount == 0) return;
  
  static unsigned long lastSync = 0;
  if (millis() - lastSync < 1000) return;
  
  DataPoint& data = dataQueue[queueHead];
  StaticJsonDocument<512> message;
  message["timestamp"] = data.timestamp;
  message["temperature"] = data.temperature;
  message["data"] = data.data;
  char messageBuffer[512];
  serializeJson(message, messageBuffer);
  
  if (client.publish(AWS_IOT_PUBLISH_TOPIC, messageBuffer)) {
    Serial.println("synced queued data");
    queueHead = (queueHead + 1) % MAX_QUEUE_SIZE;
    queueCount--;
    lastSync = millis();
  }
}