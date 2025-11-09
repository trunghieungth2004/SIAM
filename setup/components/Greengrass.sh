#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Greengrass Component               |--/ /-|#
#|-/ /--| Installs Greengrass on Raspberry Pi|-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

# --- Function to verify Greengrass connectivity ---
verify_greengrass_connection() {
    print_log -c "[verify] " "Checking Greengrass device connectivity..."
    
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    
    # Check if Greengrass core device exists
    if ! aws greengrassv2 get-core-device --core-device-thing-name "$GG_THING_NAME" > /dev/null 2>&1; then
        print_log -r "[error] " "Greengrass core device not found: $GG_THING_NAME"
        print_log -y "[info] " "Please ensure Greengrass component was set up successfully"
        return 1
    fi
    
    # Check device status
    DEVICE_STATUS=$(aws greengrassv2 get-core-device --core-device-thing-name "$GG_THING_NAME" --query "status" --output text 2>/dev/null)
    if [ "$DEVICE_STATUS" != "HEALTHY" ]; then
        print_log -y "[warn] " "Greengrass device status: $DEVICE_STATUS"
        print_log -y "[info] " "Device may not be fully connected. Continuing anyway..."
    else
        print_log -g "[ok] " "Greengrass device is healthy and connected"
    fi
    
    # Test connectivity by checking last update time
    LAST_UPDATE=$(aws greengrassv2 get-core-device --core-device-thing-name "$GG_THING_NAME" --query "lastStatusUpdateTimestamp" --output text 2>/dev/null)
    if [ ! -z "$LAST_UPDATE" ] && [ "$LAST_UPDATE" != "None" ]; then
        print_log -g "[ok] " "Device last seen: $(date -d @${LAST_UPDATE} 2>/dev/null || echo 'recently')"
    fi
    
    return 0
}

discover_s3_bucket() {
    # Look for resource file first (like Lambda does)
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    
    if [ -f "$RESOURCE_FILE" ]; then
        S3_DATA_BUCKET=$(grep "S3_DATA_BUCKET" "$RESOURCE_FILE" | cut -d'=' -f2)
        print_log -g "[found] " "Found S3 bucket in resource file: ${S3_DATA_BUCKET}"
    fi
    
    # If not found, discover bucket (like Lambda does)
    if [ -z "$S3_DATA_BUCKET" ]; then
        print_log -y "[discover] " "Resource file not found, discovering S3 bucket..."
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        S3_DATA_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'iot-data')].Name" --output text | head -1)
        
        if [ -z "$S3_DATA_BUCKET" ] || [ "$S3_DATA_BUCKET" = "None" ]; then
            print_log -r "[error] " "S3 data bucket not found. Please ensure S3 setup completed successfully."
            return 1
        else
            print_log -g "[discovered] " "Discovered S3 data bucket: ${S3_DATA_BUCKET}"
        fi
    fi
    
    # Check for compiled Edge TPU model
    COMPILED_MODEL_URI="s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz"
    if aws s3 ls "${COMPILED_MODEL_URI}" > /dev/null 2>&1; then
        print_log -g "[model] " "Found compiled Edge TPU model: ${COMPILED_MODEL_URI}"
    else
        print_log -r "[error] " "Compiled Edge TPU model not found at: ${COMPILED_MODEL_URI}"
        print_log -y "[info] " "Please run EdgeTPUCompiler.sh to compile the model first"
        print_log -y "[info] " "Run: bash scripts/EdgeTPUCompiler.sh setup"
        return 1
    fi
}

get_next_component_version() {
    local component_name="$1"
    local latest_version=$(aws greengrassv2 list-component-versions --arn "arn:aws:greengrass:${AWS_REGION}:${ACCOUNT_ID}:components:${component_name}" --query "componentVersions[0].componentVersion" --output text 2>/dev/null || echo "1.0.0")
    if [ "$latest_version" = "None" ] || [ -z "$latest_version" ]; then
        echo "1.0.1"
    else
        local patch=$(echo "$latest_version" | cut -d'.' -f3)
        local new_patch=$((patch + 1))
        echo "1.0.$new_patch"
    fi
}

generate_component_recipes() {
    print_log -c "[recipes] " "Generating component recipes with project variables..."
    
    # Discover S3 bucket and model path
    if ! discover_s3_bucket; then
        return 1
    fi
    
    # Get next component versions
    DATALOGGER_VERSION=$(get_next_component_version "com.${PROJECT_NAME}.DataLogger")
    MLINFERENCE_VERSION=$(get_next_component_version "com.${PROJECT_NAME}.MLInference")
    
    # Create directories if they don't exist
    mkdir -p "$(dirname "$0")/Greengrass/DataLogger"
    mkdir -p "$(dirname "$0")/Greengrass/MLInference"
    
    # Generate DataLogger component recipe
    cat > "$(dirname "$0")/Greengrass/DataLogger/component_recipe.json" << DATALOGGER_EOF
{
  "RecipeFormatVersion": "2020-01-25",
  "ComponentName": "com.${PROJECT_NAME}.DataLogger",
  "ComponentVersion": "${DATALOGGER_VERSION}",
  "ComponentDescription": "IoT sensor datalogger with StreamManager integration (Host-Native)",
  "ComponentPublisher": "${PROJECT_NAME}",
  "ComponentDependencies": {
    "aws.greengrass.StreamManager": {
      "VersionRequirement": ">=2.0.0"
    }
  },
  "Manifests": [
    {
      "Platform": {
        "os": "linux"
      },
      "Lifecycle": {
        "Install": {
          "RequiresPrivilege": true,
          "Script": "apt-get update && apt-get install -y libgpiod-dev i2c-tools python3 python3-pip && python3 -m pip install --break-system-packages git+https://github.com/aws-greengrass/aws-greengrass-stream-manager-sdk-python && gcc -o {artifacts:path}/datalogger {artifacts:path}/datalogger.c -lgpiod -lm"
        },
        "Run": {
          "RequiresPrivilege": true,
          "Script": "{artifacts:path}/datalogger | python3 {artifacts:path}/streammanager_datalogger.py"
        }
      },
      "Artifacts": [
        {
          "Uri": "s3://${S3_DATA_BUCKET}/greengrass/artifacts/datalogger.c"
        },
        {
          "Uri": "s3://${S3_DATA_BUCKET}/greengrass/artifacts/streammanager_datalogger.py"
        }
      ]
    }
  ]
}
DATALOGGER_EOF

    # Generate MLInference component recipe
    cat > "$(dirname "$0")/Greengrass/MLInference/component_recipe.json" << MLINFERENCE_EOF
{
  "RecipeFormatVersion": "2020-01-25",
  "ComponentName": "com.${PROJECT_NAME}.MLInference",
  "ComponentVersion": "${MLINFERENCE_VERSION}",
  "ComponentDescription": "TPU-accelerated ML inference with Coral USB Accelerator",
  "ComponentPublisher": "${PROJECT_NAME}",
  "ComponentDependencies": {
    "aws.greengrass.StreamManager": {
      "VersionRequirement": ">=2.0.0"
    }
  },
  "Manifests": [
    {
      "Platform": {
        "os": "linux"
      },
      "Lifecycle": {
        "Install": {
          "RequiresPrivilege": true,
          "Script": "python3 -m pip install --break-system-packages git+https://github.com/aws-greengrass/aws-greengrass-stream-manager-sdk-python && mkdir -p /tmp/greengrass_ml && echo '[1/4] Extracting model archive...' && tar -xzf {artifacts:path}/model_edgetpu_latest.tar.gz -C /tmp/greengrass_ml/ && echo '[2/4] Validating model artifacts...' && for file in model.tflite scaler.pkl days_scaler.pkl features.txt; do if [ ! -f /tmp/greengrass_ml/\$file ]; then echo \"ERROR: Missing required file: \$file\" && ls -la /tmp/greengrass_ml/ && exit 1; fi; done && echo 'All required artifacts found' && echo '[3/4] Checking Docker image...' && if ! docker images | grep -q coral-tpu; then echo 'Building coral-tpu Docker image...' && mkdir -p /tmp/coral-docker && cp {artifacts:path}/Dockerfile.tpu {artifacts:path}/tpu_inference_service.py /tmp/coral-docker/ && cd /tmp/coral-docker && docker build -f Dockerfile.tpu -t coral-tpu:latest . && echo 'Docker image built'; else echo 'Docker image already exists'; fi && echo '[4/4] Install complete'",
          "Timeout": 900
        },
        "Run": {
          "RequiresPrivilege": true,
          "Script": "docker run --rm --network host --device=/dev/bus/usb --privileged -e AWS_GG_NUCLEUS_DOMAIN_SOCKET_FILEPATH_FOR_COMPONENT=/greengrass/ipc.socket -e SVCUID -e AWS_CONTAINER_AUTHORIZATION_TOKEN -e AWS_CONTAINER_CREDENTIALS_FULL_URI -v /greengrass/v2/ipc.socket:/greengrass/ipc.socket -v /greengrass/v2/work:/greengrass/v2/work:ro -v /tmp/greengrass_ml:/app/models -v {artifacts:path}:/app/artifacts coral-tpu:latest python3 /app/artifacts/inference_service.py"
        }
      },
      "Artifacts": [
        {
          "Uri": "s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz",
          "Unarchive": "NONE"
        },
        {
          "Uri": "s3://${S3_DATA_BUCKET}/greengrass/artifacts/inference_service.py"
        },
        {
          "Uri": "s3://${S3_DATA_BUCKET}/greengrass/artifacts/Dockerfile.tpu"
        },
        {
          "Uri": "s3://${S3_DATA_BUCKET}/greengrass/artifacts/tpu_inference_service.py"
        }
      ]
    }
  ]
}
MLINFERENCE_EOF

    print_log -g "[ok] " "Component recipes generated with discovered S3 bucket and model path"
    print_log -m "[S3 Bucket] " "${S3_DATA_BUCKET}"
    print_log -m "[Model URI] " "${MODEL_S3_URI}"
    print_log -m "[DataLogger Component] " "com.${PROJECT_NAME}.DataLogger v${DATALOGGER_VERSION}"
    print_log -m "[MLInference Component] " "com.${PROJECT_NAME}.MLInference v${MLINFERENCE_VERSION}"
}

deploy_greengrass_components() {
    print_log -c "[deploy] " "Deploying Greengrass components..."
    
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    
    # Upload artifacts to S3 first
    print_log -c "[upload] " "Uploading component artifacts to S3..."
    
    # Upload DataLogger artifacts
    if ! aws s3 cp "$(dirname "$0")/Greengrass/DataLogger/datalogger.c" "s3://${S3_DATA_BUCKET}/greengrass/artifacts/datalogger.c"; then
        print_log -r "[error] " "Failed to upload datalogger.c"
        return 1
    fi
    if ! aws s3 cp "$(dirname "$0")/Greengrass/DataLogger/streammanager_datalogger.py" "s3://${S3_DATA_BUCKET}/greengrass/artifacts/streammanager_datalogger.py"; then
        print_log -r "[error] " "Failed to upload streammanager_datalogger.py"
        return 1
    fi
    
    # Upload MLInference artifacts
    if ! aws s3 cp "$(dirname "$0")/Greengrass/MLInference/tpu_inference_service.py" "s3://${S3_DATA_BUCKET}/greengrass/artifacts/inference_service.py"; then
        print_log -r "[error] " "Failed to upload inference_service.py"
        return 1
    fi
    if ! aws s3 cp "$(dirname "$0")/Greengrass/MLInference/Dockerfile.tpu" "s3://${S3_DATA_BUCKET}/greengrass/artifacts/Dockerfile.tpu"; then
        print_log -r "[error] " "Failed to upload Dockerfile.tpu"
        return 1
    fi
    if ! aws s3 cp "$(dirname "$0")/Greengrass/MLInference/tpu_inference_service.py" "s3://${S3_DATA_BUCKET}/greengrass/artifacts/tpu_inference_service.py"; then
        print_log -r "[error] " "Failed to upload tpu_inference_service.py"
        return 1
    fi
    
    # Verify all artifacts were uploaded
    print_log -c "[verify] " "Verifying artifact uploads..."
    MISSING_ARTIFACTS=""
    for artifact in "datalogger.c" "streammanager_datalogger.py" "inference_service.py" "Dockerfile.tpu" "tpu_inference_service.py"; do
        if ! aws s3 ls "s3://${S3_DATA_BUCKET}/greengrass/artifacts/${artifact}" > /dev/null 2>&1; then
            MISSING_ARTIFACTS="${MISSING_ARTIFACTS} ${artifact}"
        fi
    done
    
    if [ -n "$MISSING_ARTIFACTS" ]; then
        print_log -r "[error] " "Missing artifacts in S3:${MISSING_ARTIFACTS}"
        return 1
    fi
    
    print_log -g "[ok] " "All artifacts uploaded and verified in S3"
    
    # Create and deploy DataLogger component
    print_log -c "[create] " "Creating DataLogger component..."
    DATALOGGER_VERSION=$(grep -o '"ComponentVersion": "[^"]*"' "$(dirname "$0")/Greengrass/DataLogger/component_recipe.json" | cut -d'"' -f4)
    if aws greengrassv2 create-component-version --inline-recipe fileb://"$(dirname "$0")/Greengrass/DataLogger/component_recipe.json" 2>&1 | tee /tmp/component_create.log; then
        print_log -g "[ok] " "DataLogger component v${DATALOGGER_VERSION} created"
    else
        if grep -q "already exists" /tmp/component_create.log; then
            print_log -y "[skip] " "DataLogger component v${DATALOGGER_VERSION} already exists"
        else
            print_log -r "[error] " "Failed to create DataLogger component"
            cat /tmp/component_create.log
        fi
    fi
    rm -f /tmp/component_create.log
    
    # Create and deploy MLInference component
    print_log -c "[create] " "Creating MLInference component..."
    MLINFERENCE_VERSION=$(grep -o '"ComponentVersion": "[^"]*"' "$(dirname "$0")/Greengrass/MLInference/component_recipe.json" | cut -d'"' -f4)
    if aws greengrassv2 create-component-version --inline-recipe fileb://"$(dirname "$0")/Greengrass/MLInference/component_recipe.json" 2>&1 | tee /tmp/component_create_ml.log; then
        print_log -g "[ok] " "MLInference component v${MLINFERENCE_VERSION} created"
    else
        if grep -q "already exists" /tmp/component_create_ml.log; then
            print_log -y "[skip] " "MLInference component v${MLINFERENCE_VERSION} already exists"
        else
            print_log -r "[error] " "Failed to create MLInference component"
            cat /tmp/component_create_ml.log
        fi
    fi
    rm -f /tmp/component_create_ml.log
    
    # Get component versions
    MLINFERENCE_VERSION=$(grep -o '"ComponentVersion": "[^"]*"' "$(dirname "$0")/Greengrass/MLInference/component_recipe.json" | cut -d'"' -f4 2>/dev/null || echo "1.0.3")
    
    # Create deployment
    print_log -c "[deploy] " "Creating Greengrass deployment..."
    cat > /tmp/deployment.json << DEPLOYMENT_EOF
{
  "targetArn": "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:thing/${GG_THING_NAME}",
  "deploymentName": "${PROJECT_NAME}-deployment-$(date +%s)",
  "components": {
    "com.${PROJECT_NAME}.DataLogger": {
      "componentVersion": "${DATALOGGER_VERSION}",
      "configurationUpdate": {
        "merge": "{\"accessControl\":{\"aws.greengrass.ipc.mqttproxy\":{\"com.${PROJECT_NAME}.DataLogger:mqttproxy:1\":{\"policyDescription\":\"Allow publishing to IoT Core\",\"operations\":[\"aws.greengrass#PublishToIoTCore\"],\"resources\":[\"iot/data\"]}}}}"
      }
    },
    "com.${PROJECT_NAME}.MLInference": {
      "componentVersion": "${MLINFERENCE_VERSION}",
      "configurationUpdate": {
        "merge": "{\"accessControl\":{\"aws.greengrass.ipc.mqttproxy\":{\"com.${PROJECT_NAME}.MLInference:mqttproxy:1\":{\"policyDescription\":\"Allow publishing ML predictions to IoT Core\",\"operations\":[\"aws.greengrass#PublishToIoTCore\"],\"resources\":[\"ml/predictions\"]}},\"aws.greengrass.StreamManager\":{\"com.${PROJECT_NAME}.MLInference:streammanager:1\":{\"policyDescription\":\"Allow full access to StreamManager\",\"operations\":[\"aws.greengrass#CreateMessageStream\",\"aws.greengrass#AppendMessage\",\"aws.greengrass#ReadFromStream\"],\"resources\":[\"*\"]}}}}"
      }
    }
  }
}
DEPLOYMENT_EOF
    
    if DEPLOYMENT_ID=$(aws greengrassv2 create-deployment --cli-input-json file:///tmp/deployment.json --query "deploymentId" --output text 2>/dev/null); then
        print_log -g "[ok] " "Deployment created: ${DEPLOYMENT_ID}"
        print_log -m "[Target] " "GreengrassCore_${PROJECT_NAME}"
        print_log -m "[Components] " "DataLogger v${DATALOGGER_VERSION}, MLInference v${MLINFERENCE_VERSION}"
        print_log -c "[wait] " "Waiting for deployment to complete..."
        
        # Wait for deployment to complete (infinite loop until completed or failed)
        local retry_count=0
        
        while true; do
            DEPLOYMENT_STATUS=$(aws greengrassv2 get-deployment --deployment-id "$DEPLOYMENT_ID" --query "deploymentStatus" --output text 2>/dev/null)
            
            case "$DEPLOYMENT_STATUS" in
                "COMPLETED")
                    print_log -g "[ok] " "Deployment completed successfully!"
                    break
                    ;;
                "FAILED")
                    print_log -r "[error] " "Deployment failed"
                    FAILURE_REASON=$(aws greengrassv2 list-effective-deployments --core-device-thing-name "$GG_THING_NAME" --query "effectiveDeployments[0].reason" --output text 2>/dev/null || echo "Unknown")
                    if [ "$FAILURE_REASON" != "None" ] && [ ! -z "$FAILURE_REASON" ]; then
                        print_log -r "[reason] " "$FAILURE_REASON"
                    fi
                    break
                    ;;
                "ACTIVE"|"IN_PROGRESS")
                    print_log -y "[wait] " "Status: $DEPLOYMENT_STATUS | Elapsed: $((retry_count * 10))s | ID: ${DEPLOYMENT_ID:0:8}..."
                    ;;
                *)
                    print_log -y "[wait] " "Status: $DEPLOYMENT_STATUS | Elapsed: $((retry_count * 10))s | ID: ${DEPLOYMENT_ID:0:8}..."
                    ;;
            esac
            
            retry_count=$((retry_count + 1))
            sleep 10
        done
    else
        print_log -r "[error] " "Failed to create deployment"
        return 1
    fi
    
    # Cleanup
    rm -f /tmp/deployment.json
    
    # Check component status after deployment
    print_log -c "[verify] " "Checking component status on device..."
    sleep 5
    
    # Get component status for DataLogger
    DATALOGGER_STATUS=$(aws greengrassv2 list-installed-components --core-device-thing-name "$GG_THING_NAME" --query "installedComponents[?componentName=='com.${PROJECT_NAME}.DataLogger'].lifecycleState" --output text 2>/dev/null || echo "UNKNOWN")
    if [ "$DATALOGGER_STATUS" = "RUNNING" ]; then
        print_log -g "[ok] " "DataLogger component: RUNNING"
    else
        print_log -y "[status] " "DataLogger component: $DATALOGGER_STATUS"
    fi
    
    # Get component status for MLInference
    MLINFERENCE_STATUS=$(aws greengrassv2 list-installed-components --core-device-thing-name "$GG_THING_NAME" --query "installedComponents[?componentName=='com.${PROJECT_NAME}.MLInference'].lifecycleState" --output text 2>/dev/null || echo "UNKNOWN")
    if [ "$MLINFERENCE_STATUS" = "RUNNING" ]; then
        print_log -g "[ok] " "MLInference component: RUNNING"
    else
        print_log -y "[status] " "MLInference component: $MLINFERENCE_STATUS"
    fi
    
    # If any component is not running, show recent logs
    if [ "$DATALOGGER_STATUS" != "RUNNING" ] || [ "$MLINFERENCE_STATUS" != "RUNNING" ]; then
        print_log -y "[info] " "Checking component logs on Pi..."
        ssh "${PI_SSH_TARGET}" 'bash -s' << 'COMPONENT_LOG_EOF'
echo "[DataLogger logs - last 10 lines]:"
sudo tail -10 /greengrass/v2/logs/com.test.DataLogger.log 2>/dev/null || echo "No DataLogger logs found"
echo ""
echo "[MLInference logs - last 10 lines]:"
sudo tail -10 /greengrass/v2/logs/com.test.MLInference.log 2>/dev/null || echo "No MLInference logs found"
COMPONENT_LOG_EOF
    fi
    
    print_log -g "[ok] " "Component deployment completed"
}

check_pi_dependencies() {
    print_log -c "[check] " "Checking Pi dependencies..."
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'CHECK_EOF'
# Check basic requirements
echo "[check] Checking basic system requirements..."
if ! command -v curl &> /dev/null; then
    echo "ERROR: curl not found"
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "ERROR: unzip not found"
    exit 1
fi

if ! command -v java &> /dev/null; then
    echo "ERROR: Java not found - required for Greengrass"
    exit 1
fi

# Check hardware interfaces
echo "[check] Checking hardware interfaces..."
if [ ! -e /dev/i2c-1 ]; then
    echo "ERROR: I2C interface not enabled"
    exit 1
fi

if [ ! -e /dev/gpiochip0 ]; then
    echo "ERROR: GPIO interface not available"
    exit 1
fi

# Check Docker
echo "[check] Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    echo "WARN: Docker not installed - will install"
else
    echo "OK: Docker found"
fi

echo "[ok] Pi dependency check completed"
CHECK_EOF

    if [ $? -eq 0 ]; then
        print_log -g "[ok] " "Pi dependencies check passed"
        return 0
    else
        print_log -r "[error] " "Pi dependencies check failed"
        return 1
    fi
}

setup_pi_for_greengrass() {
    print_log -c "[pi-setup] " "Setting up Pi for Greengrass and Docker..."
    
    # Check dependencies first
    if ! check_pi_dependencies; then
        print_log -r "[error] " "Pi dependency check failed - please fix issues first"
        return 1
    fi
    
    # Setup Pi using Pi.sh (includes Coral TPU Docker image build)
    if ! bash "$(dirname "$0")/Greengrass/Pi.sh" setup; then
        print_log -r "[error] " "Pi setup failed"
        return 1
    fi
    
    # Verify TPU Docker image was created
    print_log -c "[verify] " "Verifying Coral TPU Docker image..."
    if ssh "${PI_SSH_TARGET}" 'docker images | grep -q coral-tpu'; then
        print_log -g "[ok] " "Coral TPU Docker image found"
        
        # Test TPU detection
        print_log -c "[test] " "Testing TPU detection..."
        if ssh "${PI_SSH_TARGET}" "docker run --rm --privileged --device=/dev/bus/usb coral-tpu:latest python3 -c 'from pycoral.utils import edgetpu; devices = edgetpu.list_edge_tpus(); print(f\"Found {len(devices)} TPU device(s)\" if devices else \"No TPU detected\")' 2>/dev/null"; then
            print_log -g "[ok] " "TPU detection successful"
        else
            print_log -y "[info] " "TPU test completed - device may need initialization"
        fi
    else
        print_log -y "[warn] " "Coral TPU Docker image not found - ML inference may not work"
    fi
    
    print_log -g "[ok] " "Pi setup for Greengrass completed"
    return 0
}

verify_pi_installation() {
    print_log -c "[verify] " "Comprehensive Pi installation verification..."
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'VERIFY_EOF'
echo "[verify] Checking system packages..."
MISSING_PACKAGES=""

# Check basic system packages
for pkg in curl unzip build-essential gnupg ca-certificates; do
    if ! dpkg -l | grep -q "^ii.*$pkg"; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

# Check Java installation
if ! command -v java &> /dev/null; then
    MISSING_PACKAGES="$MISSING_PACKAGES default-jre"
else
    JAVA_VERSION=$(java -version 2>&1 | head -1)
    echo "[ok] Java: $JAVA_VERSION"
fi

# Check Docker installation
if ! command -v docker &> /dev/null; then
    MISSING_PACKAGES="$MISSING_PACKAGES docker.io"
else
    DOCKER_VERSION=$(docker --version 2>/dev/null || echo "Unknown")
    echo "[ok] Docker: $DOCKER_VERSION"
    
    # Check Docker service status
    if systemctl is-active --quiet docker; then
        echo "[ok] Docker service: Running"
    else
        echo "[warn] Docker service: Not running"
    fi
    
    # Check user in docker group
    if groups | grep -q docker; then
        echo "[ok] User in docker group: Yes"
    else
        echo "[warn] User in docker group: No"
    fi
fi

# Check Coral TPU runtime
if dpkg -l | grep -q "^ii.*libedgetpu1-std"; then
    TPU_VERSION=$(dpkg -l | grep libedgetpu1-std | awk '{print $3}')
    echo "[ok] Coral TPU runtime: libedgetpu1-std $TPU_VERSION"
else
    MISSING_PACKAGES="$MISSING_PACKAGES libedgetpu1-std"
fi

# Check Coral repository
if [ -f /etc/apt/sources.list.d/coral-edgetpu.list ]; then
    echo "[ok] Coral repository: Configured"
else
    echo "[warn] Coral repository: Not configured"
fi

# Check GPG key
if [ -f /usr/share/keyrings/coral-edgetpu.gpg ]; then
    echo "[ok] Coral GPG key: Installed"
else
    echo "[warn] Coral GPG key: Missing"
fi

# Check udev rules
if [ -f /etc/udev/rules.d/99-coral.rules ]; then
    echo "[ok] Coral udev rules: Configured"
    cat /etc/udev/rules.d/99-coral.rules | sed 's/^/  /'
else
    echo "[warn] Coral udev rules: Missing"
fi

# Check Docker images
echo "[verify] Checking Docker images..."
if docker images | grep -q coral-tpu; then
    CORAL_IMAGE=$(docker images coral-tpu:latest --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" | tail -1)
    echo "[ok] Coral TPU image: $CORAL_IMAGE"
else
    echo "[error] Coral TPU image: Missing"
fi

# Check hardware interfaces
echo "[verify] Checking hardware interfaces..."
if [ -e /dev/i2c-1 ]; then
    echo "[ok] I2C interface: Available"
else
    echo "[error] I2C interface: Missing"
fi

if [ -e /dev/gpiochip0 ]; then
    echo "[ok] GPIO interface: Available"
else
    echo "[error] GPIO interface: Missing"
fi

# Check SPI interface
if [ -e /dev/spidev0.0 ] || [ -e /dev/spidev0.1 ]; then
    echo "[ok] SPI interface: Available"
else
    echo "[warn] SPI interface: Not available"
fi

# Check USB devices for Coral TPU
echo "[verify] Checking USB devices..."
if lsusb | grep -q "Global Unichip Corp."; then
    USB_DEVICE=$(lsusb | grep "Global Unichip Corp.")
    echo "[ok] Coral TPU USB pre-init: $USB_DEVICE"
elif lsusb | grep -q "Google Inc."; then
    USB_DEVICE=$(lsusb | grep "Google Inc.")
    echo "[ok] Coral TPU USB initialized: $USB_DEVICE"
else
    echo "[info] Coral TPU USB: Not detected"
fi

# Check Greengrass installation
echo "[verify] Checking Greengrass installation..."
if [ -d /greengrass ]; then
    echo "[ok] Greengrass directory: /greengrass exists"
    
    # Check if service file exists
    if [ -f /etc/systemd/system/greengrass.service ]; then
        echo "[ok] Greengrass service file: Exists"
    else
        echo "[warn] Greengrass service file: Missing"
    fi
    
    # Check if service is enabled
    if systemctl is-enabled --quiet greengrass.service 2>/dev/null; then
        echo "[ok] Greengrass service: Enabled"
    else
        echo "[warn] Greengrass service: Not enabled"
    fi
    
    # Check if service is active (more verbose)
    SERVICE_STATE=$(systemctl is-active greengrass.service 2>/dev/null || echo "inactive")
    case "$SERVICE_STATE" in
        "active")
            echo "[ok] Greengrass service: Running"
            ;;
        "inactive")
            echo "[warn] Greengrass service: Stopped"
            ;;
        "failed")
            echo "[error] Greengrass service: Failed"
            # Show recent logs
            echo "[logs] Recent Greengrass logs:"
            journalctl -u greengrass.service --no-pager -n 5 2>/dev/null | sed 's/^/  /' || echo "  No logs available"
            ;;
        *)
            echo "[info] Greengrass service: $SERVICE_STATE"
            ;;
    esac
    
    # Check Greengrass users/groups
    if id ggc_user &>/dev/null; then
        echo "[ok] Greengrass user: ggc_user exists"
    else
        echo "[warn] Greengrass user: ggc_user missing"
    fi
    
    if getent group ggc_group &>/dev/null; then
        echo "[ok] Greengrass group: ggc_group exists"
    else
        echo "[warn] Greengrass group: ggc_group missing"
    fi
    
    # Check if Greengrass is actually running (check process)
    if pgrep -f "greengrass" >/dev/null; then
        echo "[ok] Greengrass process: Running"
    else
        echo "[warn] Greengrass process: Not found"
    fi
else
    echo "[error] Greengrass directory: Missing"
fi

# Summary
if [ -n "$MISSING_PACKAGES" ]; then
    echo "[error] Missing packages:$MISSING_PACKAGES"
    exit 1
else
    echo "[ok] All required packages are installed"
fi

echo "[complete] Pi installation verification finished"
VERIFY_EOF

    local verify_result=$?
    if [ $verify_result -eq 0 ]; then
        print_log -g "[ok] " "Pi installation verification passed"
        return 0
    else
        print_log -r "[error] " "Pi installation verification failed"
        return 1
    fi
}

troubleshoot_greengrass() {
    print_log -c "[troubleshoot] " "Running comprehensive Greengrass troubleshooting diagnostics..."
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << TROUBLESHOOT_EOF
echo "=================================="
echo "GREENGRASS TROUBLESHOOTING REPORT"
echo "=================================="
echo ""

echo "[system] System Information:"
echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  Kernel: $(uname -r)"
echo "  Architecture: $(uname -m)"
echo "  Memory: $(free -h | grep '^Mem:' | awk '{print $2 " total, " $7 " available"}')"
echo "  Disk Space: $(df -h / | tail -1 | awk '{print $4 " available on /"}')" 
echo "  Uptime: $(uptime | cut -d',' -f1)"

echo ""
echo "[java] Java Installation Check:"
if command -v java >/dev/null 2>&1; then
    JAVA_VERSION=$(java -version 2>&1 | head -1)
    echo "  Java: $JAVA_VERSION"
    
    # Check if Java is the correct version for Greengrass
    JAVA_MAJOR=$(java -version 2>&1 | grep -oP 'version "([0-9]+)' | grep -oP '[0-9]+' 2>/dev/null || echo "unknown")
    if [ "$JAVA_MAJOR" -ge 8 ] 2>/dev/null; then
        echo "  Java Version: OK - greater than or equal to 8 required"
    else
        echo "  Java Version: ERROR - need greater than or equal to 8, found: $JAVA_MAJOR"
    fi
    
    # Check Java heap settings
    echo "  Java Heap: $(java -XX:+PrintFlagsFinal -version 2>&1 | grep MaxHeapSize | awk '{print $4/1024/1024 " MB"}' 2>/dev/null || echo "unknown")"
else
    echo "  Java: ✗ NOT FOUND - This will prevent Greengrass from running"
fi

echo ""
echo "[greengrass] Greengrass Installation Analysis:"
if [ -d "/greengrass" ]; then
    echo "  Installation: ✓ Directory exists at /greengrass"
    echo "  Size: $(du -sh /greengrass 2>/dev/null | cut -f1)"
    
    # Check ownership and permissions
    OWNER=$(stat -c '%U:%G' /greengrass 2>/dev/null || echo "unknown")
    PERMS=$(stat -c '%a' /greengrass 2>/dev/null || echo "unknown")
    echo "  Ownership: $OWNER"
    echo "  Permissions: $PERMS"
    
    # Check key directories
    echo "  Directory Structure:"
    for dir in v2 v2/config v2/logs v2/work v2/packages; do
        if [ -d "/greengrass/$dir" ]; then
            SIZE=$(du -sh "/greengrass/$dir" 2>/dev/null | cut -f1)
            echo "    OK /greengrass/$dir - $SIZE"
        else
            echo "    MISSING /greengrass/$dir"
        fi
    done
    
    # Check configuration file
    echo "  Configuration:"
    if [ -f "/greengrass/v2/config/effectiveConfig.yaml" ]; then
        echo "    ✓ Config file exists"
        
        # Extract key config values
        if grep -q "awsRegion" /greengrass/v2/config/effectiveConfig.yaml 2>/dev/null; then
            REGION=$(grep "awsRegion" /greengrass/v2/config/effectiveConfig.yaml | awk '{print $2}' | tr -d '"')
            echo "    AWS Region: $REGION"
        fi
        
        if grep -q "thingName" /greengrass/v2/config/effectiveConfig.yaml 2>/dev/null; then
            THING_NAME=$(grep "thingName" /greengrass/v2/config/effectiveConfig.yaml | awk '{print $2}' | tr -d '"')
            echo "    Thing Name: $THING_NAME"
        fi
        
        if grep -q "iotDataEndpoint" /greengrass/v2/config/effectiveConfig.yaml 2>/dev/null; then
            IOT_ENDPOINT=$(grep "iotDataEndpoint" /greengrass/v2/config/effectiveConfig.yaml | awk '{print $2}' | tr -d '"')
            echo "    IoT Endpoint: $IOT_ENDPOINT"
        fi
    else
        echo "    MISSING Config file effectiveConfig.yaml"
    fi
    
    # Check log files
    echo "  Recent Logs:"
    if [ -f "/greengrass/v2/logs/greengrass.log" ]; then
        LOG_SIZE=$(ls -lh /greengrass/v2/logs/greengrass.log | awk '{print $5}')
        LAST_MODIFIED=$(stat -c '%y' /greengrass/v2/logs/greengrass.log | cut -d'.' -f1)
        echo "    Main log: $LOG_SIZE modified: $LAST_MODIFIED"
        
        # Look for recent errors
        RECENT_ERRORS=$(sudo tail -100 /greengrass/v2/logs/greengrass.log 2>/dev/null | grep -i "error\|exception\|fail" | wc -l)
        if [ "$RECENT_ERRORS" -gt 0 ]; then
            echo "    ⚠ Found $RECENT_ERRORS recent error/exception entries"
        fi
    else
        echo "    ✗ Main log missing"
    fi
    
else
    echo "  Installation: ✗ NOT FOUND at /greengrass"
fi

echo ""
echo "[service] Greengrass Service Analysis:"

# Check if service file exists
if [ -f "/etc/systemd/system/greengrass.service" ]; then
    echo "  Service File: ✓ exists"
    
    # Check service status in detail
    if systemctl is-enabled --quiet greengrass.service 2>/dev/null; then
        echo "  Service Enabled: ✓ yes"
    else
        echo "  Service Enabled: no will not start on boot"
    fi
    
    # Get detailed service status
    SERVICE_STATE=$(systemctl is-active greengrass.service 2>/dev/null || echo "unknown")
    echo "  Service Status: $SERVICE_STATE"
    
    # If failed, get the failure reason
    if [ "$SERVICE_STATE" = "failed" ]; then
        echo "  Failure Analysis:"
        
        # Get exit code
        EXIT_CODE=$(systemctl show -p ExecMainStatus greengrass.service 2>/dev/null | cut -d'=' -f2)
        if [ ! -z "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ]; then
            echo "    Exit Code: $EXIT_CODE"
            case "$EXIT_CODE" in
                "1") echo "    Meaning: General error" ;;
                "2") echo "    Meaning: Misuse of shell command" ;;
                "143") echo "    Meaning: Terminated by SIGTERM graceful shutdown requested" ;;
                "137") echo "    Meaning: Killed by SIGKILL force terminated" ;;
                *) echo "    Meaning: Unknown exit code" ;;
            esac
        fi
        
        # Get recent service logs
        echo "    Recent Service Logs:"
        sudo journalctl -u greengrass.service --no-pager -n 10 --since "1 hour ago" 2>/dev/null | sed 's/^/      /' || echo "      No recent logs available"
    fi
    
else
    echo "  Service File: ✗ missing at /etc/systemd/system/greengrass.service"
fi

echo ""
echo "[users] User and Group Setup:"
if id ggc_user >/dev/null 2>&1; then
    echo "  ggc_user: ✓ exists"
    echo "    Groups: $(groups ggc_user 2>/dev/null)"
    echo "    Home: $(getent passwd ggc_user | cut -d: -f6)"
    echo "    Shell: $(getent passwd ggc_user | cut -d: -f7)"
else
    echo "  ggc_user: ✗ missing"
fi

if getent group ggc_group >/dev/null 2>&1; then
    echo "  ggc_group: ✓ exists"
    GID=$(getent group ggc_group | cut -d: -f3)
    echo "    GID: $GID"
else
    echo "  ggc_group: ✗ missing"
fi

echo ""
echo "[network] Network Connectivity:"

# Test DNS resolution
if nslookup greengrass-ats.iot.amazonaws.com >/dev/null 2>&1; then
    echo "  DNS Resolution: ✓ can resolve greengrass-ats.iot.amazonaws.com"
else
    echo "  DNS Resolution: ✗ cannot resolve AWS IoT endpoint"
fi

# Test internet connectivity
if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    echo "  Internet: ✓ can reach external hosts"
else
    echo "  Internet: ✗ no internet connectivity"
fi

# Test HTTPS connectivity to AWS
if curl -s --connect-timeout 10 https://amazonaws.com >/dev/null 2>&1; then
    echo "  AWS Connectivity: ✓ can reach amazonaws.com"
else
    echo "  AWS Connectivity: ✗ cannot reach AWS services"
fi

echo ""
echo "[certificates] Certificate Analysis:"
CERT_BASE="/greengrass/v2/work/aws.greengrass.Nucleus"
if [ -d "$CERT_BASE/certs" ]; then
    echo "  Certificate Directory: ✓ exists"
    
    # Check individual certificate files
    for certfile in thingCert.crt privKey.key pubKey.key AmazonRootCA1.pem; do
        CERT_PATH="$CERT_BASE/certs/$certfile"
        if [ -f "$CERT_PATH" ]; then
            SIZE=$(ls -lh "$CERT_PATH" | awk '{print $5}')
            echo "  $certfile: exists - $SIZE"
            
            # For the thing certificate, check expiration
            if [ "$certfile" = "thingCert.crt" ]; then
                if command -v openssl >/dev/null 2>&1; then
                    EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d'=' -f2)
                    if [ ! -z "$EXPIRY" ]; then
                        echo "    Expires: $EXPIRY"
                        
                        # Check if certificate is close to expiring (within 30 days)
                        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
                        CURRENT_EPOCH=$(date +%s)
                        DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
                        
                        if [ "$DAYS_LEFT" -lt 30 ] && [ "$DAYS_LEFT" -gt 0 ]; then
                            echo "    ⚠ Certificate expires in $DAYS_LEFT days"
                        elif [ "$DAYS_LEFT" -le 0 ]; then
                            echo "    ✗ Certificate has expired!"
                        fi
                    fi
                fi
            fi
        else
            echo "  $certfile: ✗ missing"
        fi
    done
else
    echo "  Certificate Directory: ✗ not found at $CERT_BASE/certs"
fi

echo ""
echo "[processes] Process Status:"
if pgrep -f greengrass >/dev/null 2>&1; then
    echo "  Greengrass Processes: ✓ running"
    echo "    Details:"
    ps aux | grep -v grep | grep greengrass | while read line; do
        echo "      $line"
    done
else
    echo "  Greengrass Processes: ✗ not running"
fi

echo ""
echo "[recommendations] Troubleshooting Recommendations:"

# Based on the analysis, provide specific recommendations
if [ ! -d "/greengrass" ]; then
    echo "  1. Greengrass is not installed. Run the installer first."
elif ! command -v java >/dev/null 2>&1; then
    echo "  1. Install Java: sudo apt update && sudo apt install -y default-jre"
elif [ ! -f "/etc/systemd/system/greengrass.service" ]; then
    echo "  1. Service file missing. Re-run Greengrass installer with --setup-system-service"
elif ! systemctl is-enabled --quiet greengrass.service 2>/dev/null; then
    echo "  1. Enable service: sudo systemctl enable greengrass.service"
    echo "  2. Start service: sudo systemctl start greengrass.service"
elif ! systemctl is-active --quiet greengrass.service; then
    echo "  1. Check logs: sudo journalctl -u greengrass.service -f"
    echo "  2. Check Greengrass logs: sudo tail -f /greengrass/v2/logs/greengrass.log"
    echo "  3. Restart service: sudo systemctl restart greengrass.service"
else
    echo "  Service appears to be running. Check component deployment status."
fi

echo ""
echo "=================================="
echo "END OF TROUBLESHOOTING REPORT"
echo "=================================="
TROUBLESHOOT_EOF

    print_log -g "[complete] " "Comprehensive troubleshooting diagnostics completed"
}

# --- Function to setup required AWS roles ---
setup_aws_roles() {
    local role_name="GreengrassV2TokenExchangeRole"
    local role_alias_name="GreengrassV2TokenExchangeRoleAlias"

    print_log -c "[aws] " "Checking for required Greengrass IAM roles..."
    
    # Check if role exists
    if ! aws iam get-role --role-name "$role_name" > /dev/null 2>&1; then
        print_log -y "[create] " "Creating IAM Role: ${role_name}..."
        if ! aws iam create-role --role-name "$role_name" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"credentials.iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null 2>&1; then
            print_log -r "[error] " "Failed to create IAM role: ${role_name}"
            return 1
        fi
        
        # Create and attach inline policy for Greengrass V2 Token Exchange
        print_log -y "[create] " "Attaching token exchange policy to role..."
        cat > /tmp/greengrass-token-exchange-policy.json << 'POLICY_EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iot:DescribeCertificate",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "*"
    }
  ]
}
POLICY_EOF
        
        if ! aws iam put-role-policy --role-name "$role_name" --policy-name "GreengrassV2TokenExchangeRoleAccess" --policy-document file:///tmp/greengrass-token-exchange-policy.json; then
            print_log -r "[error] " "Failed to attach policy to role: ${role_name}"
            rm -f /tmp/greengrass-token-exchange-policy.json
            return 1
        fi
        rm -f /tmp/greengrass-token-exchange-policy.json
        
        print_log -g "[ok] " "Role ${role_name} created and policy attached."
        print_log -y "[wait] " "Waiting for IAM role to propagate..."
        sleep 10
    else
        print_log -y "[skip] " "IAM Role '${role_name}' already exists."
    fi

    # Check if role alias exists
    if ! aws iot describe-role-alias --role-alias "$role_alias_name" > /dev/null 2>&1; then
        print_log -y "[create] " "Creating IoT Role Alias: ${role_alias_name}..."
        if ! ROLE_ARN=$(aws iam get-role --role-name "$role_name" --query "Role.Arn" --output text); then
            print_log -r "[error] " "Failed to get role ARN for: ${role_name}"
            return 1
        fi
        if ! aws iot create-role-alias --role-alias "$role_alias_name" --role-arn "$ROLE_ARN"; then
            print_log -r "[error] " "Failed to create role alias: ${role_alias_name}"
            return 1
        fi
        print_log -g "[ok] " "Role alias ${role_alias_name} created."
    else
        print_log -y "[skip] " "IoT Role Alias '${role_alias_name}' already exists."
    fi
}



#--------------------------------#
# Setup Function                 #
#--------------------------------#
setup_greengrass() {
    print_log -b "[greengrass] " "Setting up AWS IoT Greengrass..."
    validate_inputs
    setup_aws_environment

    # Validate PI_SSH_TARGET was provided by AWS.sh
    if [ -z "$PI_SSH_TARGET" ]; then
        print_log -r "[error] " "PI_SSH_TARGET is not set. This should be provided during setup."
        return 1
    fi

    # Validate SSH target format
    if [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
        print_log -r "[error] " "Invalid SSH target format. Must be 'user@host'."
        return 1
    fi

    # Derive resource names and paths
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    local THING_GROUP_NAME="${GG_THING_NAME}_Group"

    print_log -c "[info] " "Greengrass will create its own IoT Thing: ${GG_THING_NAME}"
    print_log -c "[info] " "This is separate from your ESP32 Thing: ${THING_NAME}"

    # Setup Pi first using Pi.sh
    print_log -c "[pi-setup] " "Setting up Raspberry Pi..."
    if ! bash "$(dirname "$0")/Greengrass/Pi.sh" setup; then
        print_log -r "[error] " "Raspberry Pi setup failed"
        return 1
    fi
    
    # Build Coral TPU Docker image
    print_log -c "[docker] " "Building Coral TPU Docker image on Pi..."
    DOCKER_DIR="$(dirname "$0")/Greengrass/MLInference"
    if scp "${DOCKER_DIR}/Dockerfile.tpu" "${DOCKER_DIR}/tpu_inference_service.py" "${PI_SSH_TARGET}:~/coral-docker/"; then
        if ssh "${PI_SSH_TARGET}" "cd ~/coral-docker && docker build -f Dockerfile.tpu -t coral-tpu:latest ."; then
            print_log -g "[ok] " "Coral TPU Docker image built successfully"
        else
            print_log -r "[error] " "Failed to build Docker image"
            return 1
        fi
    else
        print_log -r "[error] " "Failed to upload Docker files"
        return 1
    fi

    # Setup AWS Roles on the local machine
    if ! setup_aws_roles; then
        print_log -r "[error] " "Failed to setup AWS roles"
        return 1
    fi
    
    # Create local IoT credentials for Greengrass core
    if [ -n "${CERT_DIR}" ]; then
        BASE_CERT_DIR=$(dirname "${CERT_DIR}")
    else
        BASE_CERT_DIR="./certificates/IOT"
    fi
    GG_CERT_DIR="${BASE_CERT_DIR}/${GG_THING_NAME}"
    print_log -c "[creds] " "Creating local IoT credentials for Greengrass Thing: ${GG_THING_NAME}"
    
    if mkdir -p "${GG_CERT_DIR}"; then
        # Ensure Thing exists
        if ! aws iot describe-thing --thing-name "${GG_THING_NAME}" > /dev/null 2>&1; then
            print_log -c "[create] " "Creating IoT Thing for Greengrass: ${GG_THING_NAME}..."
            aws iot create-thing --thing-name "${GG_THING_NAME}" > /dev/null 2>&1 || true
        else
            print_log -y "[skip] " "Greengrass Thing '${GG_THING_NAME}' already exists."
        fi

        # Create keys and certificate and save locally
        if GG_CERT_ARN=$(aws iot create-keys-and-certificate --set-as-active \
            --certificate-pem-outfile "${GG_CERT_DIR}/certificate.pem.crt" \
            --private-key-outfile "${GG_CERT_DIR}/private.pem.key" \
            --public-key-outfile "${GG_CERT_DIR}/public.pem.key" \
            --query certificateArn --output text 2>/dev/null); then
            print_log -g "[ok] " "Created Greengrass certificate and keys: ${GG_CERT_DIR}"
            
            # Attach certificate to Thing
            aws iot attach-thing-principal --thing-name "${GG_THING_NAME}" --principal "${GG_CERT_ARN}" 2>/dev/null || true

            # Create IoT policy for the Greengrass core
            GG_IOT_POLICY_NAME="policy-greengrass-${PROJECT_NAME}"
            if ! aws iot get-policy --policy-name "${GG_IOT_POLICY_NAME}" > /dev/null 2>&1; then
                print_log -c "[create] " "Creating IoT Policy: ${GG_IOT_POLICY_NAME}..."
                cat > /tmp/gg-iot-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["iot:Connect"], "Resource": "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:client/${GG_THING_NAME}" }, { "Effect": "Allow", "Action": ["iot:Publish","iot:Subscribe","iot:Receive"], "Resource": "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:topicfilter/*" }] }
EOL
                aws iot create-policy --policy-name "${GG_IOT_POLICY_NAME}" --policy-document file:///tmp/gg-iot-policy.json > /dev/null 2>&1 || true
                rm -f /tmp/gg-iot-policy.json
            else
                print_log -y "[skip] " "IoT Policy '${GG_IOT_POLICY_NAME}' already exists."
            fi

            # Attach policy to certificate
            aws iot attach-policy --policy-name "${GG_IOT_POLICY_NAME}" --target "${GG_CERT_ARN}" 2>/dev/null || true
        fi
    fi

    # Install Greengrass on Pi
    print_log -c "[execute] " "Installing Greengrass on ${PI_SSH_TARGET}..."

    # Get AWS credentials to pass to remote installer
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
    AWS_SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
    
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        print_log -r "[error] " "AWS credentials not found. Please run 'aws configure' first."
        return 1
    fi

    # Create and run Greengrass installer script
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    REMOTE_SCRIPT_LOCAL="${SETUP_DIR}/scripts/greengrass_remote_install.sh"
    REMOTE_SCRIPT_REMOTE="~/greengrass_remote_install.sh"
    
    # Create scripts directory if it doesn't exist
    mkdir -p "${SETUP_DIR}/scripts"

    cat > "${REMOTE_SCRIPT_LOCAL}" <<REMOTE_EOF
#!/usr/bin/env bash
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}"
export AWS_REGION="${AWS_REGION}"
GG_THING_NAME="${GG_THING_NAME}"
THING_GROUP_NAME="${THING_GROUP_NAME}"

# Check prerequisites
echo "[check] Checking Greengrass prerequisites..."
if ! command -v java &> /dev/null; then
    echo "ERROR: Java not found"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "ERROR: curl not found"
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "ERROR: unzip not found"
    exit 1
fi

# Pre-download Amazon Root CA certificate
echo "[ca] Pre-downloading Amazon Root CA certificate..."
sudo mkdir -p /greengrass/v2/work/aws.greengrass.Nucleus/certs
sudo curl -s https://www.amazontrust.com/repository/AmazonRootCA1.pem -o /greengrass/v2/work/aws.greengrass.Nucleus/certs/AmazonRootCA1.pem || true

# Download and install Greengrass
echo "[download] Downloading Greengrass Nucleus software..."
if ! curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip > greengrass-nucleus-latest.zip; then
    echo "ERROR: Failed to download Greengrass Nucleus"
    exit 1
fi

if ! unzip -o greengrass-nucleus-latest.zip -d GreengrassInstaller; then
    echo "ERROR: Failed to extract Greengrass Nucleus"
    exit 1
fi

echo "[install] Running the Greengrass Core installer..."
if ! sudo -E AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
        AWS_REGION="${AWS_REGION}" \
        java -Droot="/greengrass/v2" -Dlog.store=FILE \
      -jar ./GreengrassInstaller/lib/Greengrass.jar \
      --aws-region "${AWS_REGION}" \
      --thing-name "${GG_THING_NAME}" \
      --thing-group-name "${THING_GROUP_NAME}" \
      --tes-role-name "GreengrassV2TokenExchangeRole" \
      --tes-role-alias-name "GreengrassV2TokenExchangeRoleAlias" \
      --component-default-user ggc_user:ggc_group \
      --provision true \
      --setup-system-service true \
      --deploy-dev-tools true; then
    echo "ERROR: Greengrass installation failed"
    exit 1
fi

echo "[ok] Greengrass installer finished."

# Cleanup
rm -f greengrass-nucleus-latest.zip
rm -rf GreengrassInstaller
REMOTE_EOF

    if scp "${REMOTE_SCRIPT_LOCAL}" "${PI_SSH_TARGET}:${REMOTE_SCRIPT_REMOTE}" && \
       ssh "${PI_SSH_TARGET}" "chmod +x ${REMOTE_SCRIPT_REMOTE} && ${REMOTE_SCRIPT_REMOTE}"; then
        print_log -g "[ok] " "Greengrass setup completed successfully."
    else
        print_log -r "[error] " "Greengrass installation failed"
        rm -f "${REMOTE_SCRIPT_LOCAL}"
        return 1
    fi

    # Cleanup local script (contains credentials)
    rm -f "${REMOTE_SCRIPT_LOCAL}"
    print_log -c "[cleanup] " "Removed temporary installation script"

    print_log -m "[Greengrass Thing] " "${GG_THING_NAME}"
    print_log -m "[Thing] " "${THING_NAME}"
    print_log -y "[note] " "Both devices are now registered as separate Things in AWS IoT Core."
    
    # Setup Pi for Greengrass and Docker
    if ! setup_pi_for_greengrass; then
        print_log -r "[error] " "Pi setup for Greengrass failed"
        return 1
    fi
    
    # Verify Greengrass service is running on Pi
    print_log -c "[verify] " "Verifying Greengrass installation on Pi..."
    
    # Get detailed service status
    SERVICE_STATUS=$(ssh "${PI_SSH_TARGET}" 'sudo systemctl status greengrass.service --no-pager -l' 2>/dev/null || echo "Service not found")
    
    # Check service state
    if ssh "${PI_SSH_TARGET}" 'sudo systemctl is-active --quiet greengrass.service'; then
        print_log -g "[ok] " "Greengrass service is running on Pi"
        print_log -c "[status] " "Service details:"
        echo "$SERVICE_STATUS" | sed 's/^/  /'
    else
        # Service is not active - check why
        if echo "$SERVICE_STATUS" | grep -q "Active: failed"; then
            print_log -r "[error] " "Greengrass service has failed"
            
            # Extract exit code and reason
            EXIT_CODE=$(echo "$SERVICE_STATUS" | grep -o 'status=[0-9]*' | cut -d'=' -f2)
            if [ "$EXIT_CODE" = "143" ]; then
                print_log -y "[info] " "Exit code 143 indicates service was terminated SIGTERM"
                print_log -y "[info] " "This usually means a configuration or permission issue"
            elif [ ! -z "$EXIT_CODE" ]; then
                print_log -y "[info] " "Service exited with code: $EXIT_CODE"
            fi
            
            # Check Greengrass logs for more details
            print_log -c "[logs] " "Checking Greengrass application logs..."
            ssh "${PI_SSH_TARGET}" 'bash -s' << 'LOG_EOF'
# Check for Greengrass log directory and recent logs
if [ -d "/greengrass/v2/logs" ]; then
    echo "[logs] Recent Greengrass logs:"
    
    # Check main greengrass log
    if [ -f "/greengrass/v2/logs/greengrass.log" ]; then
        echo "=== greengrass.log (last 10 lines) ==="
        sudo tail -10 /greengrass/v2/logs/greengrass.log 2>/dev/null || echo "Could not read greengrass.log"
    fi
    
    # Check for any error logs
    if ls /greengrass/v2/logs/*error* 2>/dev/null; then
        echo "=== Error logs found ==="
        for errorlog in /greengrass/v2/logs/*error*; do
            echo "--- $errorlog (last 5 lines) ---"
            sudo tail -5 "$errorlog" 2>/dev/null || echo "Could not read $errorlog"
        done
    fi
    
    # Check system logs related to Greengrass
    echo "=== System logs for greengrass service ==="
    sudo journalctl -u greengrass.service --no-pager -n 15 2>/dev/null || echo "No journalctl entries"
    
else
    echo "[error] Greengrass log directory not found at /greengrass/v2/logs"
    echo "[info] Checking if Greengrass is installed..."
    if [ -d "/greengrass" ]; then
        echo "[found] /greengrass directory exists"
        ls -la /greengrass/ 2>/dev/null || echo "Cannot list /greengrass contents"
    else
        echo "[error] /greengrass directory does not exist"
    fi
fi
LOG_EOF
            
        elif echo "$SERVICE_STATUS" | grep -q "Active: inactive"; then
            print_log -y "[warn] " "Greengrass service is inactive (stopped)"
            print_log -y "[info] " "Attempting to start the service..."
            
            if ssh "${PI_SSH_TARGET}" 'sudo systemctl start greengrass.service'; then
                print_log -g "[ok] " "Service started successfully"
                # Wait a moment and check again
                sleep 5
                NEW_STATUS=$(ssh "${PI_SSH_TARGET}" 'sudo systemctl is-active greengrass.service' 2>/dev/null || echo "unknown")
                print_log -c "[status] " "New service status: $NEW_STATUS"
            else
                print_log -r "[error] " "Failed to start Greengrass service"
            fi
            
        else
            print_log -y "[warn] " "Greengrass service status unknown"
        fi
        
        print_log -c "[status] " "Full service status:"
        echo "$SERVICE_STATUS" | sed 's/^/  /'
        
        # Check if service file exists
        if ssh "${PI_SSH_TARGET}" 'sudo systemctl list-unit-files | grep -q greengrass.service'; then
            print_log -c "[info] " "Service file exists but service is not running"
            
            # Check service enable status
            ENABLE_STATUS=$(ssh "${PI_SSH_TARGET}" 'sudo systemctl is-enabled greengrass.service' 2>/dev/null || echo "unknown")
            print_log -c "[enable] " "Service enable status: $ENABLE_STATUS"
            
            if [ "$ENABLE_STATUS" = "disabled" ]; then
                print_log -y "[info] " "Service is disabled - enabling for automatic startup"
                ssh "${PI_SSH_TARGET}" 'sudo systemctl enable greengrass.service' || print_log -y "[warn] " "Could not enable service"
            fi
        else
            print_log -r "[error] " "Greengrass service file not found"
        fi
    fi
    
    # Run comprehensive installation verification
    if ! verify_pi_installation; then
        print_log -r "[error] " "Pi installation verification failed"
        return 1
    fi
    
    # Check if Greengrass service failed and run troubleshooting if needed
    if ssh "${PI_SSH_TARGET}" 'sudo systemctl is-failed --quiet greengrass.service'; then
        print_log -y "[troubleshoot] " "Greengrass service has failed - running diagnostics..."
        troubleshoot_greengrass
        
        print_log -y "[info] " "Attempting to restart Greengrass service..."
        if ssh "${PI_SSH_TARGET}" 'sudo systemctl restart greengrass.service'; then
            print_log -g "[ok] " "Service restart successful"
            sleep 10  # Give it time to start
            
            if ssh "${PI_SSH_TARGET}" 'sudo systemctl is-active --quiet greengrass.service'; then
                print_log -g "[ok] " "Greengrass service is now running"
            fi
        else
            print_log -r "[error] " "Failed to restart Greengrass service"
            return 1
        fi
    fi
    
    # Wait for Greengrass core device to register
    print_log -y "[wait] " "Waiting for Greengrass core device to register..."
    local retry_count=0
    local max_retries=12
    while [ $retry_count -lt $max_retries ]; do
        if aws greengrassv2 get-core-device --core-device-thing-name "$GG_THING_NAME" > /dev/null 2>&1; then
            print_log -g "[ok] " "Greengrass core device registered"
            break
        fi
        retry_count=$((retry_count + 1))
        print_log -y "[wait] " "Core device not yet registered, waiting... (attempt $retry_count/$max_retries)"
        sleep 10
    done
    
    verify_greengrass_connection
    
    # Generate component recipes with proper variables
    generate_component_recipes
    
    # Deploy components
    deploy_greengrass_components
    
    print_log -g "[complete] " "Greengrass setup and component deployment completed successfully!"
    
    return 0
}

#--------------------------------#
# Cleanup Function               #
#--------------------------------#
cleanup_greengrass() {
    print_log -b "[greengrass] " "Cleaning up AWS IoT Greengrass..."
    validate_inputs
    setup_aws_environment

    # Validate PI_SSH_TARGET
    if [ -z "$PI_SSH_TARGET" ]; then
        print_log -r "[error] " "PI_SSH_TARGET is not set."
        return 1
    fi

    # Cleanup Pi setup
    print_log -c "[pi-cleanup] " "Cleaning up Raspberry Pi..."
    bash "$(dirname "$0")/Greengrass/Pi.sh" cleanup 2>/dev/null || print_log -y "[skip] " "Pi cleanup skipped"
    
    # Cancel all existing deployments
    print_log -c "[cleanup] " "Cancelling all existing Greengrass deployments..."
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    DEPLOYMENT_IDS=$(aws greengrassv2 list-deployments --target-arn "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:thing/${GG_THING_NAME}" --query "deployments[?deploymentStatus=='ACTIVE' || deploymentStatus=='IN_PROGRESS'].deploymentId" --output text 2>/dev/null || echo "")
    for DEPLOYMENT_ID in $DEPLOYMENT_IDS; do
        if [ ! -z "$DEPLOYMENT_ID" ] && [ "$DEPLOYMENT_ID" != "None" ]; then
            aws greengrassv2 cancel-deployment --deployment-id "$DEPLOYMENT_ID" 2>/dev/null || true
            print_log -g "[ok] " "Cancelled deployment: $DEPLOYMENT_ID"
        fi
    done
    
    # Cleanup all components
    print_log -c "[cleanup] " "Cleaning up all Greengrass components..."
    for COMPONENT_NAME in "com.${PROJECT_NAME}.DataLogger" "com.${PROJECT_NAME}.MLInference"; do
        if aws greengrassv2 list-component-versions --arn "arn:aws:greengrass:${AWS_REGION}:${ACCOUNT_ID}:components:${COMPONENT_NAME}" > /dev/null 2>&1; then
            VERSIONS=$(aws greengrassv2 list-component-versions --arn "arn:aws:greengrass:${AWS_REGION}:${ACCOUNT_ID}:components:${COMPONENT_NAME}" --query "componentVersions[].componentVersion" --output text 2>/dev/null || echo "")
            for version in $VERSIONS; do
                aws greengrassv2 delete-component --arn "arn:aws:greengrass:${AWS_REGION}:${ACCOUNT_ID}:components:${COMPONENT_NAME}:versions:${version}" 2>/dev/null || true
            done
            print_log -g "[ok] " "Deleted component: $COMPONENT_NAME"
        fi
    done
    

    # Cleanup AWS Roles
    print_log -c "[cleanup] " "Deleting Greengrass IAM roles..."
    aws iot delete-role-alias --role-alias "GreengrassV2TokenExchangeRoleAlias" > /dev/null 2>&1 || true
    
    if aws iam get-role --role-name "GreengrassV2TokenExchangeRole" > /dev/null 2>&1; then
        aws iam delete-role-policy --role-name "GreengrassV2TokenExchangeRole" --policy-name "GreengrassV2TokenExchangeRoleAccess" > /dev/null 2>&1 || true
        aws iam delete-role --role-name "GreengrassV2TokenExchangeRole" > /dev/null 2>&1 || true
        print_log -g "[ok] " "Deleted IAM role."
    fi

    # Cleanup IoT Thing and related resources
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    local GG_THING_GROUP="${GG_THING_NAME}_Group"
    
    if aws iot describe-thing --thing-name "${GG_THING_NAME}" > /dev/null 2>&1; then
        print_log -c "[delete] " "Cleaning up Greengrass IoT Thing: ${GG_THING_NAME}..."
        
        # Delete certificates and policies
        PRINCIPALS=$(aws iot list-thing-principals --thing-name "${GG_THING_NAME}" --query principals --output text 2>/dev/null || echo "")
        for GG_CERT_ARN in ${PRINCIPALS}; do
            if [ ! -z "${GG_CERT_ARN}" ] && [ "${GG_CERT_ARN}" != "None" ]; then
                GG_CERT_ID=$(basename "${GG_CERT_ARN}")
                
                # Detach and delete policies
                POLICY_NAMES=$(aws iot list-attached-policies --target "${GG_CERT_ARN}" --query "policies[].policyName" --output text 2>/dev/null || echo "")
                for POLICY_NAME in ${POLICY_NAMES}; do
                    aws iot detach-policy --policy-name "${POLICY_NAME}" --target "${GG_CERT_ARN}" 2>/dev/null || true
                    aws iot delete-policy --policy-name "${POLICY_NAME}" 2>/dev/null || true
                done
                
                # Detach and delete certificate
                aws iot detach-thing-principal --thing-name "${GG_THING_NAME}" --principal "${GG_CERT_ARN}" 2>/dev/null || true
                aws iot update-certificate --certificate-id "${GG_CERT_ID}" --new-status INACTIVE 2>/dev/null || true
                aws iot delete-certificate --certificate-id "${GG_CERT_ID}" --force-delete 2>/dev/null || true
            fi
        done
        
        # Delete Greengrass core device and Thing
        aws greengrassv2 delete-core-device --core-device-thing-name "${GG_THING_NAME}" > /dev/null 2>&1 || true
        aws iot delete-thing --thing-name "${GG_THING_NAME}" 2>/dev/null || true
        print_log -g "[ok] " "Greengrass Thing deleted"
    fi

    # Delete Thing Group
    aws iot delete-thing-group --group-name "${GG_THING_GROUP}" 2>/dev/null || true

    # Remote cleanup
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'EOF'
sudo systemctl stop greengrass.service 2>/dev/null || true
sudo systemctl disable greengrass.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/greengrass.service
sudo systemctl daemon-reload
sudo rm -rf /greengrass
if id "ggc_user" &>/dev/null; then sudo userdel ggc_user 2>/dev/null || true; fi
if getent group "ggc_group" &>/dev/null; then sudo groupdel ggc_group 2>/dev/null || true; fi
echo "Rebooting Pi to ensure clean state..."
sudo reboot
EOF

    print_log -g "[ok] " "Greengrass cleanup completed successfully."
    return 0
}

#--------------------------------#
# Main Execution Logic           #
#--------------------------------#
if [ "$1" = "setup" ]; then
    setup_greengrass
elif [ "$1" = "cleanup" ]; then
    cleanup_greengrass
else
    print_log -r "[error] " "Invalid argument. Use 'setup' or 'cleanup'."
    exit 1
fi