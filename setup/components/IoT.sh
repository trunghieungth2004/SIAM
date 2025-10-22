#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| IoT Core Component                 |--/ /-|#
#|-/ /--| Creates IoT Things, certs, rules   |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_iot() {
    print_log -c "[iot] " "Setting up IoT Core..."
    validate_inputs
    setup_aws_environment

    # Get Lambda function ARN if not provided
    if [ -z "$LAMBDA_FUNCTION_ARN" ]; then
        LAMBDA_FUNCTION_NAME="func-ingestion-${PROJECT_NAME}"
        LAMBDA_FUNCTION_ARN=$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --query Configuration.FunctionArn --output text 2>/dev/null)
    fi

    print_log -c "[iot] " "Configuring IoT Thing, Certificate, and Policy..."
    if ! aws iot describe-thing --thing-name $THING_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating IoT Thing: ${THING_NAME}..."
        if ! aws iot create-thing --thing-name $THING_NAME; then
            print_log -r "[error] " "Failed to create IoT Thing: ${THING_NAME}"
            return 1
        fi
        
        if ! mkdir -p $CERT_DIR; then
            print_log -r "[error] " "Failed to create certificate directory: ${CERT_DIR}"
            return 1
        fi
        print_log -c "[create] " "Creating and saving new certificates to '${CERT_DIR}/'..."

        if ! CERT_ARN=$(aws iot create-keys-and-certificate --set-as-active \
            --certificate-pem-outfile "${CERT_DIR}/certificate.pem.crt" \
            --private-key-outfile "${CERT_DIR}/private.pem.key" \
            --public-key-outfile "${CERT_DIR}/public.pem.key" \
            --query certificateArn --output text); then
            print_log -r "[error] " "Failed to create IoT certificates"
            return 1
        fi
        
        # Verify certificate files were created
        if [ ! -f "${CERT_DIR}/certificate.pem.crt" ] || [ ! -f "${CERT_DIR}/private.pem.key" ]; then
            print_log -r "[error] " "Certificate files were not created properly"
            return 1
        fi
        
        print_log -r "[important] " "Certificates saved to '${CERT_DIR}/'. Back them up securely."
        if ! aws iot attach-thing-principal --thing-name $THING_NAME --principal $CERT_ARN; then
            print_log -r "[error] " "Failed to attach certificate to IoT Thing"
            return 1
        fi
    else
        print_log -y "[skip] " "IoT Thing '${THING_NAME}' already exists."
        if ! CERT_ARN=$(aws iot list-thing-principals --thing-name $THING_NAME --query principals[0] --output text); then
            print_log -r "[error] " "Failed to get certificate ARN for existing Thing"
            return 1
        fi
        if [ "$CERT_ARN" == "None" ] || [ -z "$CERT_ARN" ]; then
            print_log -r "[error] " "No certificate found for existing IoT Thing"
            return 1
        fi
        print_log -y "[info] " "Using existing certificate: ${CERT_ARN}"
    fi

    IOT_POLICY_NAME="policy-iot-${PROJECT_NAME}"
    if ! aws iot get-policy --policy-name $IOT_POLICY_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating IoT Policy: ${IOT_POLICY_NAME}..."
        cat > iot-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "iot:Connect", "Resource": "arn:aws:iot:$AWS_REGION:$ACCOUNT_ID:client/$THING_NAME" }, { "Effect": "Allow", "Action": "iot:Publish", "Resource": "arn:aws:iot:$AWS_REGION:$ACCOUNT_ID:topic/esp32/esp32-to-aws" }] }
EOL
        if ! aws iot create-policy --policy-name $IOT_POLICY_NAME --policy-document file://iot-policy.json; then
            print_log -r "[error] " "Failed to create IoT Policy: ${IOT_POLICY_NAME}"
            return 1
        fi
    else
        print_log -y "[skip] " "IoT Policy '${IOT_POLICY_NAME}' already exists."
    fi
    
    if ! aws iot attach-policy --policy-name $IOT_POLICY_NAME --target $CERT_ARN; then
        print_log -r "[error] " "Failed to attach IoT Policy to certificate"
        return 1
    fi

    # Create IoT Rule only if Lambda function exists
    if [ ! -z "$LAMBDA_FUNCTION_ARN" ]; then
        IOT_RULE_NAME="rule_ingestion_${PROJECT_NAME}"
        if ! aws iot get-topic-rule --rule-name $IOT_RULE_NAME > /dev/null 2>&1; then
            print_log -c "[iot] " "Creating IoT Rule to trigger Lambda..."
            # Match the actual topic your ESP32 is publishing to
            if ! aws iot create-topic-rule --rule-name $IOT_RULE_NAME --topic-rule-payload "{\"sql\": \"SELECT * FROM 'esp32/esp32-to-aws'\", \"actions\": [{\"lambda\": {\"functionArn\": \"$LAMBDA_FUNCTION_ARN\"}}]}"; then
                print_log -r "[error] " "Failed to create IoT Rule: ${IOT_RULE_NAME}"
                return 1
            fi
            
            if ! aws lambda add-permission --function-name $LAMBDA_FUNCTION_NAME --statement-id "IoTRulePermission" --action "lambda:InvokeFunction" --principal iot.amazonaws.com --source-arn "arn:aws:iot:$AWS_REGION:$ACCOUNT_ID:rule/$IOT_RULE_NAME"; then
                print_log -r "[error] " "Failed to add Lambda permission for IoT Rule"
                return 1
            fi
            print_log -g "[ok] " "IoT Rule created for topic: esp32/esp32-to-aws"
        else
            print_log -y "[skip] " "IoT Rule '${IOT_RULE_NAME}' already exists."
        fi
    else
        print_log -y "[skip] " "Lambda function not found. Skipping IoT Rule creation."
        IOT_RULE_NAME=""
    fi

    print_log -g "[ok] " "IoT Core setup complete!"
    print_log -m "[IoT Thing] " "${THING_NAME}"
    print_log -m "[IoT Policy] " "${IOT_POLICY_NAME}"
    
    # Generate AWS_KEY.h file with actual certificates and keys
    print_log -c "[generate] " "Generating AWS_KEY.h file with certificates..."
    
    # Get IoT endpoint
    if ! IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text); then
        print_log -r "[error] " "Failed to get IoT endpoint"
        return 1
    fi
    
    # Download Amazon Root CA 1 certificate from official AWS source
    print_log -c "[download] " "Downloading Amazon Root CA 1 certificate..."
    if ! ROOT_CA=$(curl -s "https://www.amazontrust.com/repository/AmazonRootCA1.pem"); then
        print_log -r "[error] " "Failed to download Amazon Root CA certificate"
        return 1
    fi
    
    # Verify Root CA was downloaded properly
    if [ -z "$ROOT_CA" ] || ! echo "$ROOT_CA" | grep -q "BEGIN CERTIFICATE"; then
        print_log -r "[error] " "Invalid Root CA certificate downloaded"
        return 1
    fi
    
    # Read certificate files
    if [ -f "${CERT_DIR}/certificate.pem.crt" ] && [ -f "${CERT_DIR}/private.pem.key" ]; then
        if ! DEVICE_CERT=$(cat "${CERT_DIR}/certificate.pem.crt"); then
            print_log -r "[error] " "Failed to read device certificate"
            return 1
        fi
        
        if ! PRIVATE_KEY=$(cat "${CERT_DIR}/private.pem.key"); then
            print_log -r "[error] " "Failed to read private key"
            return 1
        fi

        # Generate the AWS_KEY.h file
        AWS_KEY_FILE="../src/connection/secret/AWS_KEY.h"
        if ! mkdir -p "$(dirname "$AWS_KEY_FILE")"; then
            print_log -r "[error] " "Failed to create directory for AWS_KEY.h"
            return 1
        fi
        
        if ! cat > "$AWS_KEY_FILE" << HEADER_EOF
#include <pgmspace.h>

#define SECRET
#define THINGNAME "${THING_NAME}"

const char AWS_IOT_ENDPOINT[] = "${IOT_ENDPOINT}";

// Amazon Root CA 1
static const char AWS_CERT_CA[] PROGMEM = R"EOF(
${ROOT_CA})EOF";

// Device Certificate
static const char AWS_CERT_CRT[] PROGMEM = R"KEY(
${DEVICE_CERT})KEY";

// Device Private Key
static const char AWS_CERT_PRIVATE[] PROGMEM = R"KEY(
${PRIVATE_KEY})KEY";
HEADER_EOF
        then
            print_log -r "[error] " "Failed to write AWS_KEY.h file"
            return 1
        fi

        print_log -g "[ok] " "AWS_KEY.h generated at: ${AWS_KEY_FILE}"
        print_log -m "[IoT Endpoint] " "${IOT_ENDPOINT}"
    else
        print_log -r "[error] " "Certificate files not found. Cannot generate AWS_KEY.h"
        return 1
    fi
    
    # Export variables for other components
    export CERT_ARN
    export IOT_POLICY_NAME
    export IOT_RULE_NAME="rule_ingestion_${PROJECT_NAME}"
    
    cleanup_temp_files
}

cleanup_iot() {
    print_log -b "[delete] " "Cleaning up IoT Core..."
    validate_inputs
    setup_aws_environment

    IOT_POLICY_NAME="policy-iot-${PROJECT_NAME}"
    IOT_RULE_NAME="rule_ingestion_${PROJECT_NAME}"
    
    print_log -b "[delete] " "Deleting IoT Core resources..."
    
    # Get certificate ARN if Thing exists
    if aws iot describe-thing --thing-name $THING_NAME > /dev/null 2>&1; then
        CERT_ARN=$(aws iot list-thing-principals --thing-name $THING_NAME --query principals[0] --output text 2>/dev/null)
        if [ "$CERT_ARN" != "None" ] && [ ! -z "$CERT_ARN" ]; then
            CERT_ID=$(basename $CERT_ARN)
            print_log -c "[delete] " "Detaching policy from certificate..."
            aws iot detach-policy --policy-name $IOT_POLICY_NAME --target $CERT_ARN 2>/dev/null || true
            
            print_log -c "[delete] " "Detaching certificate from Thing..."
            aws iot detach-thing-principal --thing-name $THING_NAME --principal $CERT_ARN 2>/dev/null || true
            
            print_log -c "[delete] " "Deactivating and deleting certificate..."
            aws iot update-certificate --certificate-id $CERT_ID --new-status INACTIVE 2>/dev/null || true
            aws iot delete-certificate --certificate-id $CERT_ID --force-delete 2>/dev/null || true
        fi
        
        print_log -c "[delete] " "Deleting IoT Thing..."
        aws iot delete-thing --thing-name $THING_NAME 2>/dev/null || true
    else
        print_log -y "[skip] " "IoT Thing '${THING_NAME}' does not exist."
    fi
    
    # Delete IoT Policy
    print_log -c "[delete] " "Deleting IoT Policy..."
    aws iot delete-policy --policy-name $IOT_POLICY_NAME 2>/dev/null || true
    
    # Delete IoT Rule
    print_log -c "[delete] " "Deleting IoT Rule..."
    aws iot delete-topic-rule --rule-name $IOT_RULE_NAME 2>/dev/null || true
    
    print_log -g "[ok] " "IoT Core resources deleted."
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_iot; then
            print_log -r "[error] " "IoT Core setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_iot; then
            print_log -r "[error] " "IoT Core cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac