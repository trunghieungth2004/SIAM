---
title: "Week 7 Worklog"
date: 2025-10-20
draft: false
weight: 7
---

### Week 7 Objectives:
- Master AWS IoT Greengrass component development
- Convert local datalogger to Greengrass component
- Implement Greengrass Stream Manager for data buffering
- Set up Docker on Raspberry Pi for ML inference container
- Deploy and test Greengrass components on the edge device

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn AWS IoT Greengrass V2 architecture: <br>  + Components and recipes <br>  + Nucleus and component lifecycle <br>  + Local pub/sub messaging <br>  + Stream Manager <br> - Study component recipe JSON schema | 20/10/2025 | 20/10/2025 | [AWS Greengrass V2 Documentation](https://docs.aws.amazon.com/greengrass/v2/) |
| 2 | - Convert local_datalogger.c to Greengrass component: <br>  + Modify code to use Stream Manager SDK <br>  + Create component recipe JSON <br>  + Test local compilation <br> - Implement graceful shutdown handling | 21/10/2025 | 21/10/2025 | Greengrass SDK documentation |
| 3 | - Create DataLogger Greengrass component: <br>  + Write component recipe <br>  + Configure lifecycle scripts <br>  + Set up Stream Manager stream <br>  + Upload artifacts to S3 <br> - Deploy component to Raspberry Pi | 22/10/2025 | 22/10/2025 | Component development guide |
| 4 | - Set up Docker on Raspberry Pi: <br>  + Install Docker Engine <br>  + Configure Docker daemon <br>  + Add pi user to docker group <br>  + Test container runtime <br> - Pull TensorFlow Lite runtime image | 23/10/2025 | 23/10/2025 | [Docker Documentation](https://docs.docker.com/) |
| 5 | - Develop ML Inference Docker container: <br>  + Create Dockerfile with Coral TPU support <br>  + Implement inference service in Python <br>  + Integrate Stream Manager consumer <br>  + Add model loading and prediction <br> - Test container locally | 24/10/2025 | 25/10/2025 | Coral TPU documentation |
| 6 | - Create MLInference Greengrass component: <br>  + Write component recipe for Docker <br>  + Configure Docker container lifecycle <br>  + Deploy model artifact from S3 <br>  + Test end-to-end data flow <br> - Monitor component logs | 26/10/2025 | 26/10/2025 | Greengrass Docker integration |

### Week 7 Achievements:

- **AWS IoT Greengrass V2 Architecture:**
  - Mastered Greengrass Core concepts:
    - **Nucleus:** Core runtime engine, manages component lifecycle
    - **Components:** Modular software units (native, Docker, Lambda)
    - **Recipes:** JSON configuration defining component behavior
    - **Deployments:** Push updates to Greengrass devices/groups
    - **Local Pub/Sub:** IPC for inter-component communication
    - **Stream Manager:** Local data buffering and cloud sync
  - Understood component lifecycle:
    - NEW → INSTALLED → STARTING → RUNNING → STOPPING → FINISHED
    - Automatic restart on failure (configurable)
  - Learned recipe schema:
    - ComponentName, ComponentVersion
    - Manifests (platform-specific)
    - Lifecycle scripts (Install, Run, Shutdown)
    - Artifacts (code, binaries, models)
    - ComponentDependencies

- **Greengrass Stream Manager Deep Dive:**
  - Learned Stream Manager capabilities:
    - Local persistent message buffer (disk-backed)
    - Automatic export to AWS IoT Core, Kinesis, IoT Analytics
    - Offline resilience (buffers when disconnected)
    - Configurable retention (size, age)
  - Configured stream parameters:
    - Strategy: `StrategyOnFull.RejectNewData`
    - Persistence: `Persisted to disk`
    - Flush on write: `false` (batch for efficiency)
    - Export to IoT Core: `true`
  - Benefits for SIAM:
    - Zero data loss during network outages
    - Decouples data collection from cloud connectivity
    - Local stream acts as message bus between components

- **DataLogger Greengrass Component:**
  - Converted `local_datalogger.c` to use Stream Manager:
    ```c
    #include <stream_manager.h>
    
    int main() {
        StreamManagerClient client = create_stream_manager_client();
        
        while (running) {
            SensorData data = read_sensors();
            char json_payload[512];
            snprintf(json_payload, sizeof(json_payload),
                "{\"device_id\":\"%s\",\"timestamp\":%llu,\"accel_x\":%.3f,...}",
                DEVICE_ID, get_timestamp(), data.accel_x);
            
            append_to_stream(client, "SensorDataStream", json_payload);
            sleep(1);
        }
    }
    ```
  - Implemented signal handling for graceful shutdown (SIGTERM, SIGINT)
  - Created component recipe `com.siam.DataLogger-1.0.0.json`:
    ```json
    {
      "RecipeFormatVersion": "2020-01-25",
      "ComponentName": "com.siam.DataLogger",
      "ComponentVersion": "1.0.0",
      "ComponentDescription": "Native C datalogger with Stream Manager",
      "ComponentPublisher": "SIAM",
      "ComponentDependencies": {
        "aws.greengrass.StreamManager": {
          "VersionRequirement": "^2.0.0"
        }
      },
      "Manifests": [
        {
          "Platform": {
            "os": "linux",
            "architecture": "arm64"
          },
          "Lifecycle": {
            "Install": "chmod +x {artifacts:path}/datalogger",
            "Run": "{artifacts:path}/datalogger"
          },
          "Artifacts": [
            {
              "URI": "s3://siam-demo-components/datalogger-arm64"
            }
          ]
        }
      ]
    }
    ```
  - Compiled for ARM64: `gcc -o datalogger datalogger.c -lstream_manager -lpthread`
  - Uploaded binary to S3 component bucket
  - Deployed component to Raspberry Pi via Greengrass console

- **Docker Setup on Raspberry Pi:**
  - Installed Docker Engine:
    ```bash
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker pi
    sudo systemctl enable docker
    ```
  - Configured Docker daemon for Greengrass:
    - Added `ggc_user` to docker group
    - Set resource limits (memory: 512MB)
  - Tested Docker installation:
    ```bash
    docker run hello-world
    ```
  - Pulled base images:
    - `python:3.9-slim-bullseye` - Lightweight Python runtime
    - Downloaded Coral TPU libraries manually (PyCoral, TensorFlow Lite)

- **ML Inference Docker Container:**
  - Created `Dockerfile.tpu` with Coral TPU support:
    ```dockerfile
    FROM python:3.9-slim-bullseye
    
    # Install Coral TPU runtime libraries
    RUN echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" > /etc/apt/sources.list.d/coral-edgetpu.list && \
        curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - && \
        apt-get update && \
        apt-get install -y libedgetpu1-std python3-pycoral && \
        apt-get clean
    
    # Install Python dependencies
    RUN pip install --no-cache-dir \
        paho-mqtt \
        numpy \
        boto3
    
    # Copy inference service code
    COPY tpu_inference_service.py /app/
    COPY model_edgetpu.tflite /app/models/
    
    WORKDIR /app
    CMD ["python", "tpu_inference_service.py"]
    ```
  - Implemented inference service `tpu_inference_service.py`:
    ```python
    from pycoral.utils import edgetpu
    from pycoral.adapters import common
    import numpy as np
    import json
    import time
    
    # Load TPU model
    interpreter = edgetpu.make_interpreter('models/model_edgetpu.tflite')
    interpreter.allocate_tensors()
    
    # Load normalization params
    with open('normalization_params.json') as f:
        norm_params = json.load(f)
    
    # Stream Manager consumer
    while True:
        # Read from Stream Manager
        message = read_from_stream('SensorDataStream')
        sensor_data = json.loads(message)
        
        # Preprocess
        features = normalize_features(sensor_data, norm_params)
        
        # Run inference on TPU
        common.set_input(interpreter, features)
        interpreter.invoke()
        output = common.output_tensor(interpreter, 0)
        
        # Calculate reconstruction error
        reconstruction_error = np.mean((features - output) ** 2)
        is_anomaly = reconstruction_error > ANOMALY_THRESHOLD
        
        # Publish prediction to IoT Core
        prediction = {
            'device_id': sensor_data['device_id'],
            'timestamp': sensor_data['timestamp'],
            'reconstruction_error': float(reconstruction_error),
            'is_anomaly': is_anomaly
        }
        publish_to_iot(prediction)
        
        time.sleep(1)
    ```
  - Built Docker image:
    ```bash
    docker build -f Dockerfile.tpu -t siam-inference:v1 .
    ```
  - Tested container locally on Raspberry Pi:
    - Container size: 458 MB (includes TPU libraries)
    - Inference latency: 1.3ms (TPU accelerated)
    - CPU usage: 12% (very efficient)

- **MLInference Greengrass Component:**
  - Created component recipe for Docker container:
    ```json
    {
      "RecipeFormatVersion": "2020-01-25",
      "ComponentName": "com.siam.MLInference",
      "ComponentVersion": "1.0.0",
      "ComponentDescription": "Docker-based ML inference with Coral TPU",
      "ComponentPublisher": "SIAM",
      "ComponentDependencies": {
        "aws.greengrass.StreamManager": {
          "VersionRequirement": "^2.0.0"
        },
        "aws.greengrass.DockerApplicationManager": {
          "VersionRequirement": "^2.0.0"
        }
      },
      "Manifests": [
        {
          "Platform": {
            "os": "linux"
          },
          "Lifecycle": {
            "Run": "docker run --privileged --device /dev/apex_0 --rm -v /greengrass/v2/ipc.socket:/greengrass/v2/ipc.socket siam-inference:v1"
          }
        }
      ]
    }
    ```
  - Key Docker configurations:
    - `--privileged`: Access to Coral TPU device
    - `--device /dev/apex_0`: Coral TPU device passthrough
    - `-v /greengrass/v2/ipc.socket`: IPC for Stream Manager
  - Deployed model artifact:
    - Downloaded `model_edgetpu.tflite` from S3
    - Placed in `/greengrass/v2/packages/artifacts/com.siam.MLInference/1.0.0/models/`
  - Deployed component to Raspberry Pi

- **End-to-End Testing:**
  - Verified component deployments:
    ```bash
    sudo /greengrass/v2/bin/greengrass-cli component list
    ```
    Output:
    ```
    Component Name: com.siam.DataLogger
    Version: 1.0.0
    State: RUNNING
    
    Component Name: com.siam.MLInference
    Version: 1.0.0
    State: RUNNING
    ```
  - Monitored Stream Manager streams:
    - Stream `SensorDataStream` active
    - Messages buffering locally (1 msg/sec)
    - Automatic export to IoT Core enabled
  - Verified data flow:
    1. DataLogger → Stream Manager (sensor data)
    2. Stream Manager → MLInference (via consumer)
    3. MLInference → IoT Core (predictions)
  - Checked CloudWatch Logs:
    - DataLogger: "Published sensor data to stream"
    - MLInference: "Prediction: error=0.0234, anomaly=False"
  - Tested offline resilience:
    - Disconnected WiFi for 30 minutes
    - Stream Manager buffered 1,800 messages to disk
    - Reconnected WiFi → automatic sync to cloud
    - Zero data loss confirmed

### Sample Greengrass Deployment:

```
$ sudo /greengrass/v2/bin/greengrass-cli deployment create \
  --merge "com.siam.DataLogger=1.0.0" \
  --merge "com.siam.MLInference=1.0.0"

Deployment Id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
Deployment Status: IN_PROGRESS
...
Deployment Status: COMPLETED

Components Deployed:
- com.siam.DataLogger (1.0.0)
- com.siam.MLInference (1.0.0)
- aws.greengrass.StreamManager (2.1.3)
- aws.greengrass.DockerApplicationManager (2.0.5)
```

### Challenges Encountered:

- **Stream Manager SDK:** C SDK not well-documented - used Python SDK example as reference
- **Docker Permissions:** Container couldn't access Coral TPU - solved with `--privileged` flag
- **Component Dependencies:** Circular dependency issues - restructured recipe to explicit deps
- **Greengrass IPC:** Docker container IPC socket mounting required specific path

### Key Learnings:

- Greengrass components enable modular edge application development
- Stream Manager is critical for offline-first IoT architectures
- Docker containers solve dependency hell for legacy hardware libraries (Coral TPU)
- Greengrass deployments provide over-the-air (OTA) updates for edge devices
- Component recipes are the "infrastructure as code" for edge devices

### Next Week Preview:

In Week 8, I will complete the full pipeline integration by connecting the edge predictions back to the cloud, implementing CloudWatch monitoring and alarms, and testing the entire system end-to-end. This includes simulating anomalies with a deliberately imbalanced fan to validate the ML model's effectiveness.
