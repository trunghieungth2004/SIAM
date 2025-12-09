---
title: "Week 4 Worklog"
date: 2025-09-29
draft: false
weight: 4
---

# Week 4 Worklog

### Week 4 Objectives:
- Deep dive into EC2 instance types and use cases
- Master VPC networking and security configuration
- Set up Raspberry Pi 5 hardware and Raspberry Pi OS
- Install and configure AWS IoT Greengrass Core on the Pi
- Begin local sensor data collection development

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Deep dive into EC2: <br>  + Instance families (T3, M5, C5, etc.) <br>  + Pricing models (On-Demand, Reserved, Spot) <br>  + EC2 Auto Scaling <br> - Learn about EC2 placement groups <br> - Study EC2 Instance Connect and Session Manager | 29/09/2025 | 29/09/2025 | [AWS EC2 Documentation](https://docs.aws.amazon.com/ec2/) <br> FCJ EC2 workshops |
| 2 | - Hands-on VPC workshop: <br>  + Create VPC with public/private subnets <br>  + Configure Internet Gateway <br>  + Set up NAT Gateway <br>  + Configure route tables <br>  + Test EC2 in public subnet | 30/09/2025 | 30/09/2025 | FCJ VPC workshop materials |
| 3 | - Set up Raspberry Pi 5 hardware: <br>  + Unbox and assemble Pi 5 <br>  + Install heatsink and cooling fan <br>  + Connect power supply and peripherals <br> - Download Raspberry Pi OS Lite (64-bit) <br> - Flash OS to microSD card using Raspberry Pi Imager | 01/10/2025 | 01/10/2025 | [Raspberry Pi Documentation](https://www.raspberrypi.com/documentation/) |
| 4 | - Configure Raspberry Pi OS: <br>  + Enable SSH <br>  + Configure WiFi/Ethernet <br>  + Update system packages <br>  + Set up static IP address <br> - Install development tools (git, gcc, python3) <br> - Configure I2C and 1-Wire interfaces | 02/10/2025 | 02/10/2025 | Raspberry Pi setup guides |
| 5 | - Install AWS IoT Greengrass Core: <br>  + Download Greengrass installer <br>  + Create Greengrass IAM role <br>  + Run Greengrass installer <br>  + Configure Greengrass as systemd service <br> - Verify Greengrass connectivity to AWS | 03/10/2025 | 03/10/2025 | [AWS IoT Greengrass Documentation](https://docs.aws.amazon.com/greengrass/) |
| 6 | - Create Local.sh component script: <br>  + Compile local data logger (C) <br>  + Set up systemd service <br>  + Configure automatic startup <br> - Begin 24-hour local data collection test | 04/10/2025 | 05/10/2025 | Project requirements |

### Week 4 Achievements:

- **EC2 Advanced Concepts:**
  - Mastered EC2 instance family selection criteria:
    - **T3/T3a:** Burstable, cost-effective for variable workloads
    - **M5/M5a:** General purpose, balanced compute/memory
    - **C5/C5a:** Compute-optimized for CPU-intensive tasks
    - **R5/R5a:** Memory-optimized for in-memory databases
    - **P3/G4:** GPU instances for ML training/inference
  - Learned EC2 pricing strategies:
    - On-Demand: Pay per second, no commitment
    - Reserved Instances: 1-3 year commitment, up to 75% savings
    - Spot Instances: Bid for unused capacity, up to 90% savings
    - Savings Plans: Flexible pricing for consistent usage
  - Understood EC2 Auto Scaling for high availability
  - Learned EC2 Instance Connect (browser-based SSH)
  - Explored AWS Systems Manager Session Manager (no SSH keys needed)

- **VPC Hands-on Workshop:**
  - Created production-grade VPC from scratch:
    - VPC CIDR: 10.0.0.0/16 (65,536 IPs)
    - Public subnet: 10.0.1.0/24 (in us-east-1a)
    - Private subnet: 10.0.2.0/24 (in us-east-1a)
  - Configured Internet Gateway (IGW) for public internet access
  - Deployed NAT Instance (t3.nano) in public subnet for private subnet egress
  - Created and associated route tables:
    - Public route table: 0.0.0.0/0 → IGW
    - Private route table: 0.0.0.0/0 → NAT Instance
  - Launched EC2 instances in both subnets:
    - Public subnet: Jump host/bastion (Amazon Linux 2)
    - Private subnet: Application server (no public IP)
  - Configured Security Groups:
    - Bastion SG: Allow SSH (22) from my IP
    - App SG: Allow SSH (22) from Bastion SG only
  - Successfully tested SSH jump: Local → Bastion → Private EC2
  - Learned VPC Flow Logs for network troubleshooting

- **VPC Endpoints Deep Dive:**
  - Created S3 Gateway Endpoint:
    - Benefit: Private S3 access without NAT Gateway charges
    - Route added to private route table
    - Free of charge
  - Learned Interface Endpoints (AWS PrivateLink):
    - Private connections to AWS services via ENI
    - Examples: DynamoDB, SNS, SQS, Lambda
    - Hourly charges + data transfer costs

- **Raspberry Pi 5 Hardware Setup:**
  - Unboxed and assembled Raspberry Pi 5:
    - 8GB RAM model (optimal for ML inference)
    - Active cooler installed for thermal management
    - 64GB microSD card (SanDisk Extreme Pro)
  - Downloaded Raspberry Pi OS Lite (64-bit) - minimal, no desktop
  - Used Raspberry Pi Imager to flash OS:
    - Pre-configured SSH enabled
    - Set hostname: `siam-edge-01`
    - Configured WiFi credentials
    - Set user: `pi` with secure password
  - First boot successful, SSH connection established
  - Assigned static IP: 192.168.1.100

- **Raspberry Pi OS Configuration:**
  - Updated system packages:
    ```bash
    sudo apt update && sudo apt upgrade -y
    ```
  - Installed development tools:
    - `build-essential` - GCC, G++, Make
    - `git` - Version control
    - `python3-pip` - Python package manager
    - `docker.io` - Container runtime (for ML inference)
    - `i2c-tools` - I2C debugging
  - Enabled hardware interfaces via `raspi-config`:
    - I2C (for MPU-6050, INA219)
    - 1-Wire (for DS18B20 temperature sensor)
    - SPI (for future expansion)
  - Verified I2C: `i2cdetect -y 1` - detected devices on bus
  - Configured kernel modules to load at boot:
    ```bash
    sudo echo "i2c-dev" >> /etc/modules
    sudo echo "w1-gpio" >> /etc/modules
    sudo echo "w1-therm" >> /etc/modules
    ```

- **AWS IoT Greengrass Installation:**
  - Created Greengrass-specific IAM role with permissions:
    - S3 access for component artifacts
    - CloudWatch Logs for logging
    - IoT Core for connectivity
  - Created Greengrass Thing in AWS IoT Core: `RaspberryPi_5_Core`
  - Downloaded Greengrass Core installer (v2.12.0):
    ```bash
    curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip > greengrass-nucleus-latest.zip
    unzip greengrass-nucleus-latest.zip -d GreengrassInstaller
    ```
  - Ran Greengrass installer with automated provisioning:
    ```bash
    sudo -E java -Droot="/greengrass/v2" -Dlog.store=FILE \
      -jar ./GreengrassInstaller/lib/Greengrass.jar \
      --aws-region us-east-1 \
      --thing-name RaspberryPi_5_Core \
      --thing-group-name SIAMDevices \
      --component-default-user ggc_user:ggc_group \
      --provision true \
      --setup-system-service true
    ```
  - Verified Greengrass service status:
    ```bash
    sudo systemctl status greengrass.service
    ```
  - Confirmed connectivity in AWS IoT console (Thing status: Connected)

- **Greengrass.sh Component Script:**
  - Enhanced Greengrass component script for automated Pi provisioning
  - Implemented remote SSH commands for Greengrass installation
  - Added certificate download and transfer logic
  - Created Greengrass component recipes (JSON) for deployment
  - Tested deployment of hello-world component successfully

- **Local Data Collection Development:**
  - Created `local_datalogger.c` in C for high-performance sensor reading
  - Implemented I2C communication for MPU-6050 and INA219
  - Integrated 1-Wire protocol for DS18B20 temperature sensor
  - Designed sensor data structure:
    ```c
    typedef struct {
        float accel_x, accel_y, accel_z;
        float gyro_x, gyro_y, gyro_z;
        float voltage, current;
        float temperature;
        uint64_t timestamp;
    } SensorData;
    ```
  - Compiled native binary: `gcc -o datalogger local_datalogger.c -lm -lpthread`
  - Created systemd service for automatic startup:
    ```ini
    [Unit]
    Description=SIAM Local Data Logger
    After=network.target

    [Service]
    ExecStart=/home/pi/datalogger
    Restart=always
    User=pi

    [Install]
    WantedBy=multi-user.target
    ```
  - Enabled service: `sudo systemctl enable datalogger.service`
  - Started 24-hour continuous data collection test

- **Local.sh Component Script:**
  - Implemented `Local.sh` for automated local data logger deployment
  - Features:
    - Cross-compile C datalogger from local machine
    - SCP binary to Raspberry Pi
    - Install as systemd service remotely
    - Start data collection
  - Added cleanup function to stop and remove service

- **VPC Component Implementation:**
  - Finalized VPC.sh script (created during EC2 learning)
  - Automated VPC creation with public/private subnets
  - Security group configuration for SSH and HTTPS
  - Not used in final SIAM architecture (edge device uses direct IoT Core connection)
  - Retained for future EC2-based expansion scenarios

### Sample Sensor Data Log:

```
[2025-10-05 08:23:15] accel(0.02, -0.03, 9.78) gyro(0.01, 0.00, -0.01) V=12.4 I=0.52A T=24.2°C
[2025-10-05 08:23:16] accel(0.01, -0.02, 9.79) gyro(0.00, 0.01, 0.00) V=12.3 I=0.51A T=24.2°C
[2025-10-05 08:23:17] accel(0.03, -0.04, 9.77) gyro(0.02, -0.01, 0.01) V=12.4 I=0.53A T=24.3°C
```

### Challenges Encountered:

- **I2C Permission Errors:** User `pi` couldn't access I2C bus - solved by adding user to `i2c` group: `sudo usermod -a -G i2c pi`
- **Greengrass Java Dependency:** Greengrass requires Java - installed `openjdk-11-jdk`
- **NAT Instance Setup:** Used NAT Instance (t3.nano) instead of NAT Gateway to save costs ($0.0052/hour vs $0.045/hour)
- **SSH Key Management:** Initial SSH issues with Greengrass installer - resolved by using correct key path

### Key Learnings:

- EC2 is powerful but not needed for edge-first IoT architectures
- VPC networking knowledge is essential for enterprise AWS deployments
- Raspberry Pi 5 is significantly faster than Pi 4 for ML workloads
- AWS IoT Greengrass simplifies edge device management at scale
- Systemd services enable reliable autonomous edge operation

### Next Week Preview:

In Week 5, I will analyze the 24-48 hours of local sensor data collected from the Raspberry Pi, prepare the dataset for ML training, and complete the Lambda component scripts for data ingestion and querying. The focus shifts to cloud data processing pipelines.
