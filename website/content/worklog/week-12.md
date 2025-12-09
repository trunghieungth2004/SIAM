---
title: "Week 12 Worklog"
date: 2025-11-24
draft: false
weight: 12
---

# Week 12 Worklog

### Week 12 Objectives:
- Finalize all project documentation and deliverables
- Conduct final system demo for FCJ mentors and stakeholders
- Perform knowledge transfer and project handover
- Document lessons learned and best practices
- Identify future improvements and roadmap
- Complete internship reflection and final report

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Finalize project documentation: <br>  + Complete README.md <br>  + Update architecture diagrams <br>  + Finalize API documentation <br>  + Create deployment checklist <br> - Package all deliverables | 24/11/2025 | 24/11/2025 | Documentation standards |
| 2 | - Prepare final demo presentation: <br>  + Create presentation slides <br>  + Rehearse demo flow <br>  + Prepare backup scenarios <br>  + Test demo environment | 25/11/2025 | 25/11/2025 | Presentation best practices |
| 3 | - Conduct final demo to FCJ mentors: <br>  + Present architecture overview <br>  + Live system demonstration <br>  + Q&A session <br>  + Gather feedback | 26/11/2025 | 26/11/2025 | Internal demo materials |
| 4 | - Knowledge transfer session: <br>  + Code walkthrough <br>  + Infrastructure review <br>  + Troubleshooting guidance <br>  + Handover documentation | 27/11/2025 | 27/11/2025 | Handover checklist |
| 5 | - Document lessons learned: <br>  + Technical challenges and solutions <br>  + Best practices discovered <br>  + What went well / What to improve <br>  + Future recommendations | 28/11/2025 | 28/11/2025 | Retrospective template |
| 6 | - Internship reflection and wrap-up: <br>  + Complete final report <br>  + Thank FCJ mentors and team <br>  + Update LinkedIn and portfolio <br>  + Plan next steps | 29/11/2025 | 08/12/2025 | FCJ internship guidelines |

### Week 12 Achievements:

- **Project Documentation Finalization:**
  - **README.md Enhancements:**
    - Added comprehensive project overview with feature highlights
    - Included architecture diagram (embedded PNG from draw.io)
    - Detailed setup instructions with prerequisites
    - Component-by-component deployment guide
    - Troubleshooting FAQ section
    - Cost breakdown and optimization tips
    - License and attribution (MIT License)
  
  - **Architecture Documentation:**
    - Updated `SIAM_Architecture.drawio` with final component versions
    - Created high-resolution PNG export for presentations
    - Added data flow sequence diagrams
    - Documented each AWS service's role and configuration
  
  - **API Documentation:**
    - Finalized OpenAPI 3.0 specification (swagger.yaml)
    - Added detailed endpoint descriptions
    - Included authentication guide
    - Provided code examples in JavaScript and Python
    - Documented error codes and troubleshooting
  
- **Final Demo Presentation:**
  - **Presentation Structure (30 minutes):**
    1. **Introduction (3 min):**
       - Project motivation: Predictive maintenance problem
       - Solution overview: Hybrid edge-cloud architecture
       - Key achievements and metrics
    
    2. **Architecture Deep Dive (7 min):**
       - Edge layer: Raspberry Pi + Greengrass + Coral TPU
       - Cloud layer: IoT Core, Lambda, DynamoDB, S3, SageMaker
       - Data flow: Sensor → Edge → Cloud → Dashboard
       - Highlight: Stream Manager offline resilience
    
    3. **Live Demonstration (15 min):**
       - Show web dashboard with real-time data
       - Display normal operation metrics
       - **Anomaly Simulation:** Attach weight to fan blade
       - Wait for ML detection (~2 minutes)
       - Show alarm notification email
       - Display CloudWatch metrics spike
       - **Offline Test:** Disconnect network, show buffering
       - Reconnect and demonstrate automatic data sync
       - Query API via Swagger UI
    
    4. **Technical Highlights (3 min):**
       - Automated MLOps pipeline (bi-weekly retraining)
       - API key rotation (monthly, automated)
       - Cost optimization: $27/month per device
       - Zero data loss guarantee
    
    5. **Q&A (2 min):**
       - Addressed mentor questions
  
  - **Demo Execution:**
    - **Date:** 26/11/2025, 2:00 PM
    - **Attendees:** 3 FCJ mentors, 2 peer interns
    - **Outcome:**  Demo successful, no technical issues
    - **Feedback received:**
      - "Impressive end-to-end integration"
      - "Great use of AWS IoT Greengrass"
      - "Documentation is comprehensive and clear"
      - "Consider adding multi-device dashboard view"
      - "Explore AWS IoT TwinMaker for digital twin visualization"

- **Knowledge Transfer Session:**
  - **Code Walkthrough (1.5 hours):**
    - Explained AWS.sh modular architecture
    - Walked through Lambda function implementations
    - Demonstrated Greengrass component development
    - Showed ML model training and deployment process
  
  - **Infrastructure Review:**
    - Reviewed each AWS component's configuration
    - Explained IAM roles and permissions
    - Discussed EventBridge automation rules
    - Covered CloudWatch monitoring setup
  
  - **Troubleshooting Guidance:**
    - Shared common issues and solutions document
    - Demonstrated CloudWatch Logs analysis
    - Showed Greengrass debugging techniques
    - Explained DynamoDB query optimization
  
  - **Handover Deliverables:**
    - GitHub repository with complete source code
    - AWS infrastructure configuration files
    - Greengrass component recipes
    - Documentation in Markdown format
    - Demo video recording
    - Contact information for future questions

- **Lessons Learned Documentation:**
  - **Technical Challenges and Solutions:**
    
    | Challenge | Solution | Lesson Learned |
    |-----------|----------|----------------|
    | ESP32 limited processing power | Switched to Raspberry Pi 5 | Choose edge hardware based on workload requirements |
    | Coral TPU library obsolescence | Dockerized inference container | Containerization solves dependency conflicts |
    | Network outages causing data loss | Greengrass Stream Manager | Offline-first design is critical for industrial IoT |
    | Manual model deployment toil | Automated MLOps with EventBridge | Automation reduces errors and saves time |
    | API key security concerns | Monthly automated rotation | Security automation improves posture |
    | High AWS costs during development | Cost monitoring and optimization | Set billing alerts early, optimize continuously |
  
  - **What Went Well:**
    -  Modular script architecture enabled rapid iteration
    -  Docker containers solved TPU library compatibility issues
    -  Stream Manager provided rock-solid offline resilience
    -  Automated MLOps pipeline worked flawlessly
    -  CloudWatch monitoring caught issues proactively
    -  Comprehensive testing revealed edge cases early
    -  Documentation reduced handover time significantly
  
  - **What Could Be Improved:**
    -  Initial architecture planning took longer than expected
    -  ESP32 prototyping was useful but time-intensive
    -  Model accuracy could be improved with more training data
    -  Frontend security (API key exposure) acceptable for demo but not production-grade
    -  Multi-device support not implemented (single-device only)
    -  No alerting for cost threshold breaches (billing alerts only)
  
  - **Best Practices Discovered:**
    1. **Infrastructure as Code:** Scripts enable rapid environment recreation
    2. **Service Discovery:** AWS CLI queries eliminate hardcoded ARNs
    3. **Edge-First Design:** Local processing reduces cloud costs and latency
    4. **Automated Testing:** Catch regressions early in development
    5. **Comprehensive Logging:** CloudWatch Logs are invaluable for debugging
    6. **Security Automation:** Rotate credentials automatically
    7. **Cost Monitoring:** Review AWS billing weekly

