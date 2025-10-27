#!/usr/bin/env bash
export AWS_ACCESS_KEY_ID="AKIAU64TIM2H2LW4Z7UV"
export AWS_SECRET_ACCESS_KEY="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"
export AWS_SESSION_TOKEN=""
export AWS_REGION="ap-southeast-1"
GG_THING_NAME="GreengrassCore_test"
THING_GROUP_NAME="GreengrassCore_test_Group"

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
if ! sudo -E AWS_ACCESS_KEY_ID="AKIAU64TIM2H2LW4Z7UV"         AWS_SECRET_ACCESS_KEY="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"         AWS_SESSION_TOKEN=""         AWS_REGION="ap-southeast-1"         java -Droot="/greengrass/v2" -Dlog.store=FILE       -jar ./GreengrassInstaller/lib/Greengrass.jar       --aws-region "ap-southeast-1"       --thing-name "GreengrassCore_test"       --thing-group-name "GreengrassCore_test_Group"       --tes-role-name "GreengrassV2TokenExchangeRole"       --tes-role-alias-name "GreengrassV2TokenExchangeRoleAlias"       --component-default-user ggc_user:ggc_group       --provision true       --setup-system-service true       --deploy-dev-tools true; then
    echo "ERROR: Greengrass installation failed"
    exit 1
fi

echo "[ok] Greengrass installer finished."

# Cleanup
rm -f greengrass-nucleus-latest.zip
rm -rf GreengrassInstaller
