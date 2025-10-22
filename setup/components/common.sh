#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Common Utilities and Functions     |--/ /-|#
#|-/ /--| Shared across all AWS components   |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# --- color definitions ---
export NC='\033[0m'
export BLACK='\033[0;30m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[0;37m'

# --- print_log function ---
print_log() {
    local color_map="-b:${BLUE} -g:${GREEN} -r:${RED} -y:${YELLOW} -p:${PURPLE} -c:${CYAN} -m:${PURPLE}"
    local color="${BLUE}"
    local prefix="$1"
    local message="$2"

    if [[ "$1" =~ ^- ]]; then
        for map in $color_map; do
            local flag="${map%%:*}"
            local clr="${map#*:}"
            if [ "$1" == "$flag" ]; then
                color="$clr"
                prefix="$2"
                message="$3"
                break
            fi
        done
    fi

    echo -e "${color}${prefix}${NC}${message}"
}

# --- Common AWS setup ---
setup_aws_environment() {
    export AWS_REGION=$(aws configure get region)
    export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$AWS_REGION" ] || [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
        print_log -r "[error] " "AWS Region or Account ID could not be determined. Please run 'aws configure'."
        print_log -r "[error] " "Current AWS_REGION: '${AWS_REGION}', ACCOUNT_ID: '${ACCOUNT_ID}'"
        exit 1
    fi
    print_log -y "[region] " "${AWS_REGION}"
    print_log -y "[account] " "${ACCOUNT_ID}"
}

# --- AWS Command Error Checking ---
check_aws_command() {
    local command="$1"
    local description="$2"
    
    if ! $command; then
        print_log -r "[error] " "Failed: ${description}"
        print_log -r "[command] " "${command}"
        return 1
    fi
    return 0
}

# --- Validate project name and thing name ---
validate_inputs() {
    if [ -z "$PROJECT_NAME" ]; then
        print_log -r "[error] " "PROJECT_NAME is not set."
        exit 1
    fi
    
    if [ -z "$THING_NAME" ]; then
        print_log -r "[error] " "THING_NAME is not set."
        exit 1
    fi
    
    # Export global certificate directory path
    export CERT_DIR="./certificates/IOT/${THING_NAME}"
}

# --- Clean up temporary files ---
cleanup_temp_files() {
    rm -f query_deployment.zip query.mjs query-permissions.json test_resources.txt
}