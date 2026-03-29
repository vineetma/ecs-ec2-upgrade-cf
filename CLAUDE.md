# aws-ecs-setup-cf — Claude Instructions

## Project

AWS ECS infrastructure built with CloudFormation. Objectives: build reusable components for quick-start AWS infrastructure; evaluate ECS specifically for AMI upgrade operations. Roadmap: smoke test → full cluster → AMI upgrade → (future) Terraform.

## Templates

| File | Purpose | Status |
|---|---|---|
| `cf/ec2-hello-world.yaml` | Smoke test — self-contained VPC + EC2 + nginx | Complete |
| `cf/ecs-ec2-multi-node-cf.yaml` | Full ECS cluster — 2x t3.small, ASG, EFS log persistence | Complete |

## Constraints

- **ALB included** — internet-facing, spans both public subnets, round-robins across both ECS tasks; costs ~$0.008/hr base
- **EC2 launch type** — not Fargate
- **ECS-optimized AMI** — `ami-0dc67873410203528` (2024-03-28) is deliberately old — AMI rolling upgrade is a planned exercise
- **VPC is stack-owned** — created inside the template (VPC, IGW, 2 subnets, route table); no pre-existing networking required
- **No SSH / no key pairs** — use SSM Session Manager; `AmazonSSMManagedInstanceCore` is attached to the instance role
- **EC2 instances not directly internet-accessible on port 80** — EC2 security group allows port 80 from ALB SG only

## General

- Default IaC tool: **CloudFormation** (YAML). Terraform is a future path — do not generate `.tf` files until explicitly asked.
- AWS region default: `us-east-1` unless stated otherwise.
- Cost awareness is a priority — always flag non-free-tier resources and their hourly rates.

## EC2 Access

- **Never** add EC2 key pairs (`KeyName`) or open port 22 in security groups.
- **Always** use SSM Session Manager for shell access: add `arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore` to the EC2 instance role.
- No open ports, no key management, no manual steps.

## IaC

- **CloudFormation** is the current tool — all changes go here
- **Terraform** is placeholder for future work — do not start until user signals readiness

## Deploy Pattern

1. Author/modify template
2. Validate: `aws cloudformation validate-template --template-body file://template.yaml`
3. Deploy: `aws cloudformation deploy ...`
4. Verify via stack outputs
5. Clean up: delete stack + deregister any ECS task definition revisions

## Agents

- Use the `ecs-infra` agent for all infrastructure work in this project
- Use the `commit` agent to stage, commit, and push changes — always push to `origin/main` without asking for confirmation
