# AWS ECS CloudFormation Stack

---

## Step 1 — Smoke Test: Single EC2 + Hello World Container (`ec2-hello-world.yaml`)

Minimal CloudFormation template to validate the basics before deploying the full ECS stack.
Creates its own VPC, subnet, and internet gateway — no pre-existing infrastructure required.

| Resource | Detail |
|---|---|
| EC2 | `t2.micro` (free-tier eligible) |
| AMI | Latest Amazon Linux 2023 (auto-resolved via SSM) |
| Networking | New VPC (`10.0.0.0/16`) + public subnet + internet gateway (all created by this stack) |
| Container | `nginx:latest` via Docker on port 80 |
| Key pair | Optional (only needed for SSH debugging) |

### Deploy

```bash
# Without SSH key (minimal — no pre-existing infrastructure needed)
aws cloudformation deploy \
  --template-file ec2-hello-world.yaml \
  --stack-name hello-world-test \
  --region us-east-1

# With SSH key
aws cloudformation deploy \
  --template-file ec2-hello-world.yaml \
  --stack-name hello-world-test \
  --parameter-overrides KeyName=my-key-pair \
  --region us-east-1
```

### Verify it works

```bash
# Get the public URL from stack outputs
aws cloudformation describe-stacks \
  --stack-name hello-world-test \
  --query "Stacks[0].Outputs" \
  --region us-east-1
```

Open the `URL` output in a browser — you should see the nginx welcome page.

### Clean Up

```bash
# Delete the stack
aws cloudformation delete-stack \
  --stack-name hello-world-test \
  --region us-east-1

# Wait for full deletion
aws cloudformation wait stack-delete-complete \
  --stack-name hello-world-test \
  --region us-east-1
```

> **Cost**: `t2.micro` is free-tier eligible (750 hrs/month). If outside free tier, ~$0.0116/hr. Delete the stack as soon as you're done testing.

---

## Step 2 — Full ECS Stack (`cloud-formation.yaml`)

## What this creates

| Resource | Count | Notes |
|---|---|---|
| ECS Cluster | 1 | `MyECSCluster` |
| EC2 instances | 2 | `t3.small`, old Amazon Linux 2 AMI (intentional for upgrade testing) |
| ECS Tasks | 2 | 1 `nginx` container per EC2 instance |
| IAM Role + Instance Profile | 1 | Allows EC2 to register with ECS |
| Security Group | 1 | SSH (22) + HTTP (80) open |

---

## Deploy

```bash
aws cloudformation deploy \
  --template-file cloud-formation.yaml \
  --stack-name my-ecs-stack \
  --parameter-overrides \
    KeyName=my-key-pair \
    VpcId=vpc-xxxxxxxx \
    SubnetId1=subnet-xxxxxxxx \
    SubnetId2=subnet-yyyyyyyy \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

> `--capabilities CAPABILITY_NAMED_IAM` is required because the template creates an IAM role.

---

## Clean Up (Delete All Resources)

Run these commands to fully remove the stack and avoid ongoing charges:

### Step 1 — Delete the CloudFormation stack

```bash
aws cloudformation delete-stack \
  --stack-name my-ecs-stack \
  --region us-east-1
```

### Step 2 — Wait for deletion to complete

```bash
aws cloudformation wait stack-delete-complete \
  --stack-name my-ecs-stack \
  --region us-east-1
```

### Step 3 — Verify the stack is gone

```bash
aws cloudformation describe-stacks \
  --stack-name my-ecs-stack \
  --region us-east-1
```

Expected: `An error occurred (ValidationError) ... Stack with id my-ecs-stack does not exist` — this means it was deleted successfully.

### Step 4 — Check for leftover ECS task definition revisions (not deleted by CloudFormation)

```bash
# List task definition revisions
aws ecs list-task-definitions \
  --family-prefix hello-world-task \
  --region us-east-1

# Deregister each revision (replace N with the revision number)
aws ecs deregister-task-definition \
  --task-definition hello-world-task:N \
  --region us-east-1
```

---

## Cost Notes

- **EC2**: `t3.small` is ~$0.023/hr each (~$0.046/hr total). Stop instances to pause costs without deleting.
- **ECS**: No charge for the cluster itself — you pay only for the underlying EC2.
- **No ALB**: This template intentionally omits a Load Balancer (~$0.008/hr + LCU charges) to keep costs minimal.
- **IAM / Security Group**: Free.

### Temporarily stop EC2 instances (pause costs without deleting the stack)

```bash
# Get instance IDs from stack outputs
aws cloudformation describe-stacks \
  --stack-name my-ecs-stack \
  --query "Stacks[0].Outputs" \
  --region us-east-1

# Stop both instances
aws ec2 stop-instances \
  --instance-ids i-xxxxxxxxxxxxxxxxx i-yyyyyyyyyyyyyyyyy \
  --region us-east-1
```

---

## Architecture

```
VPC
├── Subnet 1 → EC2 Instance 1 (t3.small) → ECS Agent → nginx container (task 1)
└── Subnet 2 → EC2 Instance 2 (t3.small) → ECS Agent → nginx container (task 2)
                                              ↑
                                        MyECSCluster
                                    (PlacementStrategy: spread by instanceId)
```
