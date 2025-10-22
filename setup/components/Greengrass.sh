#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Greengrass Component               |--/ /-|#
#|-/ /--| Installs Greengrass on Raspberry Pi|-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

# --- Function to setup required AWS roles ---
setup_aws_roles() {
    local role_name="GreengrassV2TokenExchangeRole"
    local role_alias_name="GreengrassV2TokenExchangeRoleAlias"

    print_log -c "[aws-setup] " "Checking for required Greengrass IAM roles..."
    
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
        "s3:GetBucketLocation"
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
    # Use a distinct Thing name for Greengrass Core (separate from ESP32)
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    local THING_GROUP_NAME="${GG_THING_NAME}_Group"

    print_log -c "[info] " "Greengrass will create its own IoT Thing: ${GG_THING_NAME}"
    print_log -c "[info] " "This is separate from your ESP32 Thing: ${THING_NAME}"

    # Setup AWS Roles on the local machine
    if ! setup_aws_roles; then
        print_log -r "[error] " "Failed to setup AWS roles"
        return 1
    fi
    
    # --- Create local IoT credentials for Greengrass core (save under certificates like IoT) ---
    # Use the global CERT_DIR exported by common.sh as the base (CERT_DIR points to ./certificates/IOT/<THING_NAME>)
    if [ -n "${CERT_DIR}" ]; then
        BASE_CERT_DIR=$(dirname "${CERT_DIR}")
    else
        BASE_CERT_DIR="./certificates/IOT"
    fi
    GG_CERT_DIR="${BASE_CERT_DIR}/${GG_THING_NAME}"
    print_log -c "[creds] " "Creating local IoT credentials for Greengrass Thing: ${GG_THING_NAME} -> ${GG_CERT_DIR}"
    if ! mkdir -p "${GG_CERT_DIR}"; then
        print_log -y "[warn] " "Failed to create certificate directory ${GG_CERT_DIR}, continuing without saving certs locally."
    else
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

            # Create a simple IoT policy for the Greengrass core (if not present)
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

            # Export local variables for other steps or cleanup
            export GG_CERT_ARN
            export GG_CERT_DIR
            export GG_IOT_POLICY_NAME
        else
            print_log -y "[warn] " "Failed to create Greengrass keys/certificate via AWS CLI. Installer may provision on-device instead."
        fi
    fi
    
    # Check if SSH key authentication is set up
    print_log -c "[ssh] " "Checking SSH authentication method..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${PI_SSH_TARGET}" 'exit' 2>/dev/null; then
        print_log -g "[ok] " "SSH key authentication is configured. No password prompts needed."
    else
        print_log -y "[info] " "SSH key authentication not configured. You will be prompted for password."
        echo ""
        read -p "Would you like to set up SSH key authentication now? (recommended) [y/N]: " setup_ssh_key
        if [[ "$setup_ssh_key" =~ ^[yY]([eE][sS])?$ ]]; then
            print_log -c "[setup] " "Setting up SSH key authentication..."
            
            # Check if SSH key exists, create if not
            if [ ! -f "$HOME/.ssh/id_rsa.pub" ] && [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
                print_log -y "[create] " "No SSH key found. Creating one..."
                ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "greengrass-setup@$(hostname)"
                print_log -g "[ok] " "SSH key created."
            fi
            
            # Copy SSH key to Pi
            print_log -y "[copy] " "Copying SSH key to ${PI_SSH_TARGET}..."
            print_log -y "[info] " "You will be prompted for your Pi's password one time."
            if ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" "${PI_SSH_TARGET}" 2>/dev/null || \
               ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "${PI_SSH_TARGET}" 2>/dev/null; then
                print_log -g "[ok] " "SSH key authentication configured successfully!"
                print_log -g "[info] " "You won't need to enter password again for this Pi."
            else
                print_log -y "[warn] " "Failed to set up SSH key. Continuing with password authentication."
            fi
            echo ""
        fi
    fi

    print_log -c "[execute] " "Beginning remote setup on ${PI_SSH_TARGET}..."
    print_log -y "[info] " "This may take several minutes. Please be patient..."

    # Get AWS credentials to pass to remote installer
    print_log -c "[credentials] " "Preparing AWS credentials for remote installation..."
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
    AWS_SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
    
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        print_log -r "[error] " "AWS credentials not found. Please run 'aws configure' first."
        return 1
    fi
    
    # Debug: Show what we're passing
    print_log -c "[debug] " "Local AWS_REGION: ${AWS_REGION}"
    print_log -c "[debug] " "Local GG_THING_NAME: ${GG_THING_NAME}"
    print_log -c "[debug] " "Local THING_GROUP_NAME: ${THING_GROUP_NAME}"

    # Prepare a local temporary remote script with expanded variables, then copy & run it on the Pi.
    REMOTE_SCRIPT_LOCAL="/tmp/greengrass_remote_install.sh"
    REMOTE_SCRIPT_REMOTE="/tmp/greengrass_remote_install.sh"

    print_log -c "[plan] " "Generating temporary remote installer script: ${REMOTE_SCRIPT_LOCAL}"

    cat > "${REMOTE_SCRIPT_LOCAL}" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -e

# Exported environment variables (will be replaced by sed below)
export AWS_ACCESS_KEY_ID="__AWS_ACCESS_KEY_ID__"
export AWS_SECRET_ACCESS_KEY="__AWS_SECRET_ACCESS_KEY__"
export AWS_SESSION_TOKEN="__AWS_SESSION_TOKEN__"
export AWS_REGION="__AWS_REGION__"
GG_THING_NAME="__GG_THING_NAME__"
THING_GROUP_NAME="__THING_GROUP_NAME__"

# Simple print_log for remote
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'
print_log() { local color_map="-b:${BLUE} -g:${GREEN} -r:${RED} -y:${YELLOW} -p:${PURPLE} -c:${CYAN} -m:${PURPLE}"; local color="${BLUE}"; local prefix="$1"; local message="$2"; if [[ "$1" =~ ^- ]]; then for map in $color_map; do local flag="${map%%:*}"; local clr="${map#*:}"; if [ "$1" == "$flag" ]; then color="$clr"; prefix="$2"; message="$3"; break; fi; done; fi; echo -e "${color}${prefix}${NC}${message}"; }

print_log -c "[debug] " "Remote AWS_REGION: ${AWS_REGION}"
print_log -c "[debug] " "Remote GG_THING_NAME: ${GG_THING_NAME}"

if [ -z "${AWS_REGION}" ] || [ -z "${GG_THING_NAME}" ]; then
  print_log -r "[error] " "AWS_REGION or GG_THING_NAME not set in remote script"
  exit 1
fi

# Install prerequisites
print_log -c "[check] " "Verifying and installing dependencies..."
if ! command -v java &> /dev/null; then
  print_log -y "[install] " "Java not found. Installing default JRE..."
  sudo apt-get update -qq
  sudo apt-get install -y default-jre
fi
if ! command -v curl &> /dev/null; then
  sudo apt-get install -y curl
fi
if ! command -v unzip &> /dev/null; then
  sudo apt-get install -y unzip
fi
print_log -g "[ok] " "All dependencies are ready."

# Download and install Greengrass
print_log -c "[download] " "Downloading Greengrass Nucleus software..."
curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip > greengrass-nucleus-latest.zip
unzip -o greengrass-nucleus-latest.zip -d GreengrassInstaller
print_log -g "[ok] " "Downloads complete."

print_log -c "[install] " "Running the Greengrass Core installer with sudo..."
sudo -E AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
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
      --deploy-dev-tools true

print_log -g "[ok] " "Greengrass installer finished."

# Cleanup
rm -f greengrass-nucleus-latest.zip
rm -rf GreengrassInstaller

REMOTE_EOF

    # Replace placeholders with actual values (safe for single quotes)
    sed -i "s|__AWS_ACCESS_KEY_ID__|${AWS_ACCESS_KEY_ID}|g" "${REMOTE_SCRIPT_LOCAL}"
    sed -i "s|__AWS_SECRET_ACCESS_KEY__|${AWS_SECRET_ACCESS_KEY}|g" "${REMOTE_SCRIPT_LOCAL}"
    sed -i "s|__AWS_SESSION_TOKEN__|${AWS_SESSION_TOKEN}|g" "${REMOTE_SCRIPT_LOCAL}"
    sed -i "s|__AWS_REGION__|${AWS_REGION}|g" "${REMOTE_SCRIPT_LOCAL}"
    sed -i "s|__GG_THING_NAME__|${GG_THING_NAME}|g" "${REMOTE_SCRIPT_LOCAL}"
    sed -i "s|__THING_GROUP_NAME__|${THING_GROUP_NAME}|g" "${REMOTE_SCRIPT_LOCAL}"

    print_log -c "[scp] " "Copying remote installer to ${PI_SSH_TARGET}:${REMOTE_SCRIPT_REMOTE}..."
    if ! scp -o BatchMode=no "${REMOTE_SCRIPT_LOCAL}" "${PI_SSH_TARGET}:${REMOTE_SCRIPT_REMOTE}"; then
        print_log -r "[error] " "Failed to copy remote installer script"
        rm -f "${REMOTE_SCRIPT_LOCAL}"
        return 1
    fi

    print_log -c "[exec] " "Executing remote installer script..."
    if ! ssh -o BatchMode=no "${PI_SSH_TARGET}" "chmod +x ${REMOTE_SCRIPT_REMOTE} && sudo ${REMOTE_SCRIPT_REMOTE}"; then
        print_log -r "[error] " "Remote setup script failed."
        ssh -o BatchMode=no "${PI_SSH_TARGET}" "rm -f ${REMOTE_SCRIPT_REMOTE}" 2>/dev/null || true
        rm -f "${REMOTE_SCRIPT_LOCAL}"
        return 1
    fi

    # Cleanup remote and local temporary scripts
    ssh -o BatchMode=no "${PI_SSH_TARGET}" "rm -f ${REMOTE_SCRIPT_REMOTE}" 2>/dev/null || true
    rm -f "${REMOTE_SCRIPT_LOCAL}"

    print_log -g "[ok] " "Greengrass setup completed successfully."
    print_log -m "[Greengrass Thing] " "${GG_THING_NAME}"
    print_log -m "[Thing] " "${THING_NAME}"
    print_log -y "[note] " "Both devices are now registered as separate Things in AWS IoT Core."
    return 0
}

#--------------------------------#
# Cleanup Function               #
#--------------------------------#
cleanup_greengrass() {
    print_log -b "[greengrass] " "Cleaning up AWS IoT Greengrass..."
    validate_inputs
    setup_aws_environment

    # Validate PI_SSH_TARGET was provided by AWS.sh
    if [ -z "$PI_SSH_TARGET" ]; then
        print_log -r "[error] " "PI_SSH_TARGET is not set. This should be provided during cleanup."
        return 1
    fi

    # Validate SSH target format
    if [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
        print_log -r "[error] " "Invalid SSH target format. Must be 'user@host'."
        return 1
    fi
    
    # Cleanup AWS Roles
    print_log -c "[cleanup] " "Deleting Greengrass IAM roles..."
    if aws iot delete-role-alias --role-alias "GreengrassV2TokenExchangeRoleAlias" > /dev/null 2>&1; then
        print_log -g "[ok] " "Deleted role alias."
    else
        print_log -y "[skip] " "Role alias not found or already deleted."
    fi

    if aws iam get-role --role-name "GreengrassV2TokenExchangeRole" > /dev/null 2>&1; then
        # Delete inline policy first
        if ! aws iam delete-role-policy --role-name "GreengrassV2TokenExchangeRole" --policy-name "GreengrassV2TokenExchangeRoleAccess" > /dev/null 2>&1; then
            print_log -y "[warn] " "Failed to delete inline policy from role, continuing..."
        fi
        
        # Now delete the role
        if ! aws iam delete-role --role-name "GreengrassV2TokenExchangeRole"; then
            print_log -y "[warn] " "Failed to delete IAM role, it may have dependencies."
        else
            print_log -g "[ok] " "Deleted IAM role."
        fi
    else
        print_log -y "[skip] " "IAM role not found or already deleted."
    fi

    print_log -c "[connect] " "Connecting to ${PI_SSH_TARGET} to perform remote cleanup..."
    # --- Cleanup IoT Thing and related resources for Greengrass ---
    local GG_THING_NAME="GreengrassCore_${PROJECT_NAME}"
    local GG_THING_GROUP="${GG_THING_NAME}_Group"
    print_log -c "[delete] " "Cleaning up Greengrass IoT Thing and related resources: ${GG_THING_NAME}..."

    # If the Greengrass Thing exists, iterate all principals, detach and delete certificates, then delete the Thing
    if aws iot describe-thing --thing-name "${GG_THING_NAME}" > /dev/null 2>&1; then
        print_log -c "[info] " "Found Greengrass Thing: ${GG_THING_NAME}. Enumerating principals..."
        PRINCIPALS=$(aws iot list-thing-principals --thing-name "${GG_THING_NAME}" --query principals --output text 2>/dev/null || echo "")
        if [ ! -z "${PRINCIPALS}" ] && [ "${PRINCIPALS}" != "None" ]; then
            # PRINCIPALS may contain multiple ARNs separated by newlines or spaces
            for GG_CERT_ARN in ${PRINCIPALS}; do
                if [ -z "${GG_CERT_ARN}" ] || [ "${GG_CERT_ARN}" == "None" ]; then
                    continue
                fi
                GG_CERT_ID=$(basename "${GG_CERT_ARN}")
                print_log -c "[step 1] " "Finding certificate attached to Thing '${GG_THING_NAME}'..."
                print_log -g "[ok] " "Found certificate: ${GG_CERT_ID}"

                # 2. Find, detach, and delete associated policies
                print_log -c "[step 2] " "Finding, detaching, and deleting associated policies for ${GG_CERT_ID}..."
                POLICY_NAMES=$(aws iot list-attached-policies --target "${GG_CERT_ARN}" --query "policies[].policyName" --output text 2>/dev/null | tr -s '\t' ' ')
                if [ -z "${POLICY_NAMES}" ]; then
                    print_log -y "[skip] " "No policies found attached to the certificate ${GG_CERT_ID}."
                else
                    for POLICY_NAME in ${POLICY_NAMES}; do
                        print_log -y "[detach] " "Detaching policy '${POLICY_NAME}'..."
                        aws iot detach-policy --policy-name "${POLICY_NAME}" --target "${GG_CERT_ARN}" 2>/dev/null || true
                    done
                    print_log -g "[ok] " "All policies detached from ${GG_CERT_ID}."

                    for POLICY_NAME in ${POLICY_NAMES}; do
                        print_log -r "[delete] " "Deleting policy '${POLICY_NAME}'..."
                        aws iot delete-policy --policy-name "${POLICY_NAME}" 2>/dev/null || true
                    done
                    print_log -g "[ok] " "All associated policies deleted for ${GG_CERT_ID}."
                fi

                # 3. Detach the certificate from the Thing
                print_log -c "[step 3] " "Detaching certificate ${GG_CERT_ARN} from Thing '${GG_THING_NAME}'..."
                aws iot detach-thing-principal --thing-name "${GG_THING_NAME}" --principal "${GG_CERT_ARN}" 2>/dev/null || true
                print_log -g "[ok] " "Certificate detached."

                # 4. Deactivate and delete the certificate
                print_log -c "[step 4] " "Deactivating and deleting certificate '${GG_CERT_ID}'..."
                aws iot update-certificate --certificate-id "${GG_CERT_ID}" --new-status INACTIVE 2>/dev/null || true
                aws iot delete-certificate --certificate-id "${GG_CERT_ID}" --force-delete 2>/dev/null || true
                print_log -g "[ok] " "Certificate ${GG_CERT_ID} deleted."
            done
        else
            print_log -y "[skip] " "No principals found for ${GG_THING_NAME}."
        fi

        # Remove thing from any groups it belongs to before deleting thing group
        GROUPS=$(aws iot list-thing-groups-for-thing --thing-name "${GG_THING_NAME}" --query thingGroups[].groupName --output text 2>/dev/null || echo "")
        if [ ! -z "${GROUPS}" ]; then
            for g in ${GROUPS}; do
                print_log -c "[delete] " "Removing ${GG_THING_NAME} from thing group ${g}..."
                aws iot remove-thing-from-thing-group --thing-name "${GG_THING_NAME}" --thing-group-name "${g}" 2>/dev/null || true
            done
        fi

        # Remove Greengrass core device resource from GreengrassV2 (if present)
        print_log -c "[ggv2] " "Deleting Greengrass core device resource for Thing '${GG_THING_NAME}'..."
        if aws greengrassv2 delete-core-device --core-device-thing-name "${GG_THING_NAME}" > /dev/null 2>&1; then
            print_log -g "[ok] " "Greengrass core device deleted from GreengrassV2 service."
        else
            print_log -y "[skip] " "No GreengrassV2 core-device resource found for '${GG_THING_NAME}' or deletion failed."
        fi

        print_log -c "[delete] " "Deleting Greengrass IoT Thing..."
        aws iot delete-thing --thing-name "${GG_THING_NAME}" 2>/dev/null || true
    else
        print_log -y "[skip] " "Greengrass Thing '${GG_THING_NAME}' does not exist."
    fi

    # Delete Greengrass Thing Group if it exists
    if aws iot describe-thing-group --group-name "${GG_THING_GROUP}" > /dev/null 2>&1; then
        print_log -c "[delete] " "Deleting Greengrass Thing Group: ${GG_THING_GROUP}..."
        aws iot delete-thing-group --group-name "${GG_THING_GROUP}" 2>/dev/null || true
    else
        print_log -y "[skip] " "Greengrass Thing Group '${GG_THING_GROUP}' not found."
    fi

    if ! ssh "${PI_SSH_TARGET}" 'bash -s' << EOF
    # --- This entire block runs on the Raspberry Pi ---
    
    # Define print function for the remote session
    export NC='\033[0m'; export RED='\033[0;31m'; export GREEN='\033[0;32m'; export YELLOW='\033[0;33m'; export BLUE='\033[0;34m'; export CYAN='\033[0;36m'; export PURPLE='\033[0;35m'
    print_log() { local color_map="-b:\${BLUE} -g:\${GREEN} -r:\${RED} -y:\${YELLOW} -c:\${CYAN} -p:\${PURPLE} -m:\${PURPLE}"; local color="\${BLUE}"; local prefix="\$1"; local message="\$2"; if [[ "\$1" =~ ^- ]]; then for map in \$color_map; do local flag="\${map%%:*}"; local clr="\${map#*:}"; if [ "\$1" == "\$flag" ]; then color="\$clr"; prefix="\$2"; message="\$3"; break; fi; done; fi; echo -e "\${color}\${prefix}\${NC}\${message}"; }

    print_log -g "[ok] " "Connected to Pi. Starting cleanup..."

    print_log -c "[stop] " "Stopping and disabling the Greengrass service..."
    sudo systemctl stop greengrass.service 2>/dev/null || true
    sudo systemctl disable greengrass.service 2>/dev/null || true
    print_log -g "[ok] " "Service stopped and disabled."

    print_log -c "[remove] " "Removing systemd service file..."
    if [ -f "/etc/systemd/system/greengrass.service" ]; then
        sudo rm -f /etc/systemd/system/greengrass.service
        sudo systemctl daemon-reload
    fi

    print_log -c "[remove] " "Deleting Greengrass installation directory and user..."
    sudo rm -rf /greengrass
    if id "ggc_user" &>/dev/null; then sudo userdel ggc_user 2>/dev/null || true; fi
    if getent group "ggc_group" &>/dev/null; then sudo groupdel ggc_group 2>/dev/null || true; fi
    
    print_log -g "[ok] " "Remote cleanup complete."
EOF
    then
        print_log -r "[error] " "Remote cleanup script failed."
        return 1
    fi
    
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
