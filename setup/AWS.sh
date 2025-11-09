#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| AWS Infrastructure Management Script|--/ /-|#
#|-/ /--| Deploys or Cleans up the IoT stack  |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/components/common.sh"

# Components directory
COMPONENTS_DIR="$(dirname "$0")/components"

# Available components
declare -A COMPONENTS=(
    ["1"]="VPC"
    ["2"]="S3" 
    ["3"]="DynamoDB"
    ["4"]="SNS"
    ["5"]="SQS"
    ["6"]="Secrets"
    ["7"]="Lambda"
    ["8"]="SageMaker"
    ["9"]="Greengrass"
    ["10"]="IoT"
    ["11"]="CloudWatch"
    ["12"]="EventBridge"
)

# Component descriptions
declare -A DESCRIPTIONS=(
    ["VPC"]="VPC, Subnets, Gateways, and Endpoints"
    ["S3"]="S3 Buckets for data storage and web hosting"
    ["DynamoDB"]="DynamoDB tables for sensor data"
    ["SNS"]="SNS topics for notifications"
    ["SQS"]="SQS queues for message handling"
    ["Secrets"]="Secrets Manager for secure key storage"
    ["Lambda"]="Lambda functions and IAM roles"
    ["IoT"]="IoT Core - Things, certificates, and rules"
    ["Greengrass"]="IoT Greengrass Core for edge computing"
    ["SageMaker"]="ML model training for predictive maintenance"
    ["CloudWatch"]="Monitoring, alarms, and dashboards"
    ["EventBridge"]="Automated ML pipeline and edge deployment"
)

show_component_menu() {
    echo ""
    print_log -c "AWS Infrastructure Components"
    echo ":: Choose which components to $1:"
    echo ""
    
    for i in {1..12}; do
        local component="${COMPONENTS[$i]}"
        local desc="${DESCRIPTIONS[$component]}"
        printf "%2s  %-12s %s\n" "$i" "$component" "$desc"
    done
    
    echo ""
    echo "==> Components to $1: (eg: \"1 2 3\", \"1-3\", \"^4\" to exclude, or \"all\")"
    echo " -> $1 all components by default if no selection made"
    echo -n "==> "
}

parse_selection() {
    local selection="$1"
    local selected_components=()
    
    if [ -z "$selection" ] || [ "$selection" = "all" ]; then
        # Default: all components
        for i in {1..12}; do
            selected_components+=("${COMPONENTS[$i]}")
        done
    else
        # Parse selection
        local exclude_mode=false
        if [[ "$selection" =~ ^\^ ]]; then
            exclude_mode=true
            selection="${selection#^}"
            # Start with all components for exclusion
            for i in {1..12}; do
                selected_components+=("${COMPONENTS[$i]}")
            done
        fi
        
        # Handle ranges and individual numbers
        for part in $selection; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                # Range selection
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"
                for ((i=start; i<=end; i++)); do
                    if [ "$exclude_mode" = true ]; then
                        # Remove from selected_components
                        selected_components=("${selected_components[@]/${COMPONENTS[$i]}/}")
                    else
                        if [[ -v COMPONENTS[$i] ]]; then
                            selected_components+=("${COMPONENTS[$i]}")
                        fi
                    fi
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                # Individual number
                if [ "$exclude_mode" = true ]; then
                    # Remove from selected_components
                    selected_components=("${selected_components[@]/${COMPONENTS[$part]}/}")
                else
                    if [[ -v COMPONENTS[$part] ]]; then
                        selected_components+=("${COMPONENTS[$part]}")
                    fi
                fi
            fi
        done
    fi
    
    # Remove empty elements and duplicates
    selected_components=($(printf '%s\n' "${selected_components[@]}" | grep -v '^$' | sort -u))
    echo "${selected_components[@]}"
}

run_component() {
    local component="$1"
    local action="$2"
    local script_path="${COMPONENTS_DIR}/${component}.sh"
    
    if [ ! -f "$script_path" ]; then
        print_log -r "[error] " "Component script not found: $script_path"
        return 1
    fi
    
    print_log -b "[${action}] " "Running ${component} ${action}..."
    
    chmod +x "$script_path"
    
    export PROJECT_NAME THING_NAME PI_SSH_TARGET
    
    if "$script_path" "$action"; then
        print_log -g "[ok] " "${component} ${action} completed successfully."
        return 0
    else
        local exit_code=$?
        print_log -r "[error] " "${component} ${action} failed with exit code: $exit_code"
        return $exit_code
    fi
}

get_project_inputs() {
    print_log -c "Project Configuration"
    read -p "Enter a project name (e.g., 'myiotapp'): " PROJECT_NAME
    if [ -z "$PROJECT_NAME" ]; then
        print_log -r "[error] " "Project name cannot be empty."
        exit 1
    fi

    read -p "Enter a name for your IoT device (Thing Name): " THING_NAME
    if [ -z "$THING_NAME" ]; then
        print_log -r "[error] " "Thing Name cannot be empty."
    fi
    
    print_log -g "[project] " "Using project name: ${PROJECT_NAME}"
    print_log -g "[device] " "Using Thing Name: ${THING_NAME}"
    
    export PROJECT_NAME THING_NAME
}
run_setup() {
    set -e # Exit immediately if a command exits with a non-zero status.
    
    # Get project inputs
    get_project_inputs
    
    # Show component selection menu
    show_component_menu "setup"
    read -r selection
    
    # Parse selection
    selected_components=($(parse_selection "$selection"))
    
    # Prompt for PI SSH target if Greengrass is selected
    if [[ " ${selected_components[*]} " =~ " Greengrass " ]]; then
        read -p "Enter the SSH target for your Raspberry Pi (e.g., user@host): " PI_SSH_TARGET
        if [ -z "$PI_SSH_TARGET" ] || [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
            print_log -r "[error] " "Invalid SSH target format. It must be in the format 'user@host'."
            exit 1
        fi
        print_log -g "[pi] " "Using PI SSH target: ${PI_SSH_TARGET}"
    fi
    
    if [ ${#selected_components[@]} -eq 0 ]; then
        print_log -r "[error] " "No valid components selected."
        exit 1
    fi
    
    print_log -b "[info] " "Setting up components: ${selected_components[*]}"
    echo ""
    
    # Set flags for component dependencies
    if [[ " ${selected_components[*]} " =~ " SageMaker " ]]; then
        export ENABLE_SAGEMAKER="true"
    fi
    
    # Run components in dependency order
    local setup_order=("VPC" "S3" "DynamoDB" "SNS" "SQS" "Secrets" "Lambda" "SageMaker" "Greengrass" "IoT" "CloudWatch" "EventBridge")
    
    for component in "${setup_order[@]}"; do
        if [[ " ${selected_components[*]} " =~ " ${component} " ]]; then
            print_log -b "[setup] " "Setting up ${component}..."
            if ! run_component "$component" "setup"; then
                print_log -r "[FATAL] " "Failed to setup ${component}. Stopping setup to prevent cascading failures."
                print_log -r "[error] " "Setup aborted. Please fix the ${component} issues and try again."
                exit 1
            fi
            print_log -g "[ok] " "${component} setup completed successfully."
        fi
    done
    
    echo ""
    print_log -g "--------------------------------------"
    print_log -g "  AWS INFRASTRUCTURE SETUP COMPLETE   "
    print_log -g "--------------------------------------"
    echo ""
    print_log -m "[Project Name] " "${PROJECT_NAME}"
    print_log -m "[Thing Name] " "${THING_NAME}"
}

run_cleanup() {
    set +e # Continue on error

    # Get project inputs
    get_project_inputs
    
    echo ""
    print_log -r "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_log -r "  WARNING: THIS WILL PERMANENTLY DELETE ALL AWS RESOURCES"
    print_log -r "           ASSOCIATED WITH PROJECT: ${PROJECT_NAME}"
    print_log -r "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    read -r -p "Are you absolutely sure you want to continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            print_log -g "[info] " "Cleanup cancelled by user."
            exit 0
            ;;
    esac
    
    # Show component selection menu
    show_component_menu "cleanup"
    read -r selection
    
    # Parse selection
    selected_components=($(parse_selection "$selection"))
    
    # Prompt for PI SSH target if Greengrass is selected
    if [[ " ${selected_components[*]} " =~ " Greengrass " ]]; then
        read -p "Enter the SSH target for your Raspberry Pi (e.g., user@host): " PI_SSH_TARGET
        if [ -z "$PI_SSH_TARGET" ] || [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
            print_log -r "[error] " "Invalid SSH target format. It must be in the format 'user@host'."
            exit 1
        fi
        print_log -g "[pi] " "Using PI SSH target: ${PI_SSH_TARGET}"
    fi
    
    if [ ${#selected_components[@]} -eq 0 ]; then
        print_log -r "[error] " "No valid components selected."
        exit 1
    fi
    
    print_log -b "[info] " "Cleaning up components: ${selected_components[*]}"
    echo ""
    
    # Run cleanup in reverse dependency order
    local cleanup_order=("EventBridge" "CloudWatch" "IoT" "Greengrass" "SageMaker" "Lambda" "Secrets" "SQS" "SNS" "DynamoDB" "S3" "VPC")
    local failed_components=()
    
    for component in "${cleanup_order[@]}"; do
        if [[ " ${selected_components[*]} " =~ " ${component} " ]]; then
            if ! run_component "$component" "cleanup"; then
                failed_components+=("$component")
                print_log -r "[error] " "Failed to cleanup $component"
            fi
        fi
    done
    
    echo ""
    if [ ${#failed_components[@]} -eq 0 ]; then
        print_log -g "--------------------------------------"
        print_log -g "  AWS INFRASTRUCTURE CLEANUP COMPLETE "
        print_log -g "--------------------------------------"
    else
        print_log -r "--------------------------------------"
        print_log -r "  CLEANUP COMPLETED WITH ERRORS       "
        print_log -r "--------------------------------------"
        echo ""
        print_log -r "[Failed Components] " "${failed_components[*]}"
    fi
}
#--------------------------------#
# Main Execution Logic           #
#--------------------------------#
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  setup      : Deploys AWS IoT backend components (interactive selection)."
    echo "  cleanup    : Deletes AWS resources (interactive selection)."
    echo ""
    echo "Example component selection:"
    echo "  1 2 3      : Setup/cleanup components 1, 2, and 3"
    echo "  1-5        : Setup/cleanup components 1 through 5"
    echo "  ^4         : Setup/cleanup all components except 4"
    echo "  all        : Setup/cleanup all components (default)"
    echo ""
}

# Make components executable
chmod +x "${COMPONENTS_DIR}"/*.sh

# Check if a command was provided
if [ -z "$1" ]; then
    usage
    exit 1
fi

# Route to the correct function based on the command
case "$1" in
    setup)
        run_setup
        ;;
    cleanup)
        run_cleanup
        ;;
    *)
        print_log -r "[error] " "Invalid command: $1"
        usage
        exit 1
        ;;
esac