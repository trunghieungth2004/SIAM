---
title: "Event 4: AWS Cloud Mastery Series #3 - Security on AWS"
date: 2025-11-29
draft: false
---

# Event 4

## Event Details

**Event Name:** AWS Cloud Mastery Series #3 - Security on AWS (Well-Architected Security Pillar)

**Date & Time:** Saturday, November 29, 2025 | 8:30 - 12:00

**Location:** AWS Vietnam Office, 26th Floor, Bitexco Financial Tower, 2 Hai Trieu Street, Ben Nghe Ward, District 1, Ho Chi Minh City

**Role:** Attendee

**Status:** Past Event (ended 10 days ago)

---

## Event Agenda

### 8:30 – 8:50 AM | Opening & Security Foundation
- Role of Security Pillar in Well-Architected Framework
- Core principles: Least Privilege – Zero Trust – Defense in Depth
- Shared Responsibility Model
- Top threats in cloud environments in Vietnam

### Pillar 1 — Identity & Access Management

#### 8:50 – 9:30 AM | Modern IAM Architecture
- **IAM:** Users, Roles, Policies – avoiding long-term credentials
- **IAM Identity Center:** SSO, permission sets
- **SCP & permission boundaries** for multi-account environments
- **MFA, credential rotation, Access Analyzer**
- **Mini Demo:** Validate IAM Policy + simulate access

### Pillar 2 — Detection

#### 9:30 – 9:55 AM | Detection & Continuous Monitoring
- **CloudTrail** (org-level), **GuardDuty**, **Security Hub**
- Logging at every layer: VPC Flow Logs, ALB/S3 logs
- Alerting & automation with EventBridge
- Detection-as-Code (infrastructure + rules)

### 9:55 – 10:10 AM | Coffee Break

### Pillar 3 — Infrastructure Protection

#### 10:10 – 10:40 AM | Network & Workload Security
- **VPC segmentation**, private vs public placement
- **Security Groups vs NACLs:** application models
- **WAF + Shield + Network Firewall**
- Workload protection: EC2, ECS/EKS security basics

### Pillar 4 — Data Protection

#### 10:40 – 11:10 AM | Encryption, Keys & Secrets
- **KMS:** key policies, grants, rotation
- **Encryption at-rest & in-transit:** S3, EBS, RDS, DynamoDB
- **Secrets Manager & Parameter Store** — rotation patterns
- Data classification & access guardrails

### Pillar 5 — Incident Response

#### 11:10 – 11:40 AM | IR Playbook & Automation
- IR lifecycle according to AWS
- **Playbook scenarios:**
  - Compromised IAM key
  - S3 public exposure
  - EC2 malware detection
- Snapshot, isolation, evidence collection
- Auto-response using Lambda/Step Functions

### 11:40 – 12:00 PM | Wrap-Up & Q&A
- Summary of 5 pillars
- Common pitfalls & real-world practices in Vietnamese enterprises
- Security learning roadmap (Security Specialty, SA Pro)

---

## Key Takeaways

### Security Foundation
- **Well-Architected Security Pillar:** Understood security as a foundational element, not an afterthought.
- **Core Principles:**
  - **Least Privilege:** Grant only permissions needed, nothing more.
  - **Zero Trust:** Never trust, always verify – even internal resources.
  - **Defense in Depth:** Multiple layers of security controls.
- **Shared Responsibility Model:** Clearly understood the division between AWS's security responsibilities (of the cloud) and customer responsibilities (in the cloud).

### Pillar 1: Identity & Access Management
- **Modern IAM:** Learned to avoid long-term credentials by using IAM roles and temporary credentials.
- **IAM Identity Center (AWS SSO):** Centralized access management for multi-account environments.
- **Policy Validation:** Used IAM Access Analyzer to identify overly permissive policies.
- **Multi-account Strategy:** Implemented SCPs (Service Control Policies) and permission boundaries for organizational governance.

### Pillar 2: Detection
- **Continuous Monitoring:** CloudTrail for API auditing, GuardDuty for threat detection, Security Hub for centralized findings.
- **Comprehensive Logging:** Logging at every layer (VPC Flow Logs, ALB logs, S3 access logs) provides complete visibility.
- **Automated Response:** EventBridge rules trigger automated remediation workflows.
- **Detection-as-Code:** Version-controlled security rules for consistency and reproducibility.

### Pillar 3: Infrastructure Protection
- **Network Segmentation:** VPC design with public/private subnets, NACLs, and Security Groups.
- **Defense Layers:** WAF for application-layer protection, Shield for DDoS mitigation, Network Firewall for advanced filtering.
- **Workload Security:** Instance hardening for EC2, pod security for EKS, task role permissions for ECS.

### Pillar 4: Data Protection
- **Encryption Everywhere:**
  - At-rest: S3 (SSE-KMS), EBS (encrypted volumes), RDS (encrypted databases)
  - In-transit: TLS/SSL for all communications
- **Key Management:** KMS for centralized key management with rotation policies and fine-grained access control.
- **Secrets Management:** Secrets Manager for automated rotation of database credentials, API keys, and passwords.
- **Data Classification:** Tagging and access policies based on data sensitivity.

### Pillar 5: Incident Response
- **IR Lifecycle:** Preparation → Detection → Analysis → Containment → Eradication → Recovery → Lessons Learned.
- **Playbook Scenarios:**
  - **Compromised IAM Key:** Immediate key rotation, CloudTrail analysis, revoke sessions.
  - **S3 Public Exposure:** Block public access, review bucket policies, investigate how it occurred.
  - **EC2 Malware:** Snapshot for forensics, isolate instance, terminate/replace.
- **Automation:** Lambda functions and Step Functions for automated incident response workflows.
- **Forensics:** Snapshot volumes and preserve logs before remediation for investigation.

### Common Pitfalls in Vietnamese Enterprises
- Over-privileged IAM policies (using wildcards excessively)
- Lack of MFA enforcement
- Insufficient logging and monitoring
- Manual security processes instead of automation
- Not practicing incident response before incidents occur

---

## Event Experience

The AWS Security workshop provided a comprehensive, practical approach to cloud security through the lens of the Well-Architected Framework.

### Structured Learning Approach
- The 5-pillar structure (IAM, Detection, Infrastructure Protection, Data Protection, Incident Response) provided a systematic way to think about security.
- Each pillar built upon the previous one, creating a holistic security strategy.

### IAM Deep Dive
- The IAM session was particularly valuable – learned that proper access management is the foundation of cloud security.
- Hands-on demo of IAM Access Analyzer revealed overly permissive policies that I wouldn't have noticed otherwise.
- Understanding permission boundaries and SCPs showed me how to implement organizational governance at scale.

### Detection and Monitoring
- Realized that detection is not just about tools (GuardDuty, CloudTrail), but about building a detection strategy.
- EventBridge automation demonstrated how to move from reactive to proactive security.
- Detection-as-Code concept showed that security rules should be version-controlled like application code.

### Network Security Clarity
- Finally understood the difference between Security Groups (stateful, instance-level) and NACLs (stateless, subnet-level).
- WAF + Shield + Network Firewall comparison clarified which service to use for different threat types.

### Encryption and Key Management
- Learned that encryption is not optional but a default best practice in AWS.
- KMS deep dive showed the importance of key policies and rotation strategies.
- Secrets Manager's automated rotation feature was a game-changer for managing credentials securely.

### Incident Response Preparation
- The IR playbook scenarios were eye-opening – learned that preparation before incidents is crucial.
- Automated response workflows using Lambda demonstrated how to reduce MTTR (Mean Time To Respond).
- Snapshot-before-remediation principle emphasized the importance of forensics in incident investigation.

### Real-world Context
- Discussion of common pitfalls in Vietnamese enterprises resonated with challenges I've observed.
- Understanding that security is a continuous process, not a one-time setup, changed my perspective.

### Certification Roadmap
- The security learning roadmap clarified the path from foundational knowledge to AWS Certified Security – Specialty.
- Understood how security knowledge integrates with the Solutions Architect Professional certification.

### Networking and Discussion
- Exchanged experiences with participants from various industries about their security challenges.
- Learned about real-world incident response cases (anonymized) that illustrated the importance of preparation.

This workshop fundamentally changed my approach to cloud security from "applying security measures" to "thinking security-first." The Well-Architected Security Pillar framework provides a practical, comprehensive checklist for building secure systems on AWS, and the hands-on demos made abstract concepts concrete and actionable.
