# aws-ecs-setup-cf — Claude Instructions

## Project

AWS ECS infrastructure built with CloudFormation. Learning path: smoke test → full cluster → AMI upgrade → (future) Terraform.

## Templates

| File | Purpose | Status |
|---|---|---|
| `aws-ecs/ec2-hello-world.yaml` | Smoke test — self-contained VPC + EC2 + nginx | Complete |
| `aws-ecs/cloud-formation.yaml` | Full ECS cluster — 2x t3.small, MyECSCluster, 2 nginx tasks | Complete |

## Constraints

- **No ALB** — intentionally omitted to minimize costs
- **EC2 launch type** — not Fargate
- **Old AL2 AMI** in `cloud-formation.yaml` is deliberate — EC2 AMI upgrade is a planned exercise
- **VPC is stack-owned** — created inside the template (VPC, IGW, 2 subnets, route table); no pre-existing networking required
- **No SSH / no key pairs** — use SSM Session Manager; `AmazonSSMManagedInstanceCore` is attached to the instance role

## IaC

- **CloudFormation** is the current tool — all changes go here
- **Terraform** is placeholder for future work — do not start until user signals readiness

## Deploy Pattern

1. Author/modify template
2. Validate: `aws cloudformation validate-template --template-body file://template.yaml`
3. Deploy: `aws cloudformation deploy ...`
4. Verify via stack outputs
5. Clean up: delete stack + deregister any ECS task definition revisions

## Agent

Use the `ecs-infra` agent for all infrastructure work in this project.
