# Project Plan — AWS ECS Learning Path

A structured roadmap for building, operating, and evolving this ECS infrastructure.
Each phase builds on the last. Check off items as completed.

---

## Phase 1 — Foundation (Complete)

Core infrastructure and app running end-to-end.

- [x] Smoke test: VPC + EC2 + container (`cf/ec2-container-hello-world.yaml`)
- [x] Full ECS cluster: 2x t3.small, ASG, ALB, EFS (`cf/ecs-ec2-multi-node-cf.yaml`)
- [x] Node.js app: REST API + frontend UI with instance identity display
- [x] Round-robin traffic via ALB; `Connection: close` to make it observable
- [x] EFS-backed `/data` volume shared across both tasks
- [x] Suspend/resume workflow (S3 backup, conditional stack resources)
- [x] Deploy / delete / update-ami scripts in `scripts/`
- [x] SSM Session Manager for shell access — no SSH, no key pairs

---

## Phase 2 — Operations (Current)

Learn day-2 operations: upgrades, observability, app iteration.

- [ ] **AMI rolling upgrade** — step through AMI versions using `scripts/update-ami.sh`; observe zero-downtime rolling replacement via ASG update policy
- [ ] **Multi-container task** — split app into two containers (app + backend) sharing EFS volume; verify inter-container communication via localhost
- [ ] **Secrets management** — move any config/secrets from environment variables to SSM Parameter Store; fetch at task startup
- [ ] **CloudWatch logs** — add `awslogs` log driver to task definition; view container logs in CloudWatch instead of SSM exec
- [ ] **Health check tuning** — tighten ALB health check path/interval; observe task replacement when health check fails

---

## Phase 3 — IaC Evolution: CDK

Re-implement the CloudFormation stack in AWS CDK (TypeScript). `cdk/` skeleton already exists.

- [ ] **Parity** — CDK stack produces equivalent resources to `ecs-ec2-multi-node-cf.yaml`; deploy side-by-side and compare outputs
- [ ] **L2 constructs** — use ECS L2 (`Cluster`, `Ec2TaskDefinition`, `ApplicationLoadBalancedEc2Service`) where they simplify things; drop to L1 (`Cfn*`) only where needed
- [ ] **CDK deploy workflow** — add `cdk deploy` to scripts; document differences vs `cloudformation deploy`
- [ ] **CDK vs CF comparison** — write up what CDK abstracts away vs what it hides (useful for the eventual Terraform comparison)

---

## Phase 4 — Production Patterns

Add the pieces needed before this could serve real traffic.

- [ ] **HTTPS** — ACM certificate + ALB HTTPS listener (port 443); redirect HTTP → HTTPS
- [ ] **Custom domain** — Route 53 hosted zone + alias record pointing to ALB
- [ ] **CI/CD** — GitHub Actions workflow: build image → push to ECR → `cloudformation deploy` or `cdk deploy`
- [ ] **ECR** — move image from Docker Hub to AWS ECR; add ECR push permission to pipeline IAM role
- [ ] **Auto-scaling** — ECS service auto-scaling based on ALB request count or CPU; test scale-out/in

---

## Phase 5 — IaC Evolution: Terraform

Re-implement in Terraform once CDK phase is done. Direct comparison of all three tools.

- [ ] **Terraform parity** — `main.tf` equivalent to `ecs-ec2-multi-node-cf.yaml`
- [ ] **State management** — S3 backend + DynamoDB lock table
- [ ] **Workspaces** — use workspaces for dev/prod separation
- [ ] **CF vs CDK vs TF comparison** — document trade-offs: verbosity, abstraction level, state model, drift detection, ecosystem

---

## Decisions & Constraints (standing)

| Topic | Decision | Reason |
|---|---|---|
| IaC tool | CloudFormation now, CDK next, Terraform later | Learning progression |
| Launch type | EC2 (not Fargate) | Cost control + visibility into host |
| Networking | VPC stack-owned, no NAT Gateway | Cost; public subnets only |
| EC2 access | SSM Session Manager only | No key pairs, no port 22 |
| Image registry | Docker Hub now → ECR later | Simplicity for learning phase |
| AMI | Deliberately old (2024-03-28) | Rolling upgrade is a planned exercise |
| Cost target | ~$0.054/hr when running; $0 when suspended | Suspend stack when not in use |

---

## Reference

| Resource | Location |
|---|---|
| CF template (main) | `cf/ecs-ec2-multi-node-cf.yaml` |
| CF template (smoke test) | `cf/ec2-container-hello-world.yaml` |
| CDK stack | `cdk/lib/ecs-stack.ts` |
| App source | `src/app.js` |
| Scripts | `scripts/` |
| Architecture diagram | `README.md` → Architecture section |
| RCA / incident notes | `rca-ecs-setup.md` |
