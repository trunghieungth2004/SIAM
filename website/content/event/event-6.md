---
title: "Event 6: GenAI-powered App-DB Modernization Workshop"
date: 2025-08-13
draft: false
---

# Event 6

## Event Details

**Event Name:** GenAI-powered App-DB Modernization Workshop

**Date & Time:** 9:00, August 13, 2025

**Location:** 26th Floor, Bitexco Tower, 2 Hai Trieu Street, Ben Nghe Ward, District 1, Ho Chi Minh City

**Role:** Attendee

---

## Event Objectives

- Share best practices in modern application design
- Introduce Domain-Driven Design (DDD) and event-driven architecture
- Provide guidance on selecting the right compute services
- Present AI tools to support the development lifecycle

---

## Speakers

- **Jignesh Shah** – Director, Open Source Databases
- **Erica Liu** – Sr. GTM Specialist, AppMod
- **Fabrianne Effendi** – Associate Specialist SA, Serverless, Amazon Web Services

---

## Key Highlights

### Identifying the Drawbacks of Legacy Application Architecture

- **Long product release cycles** → Lost revenue/missed opportunities
- **Inefficient operations** → Reduced productivity, higher costs
- **Non-compliance with security regulations** → Security breaches, loss of reputation

### Transitioning to Modern Application Architecture – Microservices

Migrating to a modular system — each function is an independent service communicating via events, built on three core pillars:

- **Queue Management:** Handle asynchronous tasks
- **Caching Strategy:** Optimize performance
- **Message Handling:** Flexible inter-service communication

### Domain-Driven Design (DDD)

- **Four-step method:** Identify domain events → arrange timeline → identify actors → define bounded contexts
- **Bookstore case study:** Demonstrates real-world DDD application
- **Context mapping:** 7 patterns for integrating bounded contexts

### Event-Driven Architecture

- **3 integration patterns:** Publish/Subscribe, Point-to-point, Streaming
- **Benefits:** Loose coupling, scalability, resilience
- **Sync vs async comparison:** Understanding the trade-offs

### Compute Evolution

- **Shared Responsibility Model:** EC2 → ECS → Fargate → Lambda
- **Serverless benefits:** No server management, auto-scaling, pay-for-value
- **Functions vs Containers:** Criteria for appropriate choice

### Amazon Q Developer

- **SDLC automation:** From planning to maintenance
- **Code transformation:** Java upgrade, .NET modernization
- **AWS Transform agents:** VMware, Mainframe, .NET migration

---

## Key Takeaways

### Design Mindset

- **Business-first approach:** Always start from the business domain, not the technology
- **Ubiquitous language:** Importance of a shared vocabulary between business and tech teams
- **Bounded contexts:** Identifying and managing complexity in large systems

### Technical Architecture

- **Event storming technique:** Practical method for modeling business processes
- Use **event-driven communication** instead of synchronous calls
- **Integration patterns:** When to use sync, async, pub/sub, streaming
- **Compute spectrum:** Criteria for choosing between VM, containers, and serverless

### Modernization Strategy

- **Phased approach:** No rushing — follow a clear roadmap
- **7Rs framework:** Multiple modernization paths depending on the application
- **ROI measurement:** Cost reduction + business agility

### Applying to Work

- Apply **DDD** to current projects: Event storming sessions with business teams
- Refactor microservices: Use bounded contexts to define service boundaries
- Implement **event-driven patterns:** Replace some sync calls with async messaging
- Adopt **serverless:** Pilot AWS Lambda for suitable use cases
- Try **Amazon Q Developer:** Integrate into the dev workflow to boost productivity

---

## Event Experience

Attending the "GenAI-powered App-DB Modernization" workshop was extremely valuable, giving me a comprehensive view of modernizing applications and databases using advanced methods and tools. Key experiences included:

### Learning from Highly Skilled Speakers

- Experts from AWS and major tech organizations shared best practices in modern application design.
- Through real-world case studies, I gained a deeper understanding of applying DDD and Event-Driven Architecture to large projects.

### Hands-on Technical Exposure

- **Event Storming Sessions:** Participating in event storming sessions helped me visualize how to model business processes into domain events. This collaborative technique bridges the gap between business stakeholders and technical teams.
- **Microservices Architecture:** Learned how to split microservices and define bounded contexts to manage large-system complexity. The bookstore case study illustrated practical DDD implementation.
- **Integration Patterns:** Understood trade-offs between synchronous and asynchronous communication and integration patterns like pub/sub, point-to-point, and streaming.

### Compute Services Evolution

- **Shared Responsibility Spectrum:** Traced the evolution from EC2 (full control) → ECS (container orchestration) → Fargate (serverless containers) → Lambda (serverless functions).
- **Selection Criteria:** Learned criteria for choosing appropriate compute services based on workload characteristics, team skills, and business requirements.
- **Serverless Benefits:** Understood that serverless is not just about cost savings – it's about faster time-to-market, automatic scaling, and focusing on business logic rather than infrastructure.

### Amazon Q Developer Discovery

- **SDLC Integration:** Explored Amazon Q Developer, an AI tool that supports the entire Software Development Lifecycle from planning to maintenance.
- **Code Transformation:** Learned how Q Developer automates complex migration tasks like Java version upgrades and .NET modernization.
- **AWS Transform Agents:** Discovered specialized agents for migrating from VMware, Mainframe, and legacy .NET applications to modern AWS services.
- **Productivity Boost:** Saw demonstrations of how AI-powered code suggestions and transformations can significantly accelerate development velocity.

### Domain-Driven Design Deep Dive

- **Ubiquitous Language:** Realized the critical importance of establishing a shared vocabulary between business and technical teams to reduce misunderstandings.
- **Bounded Contexts:** Learned to identify and define clear boundaries between different parts of a system, reducing coupling and improving maintainability.
- **Event Storming:** Practiced this collaborative modeling technique:
  1. Identify domain events (past-tense actions)
  2. Arrange events on a timeline
  3. Identify actors (who triggers events)
  4. Define bounded contexts (system boundaries)
- **Context Mapping:** Understood 7 integration patterns for connecting bounded contexts, from shared kernel to separate ways.

### Event-Driven Architecture Insights

- **Decoupling Benefits:** Learned how event-driven patterns enable loose coupling, allowing services to evolve independently.
- **Integration Patterns:**
  - **Publish/Subscribe:** One-to-many broadcasting (SNS, EventBridge)
  - **Point-to-point:** One-to-one queuing (SQS)
  - **Streaming:** Real-time data processing (Kinesis, Kafka)
- **Sync vs Async Trade-offs:** Understood when to use synchronous (immediate consistency, simpler debugging) vs asynchronous (better scalability, fault tolerance) communication.

### Modernization Strategy

- **7Rs Framework:** Learned multiple modernization paths:
  - **Rehost** (lift-and-shift)
  - **Replatform** (lift-tinker-and-shift)
  - **Refactor/Re-architect** (redesign)
  - **Repurchase** (move to SaaS)
  - **Retire** (decommission)
  - **Retain** (keep as-is)
  - **Relocate** (VMware Cloud on AWS)
- **Phased Approach:** Emphasized starting small, measuring ROI, and scaling gradually rather than "big bang" transformations.

### Networking and Collaboration

- The workshop offered opportunities to exchange ideas with experts, peers, and business teams, enhancing the shared understanding between business and technology.
- Discussed real-world modernization challenges and solutions with participants from various industries.
- Connected with AWS specialists who provided insights beyond the official documentation.

### Practical Application

This workshop transformed my understanding of application modernization from "rewriting code" to a holistic approach encompassing:
- **Architecture patterns** (DDD, event-driven)
- **Compute evolution** (EC2 → serverless spectrum)
- **AI-powered tools** (Amazon Q Developer for automation)
- **Business alignment** (ROI measurement, phased approach)

The business-first mindset was particularly impactful – always starting from business domains and events rather than technical solutions. This approach ensures that modernization efforts deliver real business value, not just technical improvements.

### Key Lessons Learned

1. **DDD and event-driven patterns** reduce coupling while improving scalability and resilience.
2. **Modernization requires a phased approach** with ROI measurement; rushing the process can be risky.
3. **AI tools like Amazon Q Developer** can significantly boost productivity when integrated into the current workflow.
4. **Bounded contexts and ubiquitous language** are critical for managing complexity in large systems.
5. **Event storming** is an effective collaborative technique for bridging business-technical gaps.

This workshop provided immediately applicable knowledge for modernizing legacy applications using DDD, event-driven architecture, and modern AWS compute services, all accelerated by GenAI-powered development tools.
