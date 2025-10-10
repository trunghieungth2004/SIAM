#ifndef AWS_CONNECTION_H
#define AWS_CONNECTION_H

#include <Adafruit_SH110X.h>
#include <WiFiClientSecure.h>
#include <MQTTClient.h>

void messageHandler(String &topic, String &payload);
void connectToAWS(Adafruit_SH110X& display, WiFiClientSecure& net, MQTTClient& client, const char* THINGNAME, const char* AWS_IOT_ENDPOINT, const char* AWS_CERT_CA, const char* AWS_CERT_CRT, const char* AWS_CERT_PRIVATE);
void pingAWS(const char* AWS_IOT_ENDPOINT);
void handleAWS(Adafruit_SH110X& display, WiFiClientSecure& net, MQTTClient& client, const char* THINGNAME, const char* AWS_IOT_ENDPOINT, const char* AWS_CERT_CA, const char* AWS_CERT_CRT, const char* AWS_CERT_PRIVATE);
void queueData(float temperature, float vibration);
void sendToAWS(MQTTClient& client, float temperature, float vibration);
void syncQueuedData(MQTTClient& client);

#endif