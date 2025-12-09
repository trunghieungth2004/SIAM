---
title: "Deploy and Configure EC2 Instances with AWS CLI"
date: 2025-12-09
draft: false
---

## Overview

Amazon Elastic Compute Cloud (Amazon EC2) provides scalable computing capacity in the AWS cloud. Using EC2 eliminates the need to invest in hardware upfront, allowing you to develop and deploy applications faster.

In this workshop, you will learn how to deploy, configure, and manage EC2 instances entirely through the AWS CLI without using the AWS Management Console. You will create VPCs, security groups, key pairs, and EC2 instances, demonstrating infrastructure-as-code principles through command-line automation.

By the end of this workshop, you will understand how to:
- Create and configure VPC networking components via CLI
- Generate and manage EC2 key pairs programmatically
- Launch EC2 instances with custom configurations
- Attach storage volumes and configure security groups
- Connect to and manage instances remotely
- Clean up resources to avoid unnecessary costs

## Content

- Workshop overview
- Prerequisites
- Create VPC and Networking Components
- Generate EC2 Key Pair
- Launch EC2 Instance
- Configure Security Groups
- Attach EBS Volume
- Connect to EC2 Instance
- Install and Configure Applications
- Clean up

---

## Prerequisites

Before starting this workshop, ensure you have:

1. **AWS Account** with appropriate permissions to create EC2, VPC, and IAM resources
2. **AWS CLI installed and configured** with credentials:
   ```bash
   aws configure
   ```
3. **Basic Linux/Unix command-line knowledge**
4. **SSH client** installed on your local machine
5. **jq** (JSON processor) for parsing AWS CLI outputs:
   ```bash
   # Install jq
   sudo apt-get install jq  # Ubuntu/Debian
   brew install jq          # macOS
   ```

Verify your AWS CLI is configured:
```bash
aws sts get-caller-identity
```

---

## Step 1: Create VPC and Networking Components

### 1.1 Set Environment Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_NAME="ec2-workshop"
export VPC_CIDR="10.0.0.0/16"
export SUBNET_CIDR="10.0.1.0/24"
```

### 1.2 Create VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
    --region $AWS_REGION \
    --query 'Vpc.VpcId' \
    --output text)

echo "VPC ID: $VPC_ID"
```

### 1.3 Enable DNS Hostnames

```bash
aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-hostnames \
    --region $AWS_REGION
```

### 1.4 Create Internet Gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
    --region $AWS_REGION \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

echo "Internet Gateway ID: $IGW_ID"
```

### 1.5 Attach Internet Gateway to VPC

```bash
aws ec2 attach-internet-gateway \
    --vpc-id $VPC_ID \
    --internet-gateway-id $IGW_ID \
    --region $AWS_REGION
```

### 1.6 Create Public Subnet

```bash
SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET_CIDR \
    --availability-zone "${AWS_REGION}a" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-subnet}]" \
    --region $AWS_REGION \
    --query 'Subnet.SubnetId' \
    --output text)

echo "Subnet ID: $SUBNET_ID"
```

### 1.7 Enable Auto-assign Public IP

```bash
aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET_ID \
    --map-public-ip-on-launch \
    --region $AWS_REGION
```

### 1.8 Create Route Table

```bash
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt}]" \
    --region $AWS_REGION \
    --query 'RouteTable.RouteTableId' \
    --output text)

echo "Route Table ID: $ROUTE_TABLE_ID"
```

### 1.9 Create Route to Internet Gateway

```bash
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $AWS_REGION
```

### 1.10 Associate Route Table with Subnet

```bash
aws ec2 associate-route-table \
    --subnet-id $SUBNET_ID \
    --route-table-id $ROUTE_TABLE_ID \
    --region $AWS_REGION
```

---

## Step 2: Generate EC2 Key Pair

### 2.1 Create Key Pair

```bash
aws ec2 create-key-pair \
    --key-name "${PROJECT_NAME}-keypair" \
    --region $AWS_REGION \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/${PROJECT_NAME}-keypair.pem
```

### 2.2 Set Key Permissions

```bash
chmod 400 ~/.ssh/${PROJECT_NAME}-keypair.pem
```

### 2.3 Verify Key Pair

```bash
aws ec2 describe-key-pairs \
    --key-names "${PROJECT_NAME}-keypair" \
    --region $AWS_REGION
```

---

## Step 3: Configure Security Groups

### 3.1 Create Security Group

```bash
SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-sg" \
    --description "Security group for EC2 workshop" \
    --vpc-id $VPC_ID \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text)

echo "Security Group ID: $SG_ID"
```

### 3.2 Add SSH Ingress Rule

```bash
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
```

### 3.3 Add HTTP Ingress Rule

```bash
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
```

### 3.4 Add HTTPS Ingress Rule

```bash
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
```

---

## Step 4: Launch EC2 Instance

### 4.1 Get Latest Amazon Linux 2023 AMI

```bash
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
              "Name=state,Values=available" \
    --region $AWS_REGION \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "AMI ID: $AMI_ID"
```

### 4.2 Launch EC2 Instance

```bash
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t2.micro \
    --key-name "${PROJECT_NAME}-keypair" \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-instance}]" \
    --region $AWS_REGION \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"
```

### 4.3 Wait for Instance to be Running

```bash
aws ec2 wait instance-running \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

echo "Instance is now running"
```

### 4.4 Get Instance Public IP

```bash
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Public IP: $PUBLIC_IP"
```

---

## Step 5: Attach EBS Volume

### 5.1 Create EBS Volume

```bash
VOLUME_ID=$(aws ec2 create-volume \
    --availability-zone "${AWS_REGION}a" \
    --size 10 \
    --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${PROJECT_NAME}-data-volume}]" \
    --region $AWS_REGION \
    --query 'VolumeId' \
    --output text)

echo "Volume ID: $VOLUME_ID"
```

### 5.2 Wait for Volume to be Available

```bash
aws ec2 wait volume-available \
    --volume-ids $VOLUME_ID \
    --region $AWS_REGION
```

### 5.3 Attach Volume to Instance

```bash
aws ec2 attach-volume \
    --volume-id $VOLUME_ID \
    --instance-id $INSTANCE_ID \
    --device /dev/sdf \
    --region $AWS_REGION
```

---

## Step 6: Connect to EC2 Instance

### 6.1 SSH into Instance

```bash
ssh -i ~/.ssh/${PROJECT_NAME}-keypair.pem ec2-user@$PUBLIC_IP
```

### 6.2 Verify Instance Details

Once connected, run:

```bash
# Check instance metadata
curl http://169.254.169.254/latest/meta-data/instance-id
curl http://169.254.169.254/latest/meta-data/instance-type
curl http://169.254.169.254/latest/meta-data/placement/availability-zone

# Check attached volumes
lsblk
```

---

## Step 7: Install and Configure Applications

### 7.1 Update System Packages

```bash
sudo dnf update -y
```

### 7.2 Install Web Server

```bash
sudo dnf install -y httpd
```

### 7.3 Start and Enable Apache

```bash
sudo systemctl start httpd
sudo systemctl enable httpd
```

### 7.4 Create Sample Web Page

```bash
echo "<h1>Hello from EC2 Workshop Instance</h1>" | sudo tee /var/www/html/index.html
```

### 7.5 Verify Web Server

```bash
curl http://localhost
```

Exit the SSH session:
```bash
exit
```

### 7.6 Test from Local Machine

```bash
curl http://$PUBLIC_IP
```

---

## Step 8: Additional EC2 Management via CLI

### 8.1 Create AMI from Running Instance

```bash
AMI_SNAPSHOT=$(aws ec2 create-image \
    --instance-id $INSTANCE_ID \
    --name "${PROJECT_NAME}-backup-$(date +%Y%m%d)" \
    --description "Backup of EC2 workshop instance" \
    --region $AWS_REGION \
    --query 'ImageId' \
    --output text)

echo "AMI Created: $AMI_SNAPSHOT"
```

### 8.2 Stop Instance

```bash
aws ec2 stop-instances \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

aws ec2 wait instance-stopped \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

echo "Instance stopped"
```

### 8.3 Start Instance

```bash
aws ec2 start-instances \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

aws ec2 wait instance-running \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

echo "Instance started"
```

### 8.4 Modify Instance Type

```bash
# Stop instance first (if not already stopped)
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID --region $AWS_REGION

# Change instance type
aws ec2 modify-instance-attribute \
    --instance-id $INSTANCE_ID \
    --instance-type "{\"Value\": \"t3.small\"}" \
    --region $AWS_REGION

# Start instance
aws ec2 start-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
```

---

## Step 9: Clean Up

### 9.1 Terminate EC2 Instance

```bash
aws ec2 terminate-instances \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION

aws ec2 wait instance-terminated \
    --instance-ids $INSTANCE_ID \
    --region $AWS_REGION
```

### 9.2 Delete EBS Volume

```bash
aws ec2 delete-volume \
    --volume-id $VOLUME_ID \
    --region $AWS_REGION
```

### 9.3 Delete AMI and Snapshot

```bash
# Deregister AMI
aws ec2 deregister-image \
    --image-id $AMI_SNAPSHOT \
    --region $AWS_REGION

# Get snapshot ID
SNAPSHOT_ID=$(aws ec2 describe-snapshots \
    --owner-ids self \
    --filters "Name=description,Values=*${AMI_SNAPSHOT}*" \
    --region $AWS_REGION \
    --query 'Snapshots[0].SnapshotId' \
    --output text)

# Delete snapshot
aws ec2 delete-snapshot \
    --snapshot-id $SNAPSHOT_ID \
    --region $AWS_REGION
```

### 9.4 Delete Security Group

```bash
aws ec2 delete-security-group \
    --group-id $SG_ID \
    --region $AWS_REGION
```

### 9.5 Delete Subnet

```bash
aws ec2 delete-subnet \
    --subnet-id $SUBNET_ID \
    --region $AWS_REGION
```

### 9.6 Detach and Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID \
    --region $AWS_REGION

aws ec2 delete-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --region $AWS_REGION
```

### 9.7 Delete Route Table

```bash
aws ec2 delete-route-table \
    --route-table-id $ROUTE_TABLE_ID \
    --region $AWS_REGION
```

### 9.8 Delete VPC

```bash
aws ec2 delete-vpc \
    --vpc-id $VPC_ID \
    --region $AWS_REGION
```

### 9.9 Delete Key Pair

```bash
aws ec2 delete-key-pair \
    --key-name "${PROJECT_NAME}-keypair" \
    --region $AWS_REGION

rm ~/.ssh/${PROJECT_NAME}-keypair.pem
```

---

## Key Takeaways

### AWS CLI Proficiency
- Learned to manage complete EC2 infrastructure lifecycle using only CLI commands
- Understood the importance of resource IDs and environment variables for automation
- Practiced using AWS CLI output formatting (text, json) and jq for parsing

### Infrastructure as Code Principles
- Created reproducible infrastructure using shell scripts
- Used environment variables for configuration management
- Demonstrated proper resource tagging for organization and cost tracking

### VPC Networking
- Created isolated VPC with custom CIDR blocks
- Configured public subnets with internet gateway routing
- Understood the relationship between route tables, subnets, and gateways

### EC2 Instance Management
- Launched instances with custom AMIs and instance types
- Managed instance lifecycle (start, stop, terminate)
- Created AMI snapshots for backup and replication

### Security Best Practices
- Used security groups for fine-grained network access control
- Generated and managed SSH key pairs securely
- Applied principle of least privilege for security group rules

### Storage Management
- Created and attached EBS volumes dynamically
- Understood volume types (gp3) and sizing considerations
- Practiced proper cleanup to avoid orphaned resources

### Automation and Scripting
- Demonstrated complete automation workflow from creation to cleanup
- Used AWS CLI waiters for synchronous operations
- Practiced idempotent operations for reliable automation

This workshop provided hands-on experience with AWS CLI for EC2 management, eliminating dependency on the AWS Console and enabling true infrastructure-as-code practices.
