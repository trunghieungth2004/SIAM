#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Local Data Collection Component    |--/ /-|#
#|-/ /--| Sets up systemd service on Pi      |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

run_local_collection() {
    print_log -c "Local Data Collection Setup"
    echo ""
    
    # Get Pi SSH target
    read -p "Enter the SSH target for your Raspberry Pi (e.g., pi@192.168.1.100): " PI_SSH_TARGET
    if [ -z "$PI_SSH_TARGET" ] || [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
        print_log -r "[error] " "Invalid SSH target format. It must be in the format 'user@host'."
        return 1
    fi
    
    # Get collection duration
    read -p "Enter the number of days to collect data (e.g., 3): " COLLECTION_DAYS
    if ! [[ "$COLLECTION_DAYS" =~ ^[0-9]+$ ]] || [ "$COLLECTION_DAYS" -lt 1 ]; then
        print_log -r "[error] " "Invalid number of days. Must be a positive integer."
        return 1
    fi
    
    print_log -g "[pi] " "SSH Target: ${PI_SSH_TARGET}"
    print_log -g "[duration] " "Collection Duration: ${COLLECTION_DAYS} days"
    echo ""
    
    # Calculate stop time
    local stop_timestamp=$(date -d "+${COLLECTION_DAYS} days" +%s)
    
    print_log -b "[step 1/5] " "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=10 "${PI_SSH_TARGET}" "echo 'Connection successful'" > /dev/null 2>&1; then
        print_log -r "[error] " "Cannot connect to ${PI_SSH_TARGET}. Please check SSH access."
        return 1
    fi
    print_log -g "[ok] " "SSH connection successful."
    
    print_log -b "[step 2/5] " "Copying datalogger to Pi..."
    local datalogger_src="${SCRIPT_DIR}/Local/local_datalogger.c"
    
    if [ ! -f "$datalogger_src" ]; then
        print_log -r "[error] " "Datalogger source not found at: ${datalogger_src}"
        return 1
    fi
    
    # Create remote directory and copy file
    ssh "${PI_SSH_TARGET}" "mkdir -p ~/local_datalogger" || {
        print_log -r "[error] " "Failed to create directory on Pi."
        return 1
    }
    
    scp "${datalogger_src}" "${PI_SSH_TARGET}:~/local_datalogger/local_datalogger.c" || {
        print_log -r "[error] " "Failed to copy datalogger to Pi."
        return 1
    }
    print_log -g "[ok] " "Datalogger copied successfully."
    
    print_log -b "[step 3/5] " "Compiling datalogger on Pi..."
    ssh "${PI_SSH_TARGET}" "cd ~/local_datalogger && gcc -o datalogger local_datalogger.c -lm" || {
        print_log -r "[error] " "Failed to compile datalogger. Ensure gcc is installed."
        return 1
    }
    print_log -g "[ok] " "Datalogger compiled successfully."
    
    print_log -b "[step 4/5] " "Creating systemd service..."
    
    # Get the username for paths
    local remote_user=$(ssh "${PI_SSH_TARGET}" "whoami")
    
    # Create wrapper script that auto-stops after collection duration
    local wrapper_content="#!/usr/bin/env bash
LOG_FILE=\"/home/${remote_user}/local_datalogger/sensor_log_\$(date +%Y%m%d_%H%M%S).csv\"
STOP_TIME=${stop_timestamp}

# Run datalogger in background: tee to both file and stdout (stdout goes to journal)
/home/${remote_user}/local_datalogger/datalogger | tee -a \"\${LOG_FILE}\" &
DATALOGGER_PID=\$!

# Wait for duration or until datalogger exits
while kill -0 \${DATALOGGER_PID} 2>/dev/null; do
    if [ \$(date +%s) -ge \${STOP_TIME} ]; then
        echo \"Collection duration reached. Stopping datalogger...\"
        kill \${DATALOGGER_PID}
        sudo systemctl stop local-datalogger.service
        break
    fi
    sleep 60
done

wait \${DATALOGGER_PID}"
    
    # Create systemd service file content
    local service_content="[Unit]
Description=Local Data Logger
After=network.target

[Service]
Type=simple
User=${remote_user}
Group=${remote_user}
WorkingDirectory=/home/${remote_user}/local_datalogger
ExecStart=/home/${remote_user}/local_datalogger/start_logger.sh
Restart=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target"
    
    # Write service file and wrapper script
    echo "$wrapper_content" | ssh "${PI_SSH_TARGET}" "cat > ~/local_datalogger/start_logger.sh && chmod +x ~/local_datalogger/start_logger.sh"
    echo "$service_content" | ssh "${PI_SSH_TARGET}" "cat > ~/local_datalogger/local-datalogger.service"
    
    # Install service
    ssh "${PI_SSH_TARGET}" "
        sudo cp ~/local_datalogger/local-datalogger.service /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable local-datalogger.service
        sudo systemctl start local-datalogger.service
    " || {
        print_log -r "[error] " "Failed to install and start systemd service."
        return 1
    }
    
    print_log -g "[ok] " "Systemd service created and started."
    
    print_log -b "[step 5/5] " "Verifying service status..."
    sleep 2
    ssh "${PI_SSH_TARGET}" "sudo systemctl status local-datalogger.service --no-pager" || true
    
    echo ""
    print_log -g "--------------------------------------"
    print_log -g "  LOCAL DATA COLLECTION SETUP COMPLETE"
    print_log -g "--------------------------------------"
    echo ""
    print_log -m "[SSH Target] " "${PI_SSH_TARGET}"
    print_log -m "[Duration] " "${COLLECTION_DAYS} days"
    print_log -m "[Stop Time] " "$(date -d @${stop_timestamp})"
    echo ""
    print_log -c "Data will be saved to: ~/local_datalogger/sensor_log_*.csv"
    print_log -c "To view realtime sensor data: ssh ${PI_SSH_TARGET} 'sudo journalctl -u local-datalogger -f'"
    print_log -c "To view CSV file: ssh ${PI_SSH_TARGET} 'tail -f ~/local_datalogger/sensor_log_*.csv'"
    print_log -c "To stop early: ssh ${PI_SSH_TARGET} 'sudo systemctl stop local-datalogger'"
    echo ""
}

run_local_cleanup() {
    print_log -c "Local Data Collection Cleanup"
    echo ""
    
    # Get Pi SSH target
    read -p "Enter the SSH target for your Raspberry Pi (e.g., pi@192.168.1.100): " PI_SSH_TARGET
    if [ -z "$PI_SSH_TARGET" ] || [[ ! "$PI_SSH_TARGET" =~ "@" ]]; then
        print_log -r "[error] " "Invalid SSH target format. It must be in the format 'user@host'."
        return 1
    fi
    
    print_log -g "[pi] " "SSH Target: ${PI_SSH_TARGET}"
    echo ""
    
    print_log -r "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_log -r "  WARNING: THIS WILL STOP THE DATALOGGER AND REMOVE THE SERVICE"
    print_log -r "           Data logs will be preserved in ~/local_datalogger/"
    print_log -r "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    read -r -p "Are you sure you want to continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            print_log -g "[info] " "Cleanup cancelled by user."
            return 0
            ;;
    esac
    
    print_log -b "[step 1/4] " "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=10 "${PI_SSH_TARGET}" "echo 'Connection successful'" > /dev/null 2>&1; then
        print_log -r "[error] " "Cannot connect to ${PI_SSH_TARGET}. Please check SSH access."
        return 1
    fi
    print_log -g "[ok] " "SSH connection successful."
    
    print_log -b "[step 2/5] " "Stopping datalogger service..."
    ssh "${PI_SSH_TARGET}" "sudo systemctl stop local-datalogger.service 2>/dev/null || true"
    print_log -g "[ok] " "Service stopped."
    
    print_log -b "[step 3/5] " "Disabling and removing service..."
    ssh "${PI_SSH_TARGET}" "
        sudo systemctl disable local-datalogger.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/local-datalogger.service
        sudo systemctl daemon-reload
    "
    print_log -g "[ok] " "Service removed."
    
    print_log -b "[step 4/5] " "Cleaning up datalogger files..."
    echo ""
    print_log -y "[info] " "Do you want to delete the entire datalogger directory? (includes logs)"
    read -r -p "Delete all datalogger files? [y/N] " delete_files
    case "$delete_files" in
        [yY][eE][sS]|[yY])
            ssh "${PI_SSH_TARGET}" "
                rm -rf ~/local_datalogger
            "
            print_log -g "[ok] " "All datalogger files removed."
            ;;
        *)
            print_log -g "[ok] " "Datalogger files preserved."
            ;;
    esac
    
    echo ""
    print_log -g "--------------------------------------"
    print_log -g "  LOCAL DATA COLLECTION CLEANUP COMPLETE"
    print_log -g "--------------------------------------"
    echo ""
    
    # Ask if user wants to download logs first
    print_log -y "[info] " "Logs may still be available at: ${PI_SSH_TARGET}:~/local_datalogger/ (if not deleted)"
    echo ""
    
    # Ask if user wants to download logs
    read -r -p "Do you want to download the logs now? [y/N] " download_logs
    case "$download_logs" in
        [yY][eE][sS]|[yY])
            local download_dir="./local_datalogger_logs_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$download_dir"
            print_log -b "[download] " "Downloading logs to ${download_dir}..."
            scp "${PI_SSH_TARGET}:~/local_datalogger/sensor_log_*.csv" "$download_dir/" 2>/dev/null || {
                print_log -r "[error] " "No log files found or download failed."
                rmdir "$download_dir" 2>/dev/null
                return 0
            }
            print_log -g "[ok] " "Logs downloaded to ${download_dir}/"
            ;;
        *)
            print_log -g "[info] " "Logs not downloaded."
            ;;
    esac
    
    echo ""
}
