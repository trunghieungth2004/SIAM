---
title: "Week 3 Worklog"
date: 2025-09-22
draft: false
weight: 3
---

# Week 3 Worklog

### Week 3 Objectives:
- Learn Infrastructure as Code (IaC) principles and shell scripting
- Design and implement automated AWS infrastructure deployment scripts
- Set up cloud foundation: S3, DynamoDB, SNS, SQS
- Understand AWS service discovery patterns and resource management
- Learn VPC fundamentals and networking concepts

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn shell scripting best practices <br> - Study AWS CLI for automation <br> - Understand Infrastructure as Code concepts <br> - Review AWS resource tagging strategies <br> - Plan modular script structure | 22/09/2025 | 22/09/2025 | [AWS CLI Command Reference](https://awscli.amazonaws.com/v2/documentation/api/latest/index.html) |
| 2 | - Design AWS.sh orchestration script: <br>  + Component selection menu <br>  + Dependency ordering <br>  + Error handling <br> - Create common.sh utility functions <br> - Implement logging and color output | 23/09/2025 | 23/09/2025 | Bash scripting guides |
| 3 | - Implement S3 component script: <br>  + Create data lake bucket <br>  + Create frontend hosting bucket <br>  + Configure static website hosting <br>  + Set up bucket policies <br> - Test S3 setup and cleanup | 24/09/2025 | 24/09/2025 | [AWS S3 Documentation](https://docs.aws.amazon.com/s3/) |
| 4 | - Implement DynamoDB component script: <br>  + Create sensor data table <br>  + Configure partition and sort keys <br>  + Set up on-demand billing <br> - Learn about DynamoDB best practices <br> - Test table creation and deletion | 25/09/2025 | 25/09/2025 | [AWS DynamoDB Documentation](https://docs.aws.amazon.com/dynamodb/) |
| 5 | - Implement SNS and SQS component scripts: <br>  + Create SNS topics for alerts <br>  + Create SQS queues for message buffering <br>  + Configure dead-letter queues <br> - Learn about pub/sub messaging patterns | 26/09/2025 | 26/09/2025 | [AWS SNS](https://docs.aws.amazon.com/sns/) <br> [AWS SQS](https://docs.aws.amazon.com/sqs/) |
| 6 | - Learn VPC fundamentals: <br>  + Subnets (public/private) <br>  + Route tables <br>  + Internet Gateway <br>  + NAT Gateway <br>  + Security Groups vs NACLs <br> - Understand VPC endpoints | 27/09/2025 | 28/09/2025 | [AWS VPC Documentation](https://docs.aws.amazon.com/vpc/) <br> FCJ VPC workshops |

### Week 3 Achievements:

- **Infrastructure as Code (IaC) Mastery:**
  - Learned IaC principles and benefits (repeatability, version control, disaster recovery)
  - Mastered bash scripting for AWS automation
  - Understood the importance of idempotent operations
  - Learned AWS CLI JSON output parsing with `jq`
  - Studied resource tagging strategies for cost allocation and management

- **AWS.sh Orchestration Framework:**
  - Designed and implemented main orchestration script `AWS.sh`
  - Created modular component-based architecture:
    - S3, DynamoDB, SNS, SQS, Lambda, API Gateway
    - SageMaker, Greengrass, CloudWatch, EventBridge
  - Implemented interactive component selection menu:
    - Individual selection (e.g., "1 2 3")
    - Range selection (e.g., "1-5")
    - Exclusion selection (e.g., "^4")
    - Default "all" option
  - Built dependency-aware deployment ordering:
    - Setup: S3 → DynamoDB → SNS → SQS → Lambda → API Gateway → SageMaker → Greengrass → CloudWatch → EventBridge
    - Cleanup: Reverse order to prevent dependency failures
  - Added comprehensive error handling and exit on failure
  - Implemented execution time tracking (minutes and seconds)

- **common.sh Utility Library:**
  - Created shared utility functions for all component scripts
  - Implemented color-coded logging system:
    - `print_log -g` - Green for success
    - `print_log -r` - Red for errors
    - `print_log -y` - Yellow for warnings
    - `print_log -b` - Blue for info
    - `print_log -m` - Magenta for highlights
    - `print_log -c` - Cyan for headers
  - Added input validation functions
  - Created AWS CLI error checking wrappers

- **S3 Component Implementation (S3.sh):**
  - Created automated S3 bucket provisioning script
  - Implemented data lake bucket with versioning:
    - Bucket name: `${PROJECT_NAME}-siam-data-lake`
    - Lifecycle policies for data retention
    - Server-side encryption enabled
  - Configured frontend hosting bucket:
    - Bucket name: `${PROJECT_NAME}-siam-frontend`
    - Static website hosting enabled
    - Public read access via bucket policy
    - Automatic upload of web application files (HTML, CSS, JS)
  - Deployed Swagger UI for API documentation
  - Implemented S3 cleanup with forced empty-and-delete logic
  - Added error handling for existing buckets

- **DynamoDB Component Implementation (DynamoDB.sh):**
  - Created automated DynamoDB table provisioning
  - Configured sensor data table schema:
    - Table name: `${PROJECT_NAME}-SensorData`
    - Partition key: `device_id` (String)
    - Sort key: `timestamp` (Number)
    - On-demand billing mode for cost optimization
    - Point-in-time recovery enabled
  - Implemented table existence checking
  - Added cleanup script for table deletion
  - Configured CloudWatch metrics integration

- **SNS Component Implementation (SNS.sh):**
  - Created SNS topics for system notifications:
    - `${PROJECT_NAME}-siam-alerts` - Anomaly detection alerts
    - `${PROJECT_NAME}-siam-system-events` - System events
  - Configured email subscriptions for alerts
  - Implemented SNS publish permissions for Lambda
  - Added topic deletion in cleanup script

- **SQS Component Implementation (SQS.sh):**
  - Created SQS queues for message buffering:
    - `${PROJECT_NAME}-siam-sensor-queue` - Main queue
    - `${PROJECT_NAME}-siam-dlq` - Dead-letter queue
  - Configured dead-letter queue (DLQ) for failed messages:
    - Max receive count: 3
    - Message retention: 14 days
  - Set visibility timeout: 300 seconds
  - Added queue purge and deletion in cleanup

- **VPC Networking Fundamentals:**
  - Learned VPC architecture and CIDR notation
  - Understood public vs. private subnet design:
    - Public subnets: Internet-facing resources (NAT Instance, ALB)
    - Private subnets: Backend resources (EC2, RDS)
  - Mastered route table configuration:
    - Public route: 0.0.0.0/0 → Internet Gateway
    - Private route: 0.0.0.0/0 → NAT Instance (t3.nano for cost optimization)
  - Learned Security Groups (stateful firewall):
    - Inbound/outbound rules
    - Protocol, port, source/destination
  - Studied Network ACLs (stateless firewall)
  - Understood VPC endpoints:
    - Gateway endpoints (S3, DynamoDB)
    - Interface endpoints (other AWS services)

- **VPC.sh Component Skeleton:**
  - Created VPC component script structure (for future EC2 use)
  - Planned VPC configuration:
    - CIDR: 10.0.0.0/16
    - Public subnet: 10.0.1.0/24
    - Private subnet: 10.0.2.0/24
  - Designed security group for future EC2 instances

- **Script Testing and Validation:**
  - Tested full setup workflow: `./AWS.sh setup`
  - Validated all component scripts individually
  - Tested cleanup workflow: `./AWS.sh cleanup`
  - Verified idempotency (running setup twice doesn't fail)
  - Confirmed proper error handling and rollback

- **AWS Service Discovery Pattern:**
  - Implemented resource lookup without hardcoded ARNs
  - Used AWS CLI queries to discover resources dynamically:
    - `aws s3api list-buckets --query "Buckets[?contains(Name, 'siam')]"`
    - `aws dynamodb list-tables`
    - `aws sns list-topics`
  - Benefits: No resource files, self-documenting, resilient

### Sample AWS.sh Execution Output:

```bash
$ ./AWS.sh setup
Enter a project name (e.g., 'myiotapp'): siam-demo
Enter a name for your IoT device (Thing Name): RaspberryPi_5_Core

AWS Infrastructure Components
:: Choose which components to setup:

 1  S3              [Cloud] S3 Buckets for data storage and web hosting
 2  DynamoDB        [Cloud] DynamoDB tables for sensor data
 3  SNS             [Cloud] SNS topics for notifications
 4  SQS             [Cloud] SQS queues for message handling
 5  APIGateway      [Cloud] REST API for data queries and dashboard
 6  Lambda          [Cloud] Lambda functions and IAM roles
 7  SageMaker       [Cloud] ML model training for predictive maintenance
 8  Greengrass      [Cloud] IoT Greengrass Core for edge computing
 9  CloudWatch      [Cloud] Monitoring, alarms, and dashboards
10  EventBridge     [Cloud] Automated ML pipeline and edge deployment
==> Components to setup: (eg: "1 2 3", "1-3", "^4" to exclude, or "all")
 -> setup all components by default if no selection made
==> 1 2 3 4

[setup] Setting up S3...
[ok] S3 setup completed successfully.
[setup] Setting up DynamoDB...
[ok] DynamoDB setup completed successfully.
[setup] Setting up SNS...
[ok] SNS setup completed successfully.
[setup] Setting up SQS...
[ok] SQS setup completed successfully.

--------------------------------------
  AWS INFRASTRUCTURE SETUP COMPLETE
--------------------------------------

[Project Name] siam-demo
[Thing Name] RaspberryPi_5_Core
[Duration] 2m 34s
[Web Dashboard] http://siam-demo-frontend.s3-website-us-east-1.amazonaws.com
```

### Challenges Encountered:

- **Bucket Naming Conflicts:** S3 bucket names must be globally unique - solved by using project name prefix
- **Script Permissions:** Initial permission errors - fixed with `chmod +x` on all component scripts
- **AWS CLI Output Parsing:** Complex JSON filtering - learned `jq` and `--query` parameter
- **Cleanup Dependencies:** S3 buckets must be empty before deletion - implemented forced empty logic

### Key Learnings:

- Automation saves time and reduces human error
- Modular script design improves maintainability
- Proper error handling is critical for production scripts
- AWS service discovery eliminates hardcoded values
- Infrastructure as Code enables rapid environment recreation

### Next Week Preview:

In Week 4, I will dive deeper into EC2 and VPC networking, set up the Raspberry Pi 5 hardware, install Raspberry Pi OS, and provision AWS IoT Greengrass Core software on the device. This will prepare the edge device for local data collection.
