---
title: "Week 1 Worklog"
date: 2025-09-08
draft: false
weight: 1
---

### Week 1 Objectives:
- Connect and get acquainted with members and mentors of AWS First Cloud Journey (FCJ).
- Understand the internship structure, rules, and expectations.
- Learn foundational AWS concepts and service categories.
- Set up AWS account and become familiar with the AWS Console and CLI.

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Get acquainted with FCJ admins, mentors, and fellow interns <br> - Read and take note of internship unit rules and regulations <br> - Understand FCJ program structure and expectations <br> - Set up communication channels (Slack, email) | 08/09/2025 | 08/09/2025 | Internal FCJ documentation |
| 2 | - Learn about AWS Cloud Computing fundamentals <br> - Study AWS service categories: <br>  + Compute (EC2, Lambda) <br>  + Storage (S3, EBS) <br>  + Networking (VPC, Route53) <br>  + Database (DynamoDB, RDS) <br>  + IoT (IoT Core, Greengrass) <br>  + Machine Learning (SageMaker) | 09/09/2025 | 09/09/2025 | [https://cloudjourney.awsstudygroup.com/](https://cloudjourney.awsstudygroup.com/) |
| 3 | - Create AWS Free Tier account <br> - Learn about AWS Management Console navigation <br> - Learn about AWS CLI basics <br> - **Practice:** <br>  + Set up AWS account with MFA <br>  + Install AWS CLI on local machine <br>  + Configure AWS CLI with access keys | 10/09/2025 | 10/09/2025 | [https://cloudjourney.awsstudygroup.com/](https://cloudjourney.awsstudygroup.com/) <br> [AWS CLI Installation Guide](https://docs.aws.amazon.com/cli/) |
| 4 | - Deep dive into EC2 fundamentals: <br>  + Instance types and families <br>  + Amazon Machine Images (AMI) <br>  + Elastic Block Store (EBS) <br>  + Security Groups <br> - Learn SSH connection methods <br> - Study Elastic IP addressing | 11/09/2025 | 11/09/2025 | [https://cloudjourney.awsstudygroup.com/](https://cloudjourney.awsstudygroup.com/) |
| 5 | - **Hands-on Practice:** <br>  + Launch first EC2 instance (Amazon Linux 2) <br>  + Create and configure key pairs <br>  + Connect to EC2 via SSH <br>  + Create and attach EBS volume <br>  + Configure Security Groups <br> - Document learnings and challenges | 12/09/2025 | 13/09/2025 | [AWS EC2 Documentation](https://docs.aws.amazon.com/ec2/) |

### Week 1 Achievements:

- **AWS FCJ Program Integration:**
  - Successfully connected with FCJ admins, mentors, and fellow interns
  - Understood the internship program structure, timeline, and deliverables
  - Familiarized myself with communication protocols and weekly check-in processes
  - Reviewed and acknowledged FCJ rules, regulations, and code of conduct

- **AWS Fundamentals Mastery:**
  - Gained comprehensive understanding of AWS cloud computing principles
  - Learned the core AWS service categories:
    - Compute (EC2, Lambda)
    - Storage (S3, EBS, EFS)
    - Networking (VPC, CloudFront, Route53)
    - Database (DynamoDB, RDS, Aurora)
    - IoT (IoT Core, IoT Greengrass)
    - Machine Learning (SageMaker)
    - Management & Governance (CloudWatch, EventBridge)
    - Security (IAM, KMS)

- **AWS Account Setup:**
  - Successfully created and configured AWS Free Tier account
  - Enabled Multi-Factor Authentication (MFA) for enhanced security
  - Set up billing alerts to monitor Free Tier usage
  - Created IAM user with appropriate permissions

- **AWS Console & CLI Proficiency:**
  - Became comfortable navigating the AWS Management Console
  - Located and explored different AWS services through the web interface
  - Installed and configured AWS CLI v2 on local machine (Arch Linux)
  - Configured AWS CLI credentials including:
    - Access Key ID
    - Secret Access Key
    - Default Region (us-east-1)
    - Default Output Format (json)

- **AWS CLI Hands-on Experience:**
  - Executed basic AWS CLI commands:
    - `aws sts get-caller-identity` - Verify account and configuration
    - `aws ec2 describe-regions` - List available AWS regions
    - `aws ec2 describe-instances` - Check EC2 instances
    - `aws ec2 create-key-pair` - Create SSH key pairs
    - `aws s3 ls` - List S3 buckets
  - Learned to switch between Console and CLI for parallel resource management

- **EC2 Practical Skills:**
  - Launched first Amazon Linux 2 EC2 instance (t2.micro)
  - Created and configured EC2 key pairs for SSH access
  - Successfully connected to EC2 instance via SSH
  - Created a 10GB EBS volume and attached it to the instance
  - Configured Security Groups to allow SSH (port 22) access
  - Practiced stopping, starting, and terminating instances

- **Project Ideation:**
  - Began brainstorming the SIAM project concept
  - Identified the need for predictive maintenance in industrial settings
  - Started researching AWS IoT services for edge computing applications
  - Explored potential use cases for combining edge devices with cloud ML

- **Documentation Skills:**
  - Started maintaining a detailed worklog using Markdown
  - Documented all learning resources and reference materials
  - Created personal notes on AWS services and best practices
  - Began tracking questions and challenges for mentor discussions

### Challenges Encountered:

- Initial confusion with IAM roles vs. IAM users - resolved through FCJ mentor guidance
- AWS CLI configuration issues on Linux - fixed by ensuring proper permissions on `~/.aws/` directory
- Understanding the Free Tier limits and avoiding unexpected charges - set up billing alerts

### Next Week Preview:

In Week 2, I will dive into AWS IoT Core, learn MQTT protocols, and begin hands-on prototyping with ESP32 microcontrollers to test sensor integration and cloud connectivity - laying the groundwork for the SIAM edge device.
