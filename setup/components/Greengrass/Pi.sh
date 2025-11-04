#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Raspberry Pi Basic Setup           |--/ /-|#
#|-/ /--| Minimal Pi prep for Greengrass     |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/../common.sh"

is_tailscale_ip() {
    local ip=$(echo "$PI_SSH_TARGET" | cut -d'@' -f2)
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]
}

setup_ssh_keys() {
    if is_tailscale_ip; then
        print_log -c "[tailscale] " "Tailscale IP detected, skipping SSH key setup"
        return 0
    fi
    
    print_log -c "[ssh] " "Setting up SSH key authentication..."
    
    # Generate SSH key if it doesn't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        print_log -y "[generate] " "Generating SSH key..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
    fi
    
    # Copy SSH key to Pi (this will prompt for password once)
    print_log -y "[copy] " "Copying SSH key to Pi (enter password one time)..."
    ssh-copy-id -i ~/.ssh/id_rsa.pub "${PI_SSH_TARGET}" || {
        print_log -r "[error] " "Failed to copy SSH key"
        return 1
    }
    
    print_log -g "[ok] " "SSH key authentication configured"
}

setup_pi_basics() {
    print_log -b "[pi-basics] " "Setting up basic Pi configuration..."
    
    # Validate SSH target
    if [ -z "$PI_SSH_TARGET" ]; then
        print_log -r "[error] " "PI_SSH_TARGET is not set"
        return 1
    fi
    
    # Setup SSH keys first (skip for Tailscale)
    setup_ssh_keys
    
    print_log -c "[remote] " "Configuring Pi basics on: ${PI_SSH_TARGET}"
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'REMOTE_SETUP_EOF'
# Setup passwordless sudo
echo "[setup] Configuring passwordless sudo..."
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER > /dev/null

# Update system
echo "[setup] Updating system packages..."
sudo apt-get update -qq

# Install essentials including Java and Docker
echo "[setup] Installing basic packages..."
sudo apt-get install -y curl unzip build-essential libgpiod-dev default-jre docker.io docker-compose gnupg

# Configure Docker
echo "[setup] Configuring Docker..."
sudo usermod -aG docker $USER
sudo systemctl enable docker
sudo systemctl start docker

# Enable hardware interfaces
echo "[setup] Enabling I2C, SPI and 1-Wire interfaces..."
sudo raspi-config nonint do_i2c 0
sudo raspi-config nonint do_spi 0
sudo raspi-config nonint do_onewire 0

# Configure active cooling
echo "[setup] Configuring active cooling..."
if grep -q "dtparam=fan" /boot/firmware/config.txt; then
    echo "[skip] Active cooling already configured."
else
    echo "[setup] Adding active cooling configuration..."
    echo "" | sudo tee -a /boot/firmware/config.txt > /dev/null
    echo "# Active cooling fan settings" | sudo tee -a /boot/firmware/config.txt > /dev/null
    echo "dtparam=fan_temp1=25000" | sudo tee -a /boot/firmware/config.txt > /dev/null
    echo "dtparam=fan_temp1_hyst=2500" | sudo tee -a /boot/firmware/config.txt > /dev/null
    echo "dtparam=fan_temp1_speed=250" | sudo tee -a /boot/firmware/config.txt > /dev/null
fi

# Clean up any existing Greengrass - COMMENTED OUT TO PREVENT DELETION AFTER INSTALLATION
# echo "[cleanup] Cleaning up any existing Greengrass..."
# sudo systemctl stop greengrass.service 2>/dev/null || true
# sudo systemctl disable greengrass.service 2>/dev/null || true
# sudo rm -rf /greengrass
# if id "ggc_user" &>/dev/null; then sudo userdel ggc_user 2>/dev/null || true; fi
# if getent group "ggc_group" &>/dev/null; then sudo groupdel ggc_group 2>/dev/null || true; fi

# Setup Coral TPU runtime and Docker image
echo "[tpu] Setting up Coral Edge TPU..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/coral-edgetpu.gpg
echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libedgetpu1-std

# Add udev rules for USB Accelerator
echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="1a6e", ATTRS{idProduct}=="089a", MODE="0666"' | sudo tee /etc/udev/rules.d/99-coral.rules
echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9302", MODE="0666"' | sudo tee -a /etc/udev/rules.d/99-coral.rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# Build Coral TPU Docker image
echo "[docker] Building Coral TPU Docker image..."
mkdir -p ~/coral-docker
cat > ~/coral-docker/Dockerfile << 'DOCKERFILE_EOF'
FROM debian:11-slim

WORKDIR /app
ENV HOME /app

RUN apt-get update && apt-get install -y \
    git nano python3-pip python3-dev pkg-config wget usbutils curl gnupg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" > /etc/apt/sources.list.d/coral-edgetpu.list

RUN apt-get update && apt-get install -y \
    libedgetpu1-std python3-pycoral python3-tflite-runtime \
    && rm -rf /var/lib/apt/lists/*

# Install compatible NumPy version and other packages
RUN pip3 install --no-cache-dir "numpy>=1.21,<2.0" boto3 awsiotsdk pillow pandas scikit-learn joblib "tensorflow>=2.13,<2.16"

ENV PYTHONPATH=/usr/lib/python3/dist-packages:$PYTHONPATH

WORKDIR /app
DOCKERFILE_EOF

if docker build -t coral-tpu:latest ~/coral-docker/; then
    echo "[ok] Coral TPU Docker image built successfully"
else
    echo "[error] Failed to build Coral TPU Docker image"
    exit 1
fi

# Test TPU detection
echo "[test] Testing Coral TPU detection..."
if docker run --rm --privileged --device=/dev/bus/usb coral-tpu:latest \
    python3 -c "from pycoral.utils import edgetpu; devices = edgetpu.list_edge_tpus(); print(f'Found {len(devices)} TPU device(s)' if devices else 'No TPU found - connect USB Accelerator and replug')" 2>/dev/null; then
    echo "[ok] TPU test successful"
else
    echo "[info] TPU test completed - device may need to be connected/replugged"
fi

echo "[complete] Pi basics setup complete"
REMOTE_SETUP_EOF

    if [ $? -eq 0 ]; then
        print_log -g "[ok] " "Pi basics configured successfully"
        return 0
    else
        print_log -r "[error] " "Pi basics setup failed"
        return 1
    fi
}

cleanup_pi() {
    print_log -b "[cleanup] " "Cleaning up Pi setup..."
    
    if [ -z "$PI_SSH_TARGET" ]; then
        print_log -y "[skip] " "PI_SSH_TARGET not set, skipping cleanup"
        return 0
    fi
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'REMOTE_CLEANUP_EOF'
echo "[cleanup] Removing Greengrass..."
sudo systemctl stop greengrass.service 2>/dev/null || true
sudo systemctl disable greengrass.service 2>/dev/null || true
sudo rm -rf /greengrass
if id "ggc_user" &>/dev/null; then sudo userdel ggc_user 2>/dev/null || true; fi
if getent group "ggc_group" &>/dev/null; then sudo groupdel ggc_group 2>/dev/null || true; fi

echo "[cleanup] Removing Coral TPU Docker image..."
docker rmi coral-tpu:latest 2>/dev/null || true
rm -rf ~/coral-docker

echo "[cleanup] Removing all Docker containers and images..."
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm $(docker ps -aq) 2>/dev/null || true
docker rmi $(docker images -q) 2>/dev/null || true

echo "[cleanup] Removing Coral TPU runtime..."
sudo apt-get remove -y libedgetpu1-std 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/coral-edgetpu.list
sudo rm -f /usr/share/keyrings/coral-edgetpu.gpg
sudo rm -f /etc/udev/rules.d/99-coral.rules
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "[cleanup] Removing Docker..."
sudo systemctl stop docker 2>/dev/null || true
sudo systemctl disable docker 2>/dev/null || true
sudo apt-get remove -y docker.io docker-compose 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

echo "[cleanup] Removing passwordless sudo..."
sudo rm -f /etc/sudoers.d/$USER

echo "[cleanup] Pi cleanup complete"
REMOTE_CLEANUP_EOF

    print_log -g "[ok] " "Pi cleanup completed"
}

# Main execution
case "${1:-}" in
    setup)
        setup_pi_basics
        ;;
    cleanup)
        cleanup_pi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PI_SSH_TARGET"
        exit 1
        ;;
esac