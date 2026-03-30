# Project Plan — AWS ECS Infrastructure

**Objectives:**
- Build reusable components for quick-start AWS infrastructure
- Evaluate ECS specifically for AMI upgrade operations

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

Day-2 operations: upgrades, observability, app iteration.

- [x] **AMI rolling upgrade** — step through AMI versions using `scripts/update-ami.sh`; observe zero-downtime rolling replacement via ASG update policy
- [ ] **Multi-container task** — split app into two containers (app + backend) sharing EFS volume; verify inter-container communication via localhost
- [ ] **Secrets management** — move any config/secrets from environment variables to AWS Secrets Manager (or SSM Parameter Store SecureString); fetch at ECS task startup via `secrets` field in task definition
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

- [ ] **Self-signed TLS (dev)** — generate self-signed cert for `techillage.in` using `openssl`; upload to ACM (`aws acm import-certificate`); attach to ALB HTTPS listener (port 443); browsers will warn but traffic is encrypted — acceptable for dev/internal use
- [ ] **HTTPS listener** — ALB port 443 with the imported cert; HTTP → HTTPS redirect rule on port 80
- [ ] **Sidecar gateway** — run a lightweight TLS-terminating proxy as a sidecar container in the same ECS task; candidates to evaluate:
  - **nginx** — minimal config, familiar, good for simple TLS termination + reverse proxy
  - **Envoy** — more powerful (xDS, observability, retries), heavier config; better if moving toward a service mesh later
  - **Caddy** — auto-manages certs via ACME/Let's Encrypt, near-zero config for TLS; good fit for `techillage.in`
  - Decision criteria: config complexity, memory footprint, observability hooks, future service mesh alignment
- [ ] **Sidecar wiring** — sidecar listens on 443, forwards to app on localhost port; ECS task definition multi-container with shared `localhost` network (`awsvpc` mode); ALB talks to sidecar, not app directly
- [ ] **Custom domain** — Route 53 hosted zone + alias record for `techillage.in` pointing to ALB
- [ ] **ACM-issued cert (prod)** — replace self-signed with ACM-managed cert via DNS validation on `techillage.in`; zero browser warnings, auto-renewed
- [ ] **ECR** — move image from Docker Hub to AWS ECR; add ECR push permission to pipeline IAM role
- [ ] **Auto-scaling** — ECS service auto-scaling based on ALB request count or CPU; test scale-out/in

---

## Phase 5 — GitLab CI/CD

Automate the full deploy lifecycle via `.gitlab-ci.yml`.

- [ ] **Validate stage** — `aws cloudformation validate-template` + `cdk synth` on every push
- [ ] **Deploy stage** — deploy CF/CDK stack on `main` or tagged releases only
- [ ] **Verify stage** — smoke-test the ALB endpoint after deploy
- [ ] **Teardown job** — manual trigger to delete stacks and avoid runaway costs
- [ ] **Credentials** — AWS keys stored as GitLab CI/CD variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`)
- [ ] **Extend to EKS** — add `kubectl apply` stage once EKS phase is complete

---

## Phase 6 — Environment Strategy (dev / prod)

Apply consistent environment separation across IaC, naming, and CI/CD pipelines.

- [ ] **Naming convention** — all stack names, resource names, and tags include environment suffix (e.g. `ecs-cluster-dev`, `ecs-cluster-prod`); define the convention once and apply everywhere
- [ ] **Parameter files** — separate `params/dev.json` and `params/prod.json` (or CDK context files) for environment-specific values (instance type, desired count, AMI, domain)
- [ ] **CF/CDK env wiring** — templates accept `Environment` parameter; resource names and tags derived from it; no hard-coded env-specific values in templates
- [ ] **Pipeline promotion** — GitLab CI/CD: feature branches → deploy to `dev`; merges to `main` → deploy to `prod` (with manual approval gate before prod)
- [ ] **Isolated AWS accounts or namespaced stacks** — decide: separate AWS accounts per env vs single account with stack-name namespacing; document the trade-off
- [ ] **Secrets store** — use AWS Secrets Manager with env-scoped paths (`/dev/app/db-password`, `/prod/app/db-password`); IAM task role grants read access to its own env prefix only; no secrets in parameter files or CI/CD variables
- [ ] **Cost guard** — dev stack auto-teardown on schedule (nightly or weekend); prod stack protected from accidental delete via stack termination protection

---

## Phase 7 — EKS

Run the same workload on Kubernetes instead of ECS.

- [ ] **EKS cluster** — stand up a managed node group with the same nginx/app workload
- [ ] **Concept mapping** — Task Definition → Deployment, ECS Service → K8s Service, EFS → PersistentVolumeClaim
- [ ] **ALB Ingress** — AWS Load Balancer Controller replaces the manually wired ALB
- [ ] **Rolling AMI upgrade** — node group AMI update, mirror the ECS exercise
- [ ] **EKS parity doc** — write up ECS vs EKS trade-offs

---

## Phase 8 — Local Dev (minikube)

Run the same workload locally on Mac, no AWS required.

- [ ] **minikube cluster** — deploy the same manifests used for EKS
- [ ] **Storage** — hostPath or local PV as EFS equivalent
- [ ] **Ingress** — minikube ingress addon vs AWS Load Balancer Controller
- [ ] **Delta doc** — what changes between minikube and EKS (storage class, ingress, IAM, DNS)

---

## Phase 9 — Best Practices Review & Hardening

Review the full codebase against AWS and IaC best practices; produce a findings doc and fix all gaps.

- [ ] **Security** — IAM least privilege (wildcard actions/resources), open security group rules, secrets in env vars or plaintext, encryption at rest (EFS, EBS) and in transit
- [ ] **Reliability** — ALB and ECS health check tuning, multi-AZ task placement constraints, EFS mount options (`noresvport`, `tls`), ASG lifecycle hooks for graceful drain
- [ ] **CloudFormation/CDK hygiene** — hardcoded values that should be parameters, missing `DeletionPolicy` / `UpdateReplacePolicy`, missing stack termination protection on prod, incomplete `Outputs`
- [ ] **Cost** — unused or always-on resources, missing scheduled scaling for dev, no budget alarms
- [ ] **Operational** — missing CloudWatch alarms (CPU, ALB 5xx, EFS burst credits), no structured logging, scripts lacking `set -euo pipefail` and error handling
- [ ] **App / Docker** — Dockerfile best practices (non-root user, pinned base image, `.dockerignore`, multi-stage build if applicable)
- [ ] **Findings doc** — produce `docs/best-practices-review.md` with each finding: file + location, problem, recommended fix, severity (high/med/low)
- [ ] **Fix pass** — address all high and medium severity findings

---

## Phase 10 — IaC Evolution: Terraform

Re-implement in Terraform once CDK phase is done. Direct comparison of all three tools.

- [ ] **Terraform parity** — `main.tf` equivalent to `ecs-ec2-multi-node-cf.yaml`
- [ ] **State management** — S3 backend + DynamoDB lock table
- [ ] **Workspaces** — use workspaces for dev/prod separation
- [ ] **CF vs CDK vs TF comparison** — document trade-offs: verbosity, abstraction level, state model, drift detection, ecosystem


---

## Decisions & Constraints (standing)

| Topic | Decision | Reason |
|---|---|---|
| IaC tool | CloudFormation now, CDK next, Terraform later | Reusable component progression |
| Launch type | EC2 (not Fargate) | Cost control + visibility into host |
| Networking | VPC stack-owned, no NAT Gateway | Cost; public subnets only |
| EC2 access | SSM Session Manager only | No key pairs, no port 22 |
| SSM Association timeout | `WaitForSuccessTimeoutSeconds: 600` | Boot (~2min) + SSM agent start (~60s) + script (~30s) exceeded the original 300s limit, causing `MyEFSSetupAssociation` CREATE_FAILED |
| Image registry | Docker Hub now → ECR later | Simplicity; migrate when reusability requires it |
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
