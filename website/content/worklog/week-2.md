---
title: "Week 2 Worklog"
date: 2025-09-15
draft: false
weight: 2
---

### Week 2 Objectives:
- Learn AWS IoT Core fundamentals and MQTT protocol
- Understand AWS IoT device connectivity and security
- Begin hardware prototyping with ESP32 microcontroller
- Design the initial SIAM system architecture
- Start sensor integration and testing

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn AWS IoT Core fundamentals: <br>  + IoT Things, Device Shadow <br>  + MQTT protocol basics <br>  + IoT Rules and Actions <br> - Study AWS IoT security model <br> - Understand X.509 certificates | 15/09/2025 | 15/09/2025 | [AWS IoT Core Documentation](https://docs.aws.amazon.com/iot/) <br> [https://cloudjourney.awsstudygroup.com/](https://cloudjourney.awsstudygroup.com/) |
| 2 | - **Practice:** Create first IoT Thing <br> - Generate device certificates <br> - Configure IoT policies <br> - Test MQTT connectivity with test client <br> - Learn about IoT Core message broker | 16/09/2025 | 16/09/2025 | [AWS IoT Core Getting Started](https://docs.aws.amazon.com/iot/latest/developerguide/) |
| 3 | - Set up ESP32 development environment: <br>  + Install Arduino IDE / PlatformIO <br>  + Install ESP32 board support <br>  + Install required libraries (PubSubClient, WiFi) <br> - Test ESP32 WiFi connectivity | 17/09/2025 | 17/09/2025 | [ESP32 Documentation](https://docs.espressif.com/projects/esp-idf/) |
| 4 | - Connect ESP32 to AWS IoT Core: <br>  + Configure X.509 certificates on ESP32 <br>  + Establish MQTT connection <br>  + Publish test messages to IoT Core <br> - Monitor messages in AWS console | 18/09/2025 | 18/09/2025 | ESP32 AWS IoT examples |
| 5 | - Begin sensor integration: <br>  + Wire MPU-6050 (accelerometer/gyroscope) to ESP32 <br>  + Wire INA219 (current/voltage sensor) to ESP32 <br>  + Wire DS18B20 (temperature sensor) to ESP32 <br> - Test individual sensor readings <br> - Publish sensor data to AWS IoT Core | 19/09/2025 | 20/09/2025 | Sensor datasheets <br> Arduino libraries |
| 6 | - Design SIAM system architecture: <br>  + Sketch edge-to-cloud data flow <br>  + Identify AWS services needed <br>  + Plan data ingestion pipeline <br> - Create initial architecture diagram <br> - Document design decisions | 21/09/2025 | 21/09/2025 | Project proposal requirements |

### Week 2 Achievements:

- **AWS IoT Core Mastery:**
  - Gained deep understanding of AWS IoT Core architecture
  - Learned MQTT protocol fundamentals (QoS levels, topics, pub/sub pattern)
  - Understood AWS IoT Thing Registry and Device Shadow concepts
  - Mastered IoT Rules Engine for routing messages to other AWS services
  - Studied IoT Core security model and certificate-based authentication

- **AWS IoT Hands-on Experience:**
  - Created first IoT Thing in AWS IoT Core named `ESP32_Prototype_01`
  - Generated and downloaded X.509 device certificates and private keys
  - Created and attached IoT policy with appropriate permissions:
    - `iot:Connect` - Allow device connections
    - `iot:Publish` - Publish to sensor data topics
    - `iot:Subscribe` - Subscribe to command topics
    - `iot:Receive` - Receive messages
  - Successfully tested MQTT connectivity using AWS IoT Test Client
  - Published test messages and verified receipt in AWS Console

- **ESP32 Development Setup:**
  - Installed Arduino IDE 2.0 and configured for ESP32 development
  - Installed ESP32 board support package via Board Manager
  - Installed required libraries:
    - `PubSubClient` - MQTT client library
    - `WiFi` - ESP32 WiFi management
    - `Adafruit_MPU6050` - Accelerometer/gyroscope
    - `Adafruit_INA219` - Current/voltage sensor
    - `OneWire` & `DallasTemperature` - DS18B20 temperature sensor
  - Successfully tested WiFi connectivity on ESP32

- **ESP32 to AWS IoT Integration:**
  - Embedded X.509 certificates in ESP32 code securely
  - Configured MQTT broker endpoint and port (8883 for TLS)
  - Established secure TLS connection from ESP32 to AWS IoT Core
  - Implemented MQTT publish/subscribe in ESP32 firmware
  - Successfully published sensor readings to topic `siam/sensors/data`
  - Verified end-to-end connectivity: ESP32 → MQTT → AWS IoT Core

- **Sensor Hardware Integration:**
  - Successfully wired MPU-6050 accelerometer/gyroscope to ESP32 via I2C:
    - VCC → 3.3V
    - GND → GND
    - SCL → GPIO 22
    - SDA → GPIO 21
  - Integrated INA219 current/voltage sensor via I2C (shared bus with MPU-6050)
  - Wired DS18B20 temperature sensor with 4.7kΩ pull-up resistor:
    - VCC → 3.3V
    - GND → GND
    - Data → GPIO 4
  - Tested individual sensor readings and verified data accuracy
  - Combined all sensor readings into single JSON payload
  - Published multi-sensor data to AWS IoT Core every 5 seconds

- **Sample Sensor Data Published:**
```json
{
  "device_id": "ESP32_Prototype_01",
  "timestamp": 1726000800,
  "mpu6050": {
    "accel_x": 0.12,
    "accel_y": -0.05,
    "accel_z": 9.81,
    "gyro_x": 0.01,
    "gyro_y": -0.02,
    "gyro_z": 0.00
  },
  "ina219": {
    "voltage": 12.3,
    "current": 0.45
  },
  "ds18b20": {
    "temperature": 23.5
  }
}
```

- **SIAM Architecture Design:**
  - Created initial system architecture diagram using draw.io
  - Designed hybrid edge-cloud architecture:
    - **Edge Layer:** Raspberry Pi 5 with Coral TPU
    - **IoT Layer:** AWS IoT Greengrass for edge runtime
    - **Ingestion Layer:** AWS IoT Core with Rules Engine
    - **Compute Layer:** AWS Lambda for serverless processing
    - **Storage Layer:** DynamoDB for real-time data, S3 for data lake
    - **ML Layer:** Amazon SageMaker for model training
    - **API Layer:** API Gateway for web dashboard
    - **Automation Layer:** EventBridge for scheduled retraining
  - Documented architecture decisions and rationale
  - Identified data flow: Sensor → Edge → IoT Core → Lambda → DynamoDB/S3

- **IoT Rules Engine Configuration:**
  - Created first IoT Rule to route sensor data
  - Configured SQL query: `SELECT * FROM 'siam/sensors/data'`
  - Added Lambda action to process incoming sensor messages
  - Tested rule activation and message routing

- **FCJ Mentor Interactions:**
  - Received guidance on AWS IoT best practices
  - Clarified questions about AWS Free Tier limits for IoT Core

### Challenges Encountered:

- **ESP32 Certificate Storage:** Limited flash memory for storing large X.509 certificates - solved by using SPIFFS filesystem
- **I2C Address Conflicts:** MPU-6050 and INA219 initially had I2C addressing issues - resolved by checking addresses with I2C scanner
- **MQTT Reconnection Logic:** ESP32 would not auto-reconnect on WiFi drops - implemented exponential backoff retry mechanism
- **Sensor Noise:** MPU-6050 accelerometer showed significant noise - applied simple moving average filter

### Key Learnings:

- MQTT is lightweight and ideal for IoT devices with limited bandwidth
- X.509 certificate-based authentication provides strong device security
- ESP32 is powerful for prototyping but not suitable for production (lacks offline buffer, limited processing)
- AWS IoT Core pricing is based on message count - need to optimize publish frequency
- Sensor calibration and noise filtering are critical for accurate ML model training

### Next Week Preview:

In Week 3, I will begin setting up the cloud infrastructure using automated shell scripts. This includes creating S3 buckets, DynamoDB tables, Lambda functions, and the foundational components of the SIAM backend. I'll also start learning about Infrastructure as Code principles.
