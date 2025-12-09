#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| CloudWatch Component               |--/ /-|#
#|-/ /--| Creates alarms and dashboards      |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_cloudwatch() {
    print_log -b "[monitoring] " "Setting up CloudWatch monitoring..."
    validate_inputs
    setup_aws_environment

    # Get SNS topic ARN for alarms
    if [ -z "$SNS_TOPIC_ARN" ]; then
        SNS_TOPIC_NAME="${PROJECT_NAME}-high-temp-alerts"
        SNS_TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" --output text)
        if [ -z "$SNS_TOPIC_ARN" ] || [ "$SNS_TOPIC_ARN" = "None" ]; then
            print_log -r "[error] " "SNS topic not found. Please ensure SNS setup completed successfully."
            return 1
        fi
    fi

    # Get Lambda function names
    LAMBDA_FUNCTION_NAME="func-ingestion-${PROJECT_NAME}"
    QUERY_LAMBDA_NAME="func-query-${PROJECT_NAME}"

    # Create CloudWatch alarms for Lambda functions
    print_log -c "[alarm] " "Creating Lambda error rate alarms..."
    
    # Ingestion Lambda error alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-ingestion-errors" \
        --alarm-description "High error rate in ingestion Lambda" \
        --metric-name Errors \
        --namespace AWS/Lambda \
        --statistic Sum \
        --period 300 \
        --threshold 5 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 2 \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --dimensions Name=FunctionName,Value="$LAMBDA_FUNCTION_NAME" > /dev/null 2>&1 || true

    # Query Lambda error alarm  
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-query-errors" \
        --alarm-description "High error rate in query Lambda" \
        --metric-name Errors \
        --namespace AWS/Lambda \
        --statistic Sum \
        --period 300 \
        --threshold 3 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 2 \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --dimensions Name=FunctionName,Value="$QUERY_LAMBDA_NAME" > /dev/null 2>&1 || true

    # Create custom metric alarm for high maintenance scores
    print_log -c "[alarm] " "Creating maintenance score alarm..."
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-high-maintenance-score" \
        --alarm-description "Machine requires immediate maintenance" \
        --metric-name MaintenanceScore \
        --namespace "IoT/PredictiveMaintenance" \
        --statistic Average \
        --period 300 \
        --threshold 80 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 1 \
        --alarm-actions "$SNS_TOPIC_ARN" > /dev/null 2>&1 || true
    
    # Create API usage anomaly alarm
    print_log -c "[alarm] " "Creating API usage anomaly alarm..."
    aws cloudwatch put-metric-alarm \
        --alarm-name "${PROJECT_NAME}-api-usage-anomaly" \
        --alarm-description "Unusual API request volume detected" \
        --metric-name Count \
        --namespace AWS/ApiGateway \
        --statistic Sum \
        --period 300 \
        --threshold 100 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 2 \
        --alarm-actions "$SNS_TOPIC_ARN" > /dev/null 2>&1 || true

    # Create CloudWatch dashboard
    print_log -c "[dashboard] " "Creating CloudWatch dashboard..."
    
    cat > dashboard.json << DASH_EOF
{
    "widgets": [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/Lambda", "Invocations", "FunctionName", "${LAMBDA_FUNCTION_NAME}" ],
                    [ ".", "Errors", ".", "." ],
                    [ ".", "Duration", ".", "." ]
                ],
                "period": 300,
                "stat": "Sum",
                "region": "${AWS_REGION}",
                "title": "Lambda Ingestion Metrics"
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "IoT/PredictiveMaintenance", "MaintenanceScore" ],
                    [ ".", "VibrationMagnitude" ],
                    [ ".", "Temperature" ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "${AWS_REGION}",
                "title": "Sensor Metrics"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 6,
            "width": 24,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "${PROJECT_NAME}-sensor-readings" ],
                    [ ".", "ConsumedWriteCapacityUnits", ".", "." ]
                ],
                "period": 300,
                "stat": "Sum",
                "region": "${AWS_REGION}",
                "title": "DynamoDB Usage"
            }
        }
    ]
}
DASH_EOF

    DASHBOARD_NAME="${PROJECT_NAME}-iot-monitoring"
    if aws cloudwatch put-dashboard \
        --dashboard-name "$DASHBOARD_NAME" \
        --dashboard-body file://dashboard.json > /dev/null 2>&1; then
        print_log -g "[ok] " "CloudWatch dashboard created: ${DASHBOARD_NAME}"
    else
        print_log -y "[warn] " "Dashboard creation may have failed"
    fi

    print_log -g "[ok] " "CloudWatch monitoring setup complete!"
    print_log -m "[Dashboard] " "https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
    
    # Export variables
    export DASHBOARD_NAME
    
    cleanup_temp_files
}

cleanup_cloudwatch() {
    print_log -b "[delete] " "Cleaning up CloudWatch resources..."
    validate_inputs
    setup_aws_environment

    DASHBOARD_NAME="${PROJECT_NAME}-iot-monitoring"
    
    # Delete alarms
    print_log -c "[delete] " "Deleting CloudWatch alarms..."
    aws cloudwatch delete-alarms --alarm-names \
        "${PROJECT_NAME}-ingestion-errors" \
        "${PROJECT_NAME}-query-errors" \
        "${PROJECT_NAME}-high-maintenance-score" \
        "${PROJECT_NAME}-api-usage-anomaly" 2>/dev/null || true
    
    # Delete dashboard
    print_log -c "[delete] " "Deleting CloudWatch dashboard..."
    aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME" 2>/dev/null || true
    
    print_log -g "[ok] " "CloudWatch cleanup completed."
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_cloudwatch; then
            print_log -r "[error] " "CloudWatch setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_cloudwatch; then
            print_log -r "[error] " "CloudWatch cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac