# AWS ECS CloudFormation Stack

---

## Step 1 — Smoke Test: Single EC2 + Hello World Container (`cf/ec2-hello-world.yaml`)

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
  --template-file cf/ec2-hello-world.yaml \
  --stack-name hello-world-test \
  --region us-east-1

# With SSH key
aws cloudformation deploy \
  --template-file cf/ec2-hello-world.yaml \
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

## Step 2 — Full ECS Stack with ASG + EFS (`cf/ecs-ec2-multi-node-cf.yaml`)

### What this creates

| Resource | Count | Notes |
|---|---|---|
| VPC + Subnets + IGW | 1 VPC, 2 subnets | Stack-owned, no pre-existing networking needed |
| ECS Cluster | 1 | `MyECSCluster` |
| Auto Scaling Group | 1 | 2 `t3.small` instances across 2 AZs |
| EFS File System | 1 | Shared log storage, survives instance replacement |
| ECS Service | 1 | 2 `nginx` tasks, spread across instances |
| IAM Role | 1 | ECS registration + SSM access (no SSH needed) |

---

### Key Concepts

#### Why Auto Scaling Group instead of bare EC2 instances

Bare `AWS::EC2::Instance` resources cannot be replaced gracefully — CloudFormation terminates them immediately, killing any running containers with no warning.

An ASG with a rolling update policy handles AMI upgrades without downtime:

```yaml
# ecs-ec2-multi-node-cf.yaml — MyASG
UpdatePolicy:
  AutoScalingRollingUpdate:
    MaxBatchSize: 1           # Replace one instance at a time
    MinInstancesInService: 1  # Always keep at least 1 running
    PauseTime: PT2M           # Wait 2 min after new instance joins before continuing
```

Rolling upgrade flow:
1. Update `ImageId` in `MyLaunchTemplate` and run `cloudformation deploy`
2. ASG launches 1 new instance (new AMI) — cluster temporarily has 3 instances
3. ECS reschedules tasks onto the new instance
4. Old instance is drained and terminated
5. Repeat for the second instance

To trigger an AMI upgrade, change only this line in `MyLaunchTemplate`:

```yaml
# ecs-ec2-multi-node-cf.yaml — MyLaunchTemplate
ImageId: 'ami-0c55b159cbfafe1f0'  # <- replace with new AMI ID
```

---

#### Why EFS for log persistence

Container logs written to the EC2 host filesystem are lost when an instance is terminated — which happens during AMI upgrades, scaling events, or failures.

EFS is a shared network filesystem mounted on every EC2 instance at boot. nginx logs are mapped from inside the container through the host and into EFS:

```
nginx container /var/log/nginx
        ↓  (MountPoint in task definition)
EC2 host /ecs/logs/nginx
        ↓  (EFS mount via /etc/fstab in UserData)
EFS FileSystem  ← persists independently of any EC2
```

The task definition wires this up:

```yaml
# ecs-ec2-multi-node-cf.yaml — MyTaskDefinition
Volumes:
  - Name: nginx-logs
    Host:
      SourcePath: '/ecs/logs/nginx'   # on EC2 host, backed by EFS
ContainerDefinitions:
  - MountPoints:
      - SourceVolume: nginx-logs
        ContainerPath: '/var/log/nginx'  # inside the container
```

The EFS mount is set up on every instance via UserData in `MyLaunchTemplate`:

```bash
yum install -y amazon-efs-utils
mkdir -p /ecs/logs/nginx
echo "${EFSFileSystemId}:/ /ecs/logs efs defaults,_netdev 0 0" >> /etc/fstab
mount -a
```

---

#### Why two subnets across two AZs

Each subnet is pinned to one physical Availability Zone (a separate AWS data centre). The ASG spreads instances across both subnets so a single AZ failure only takes down one instance, not both.

```yaml
# ecs-ec2-multi-node-cf.yaml — MyASG
VPCZoneIdentifier:
  - !Ref MySubnet1   # AZ 0
  - !Ref MySubnet2   # AZ 1
```

It is possible to use a single subnet (both instances in the same AZ), but losing that AZ would take down the entire cluster.

---

#### EC2 access — SSM over SSH

No key pair or port 22 is used. Shell access is available via SSM Session Manager with no open ports:

```yaml
# ecs-ec2-multi-node-cf.yaml — ECSInstanceRole
ManagedPolicyArns:
  - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

```bash
# Shell into an instance (no key pair needed)
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx
```

---

### Architecture

```
VPC (10.0.0.0/16)
├── Subnet 1 (10.0.1.0/24, AZ-0)
│   └── EC2 Instance 1 (t3.small) ──► ECS Agent ──► nginx container (task 1)
│                                                          ↓ /var/log/nginx
└── Subnet 2 (10.0.2.0/24, AZ-1)                    EFS /ecs/logs/nginx
    └── EC2 Instance 2 (t3.small) ──► ECS Agent ──► nginx container (task 2)
                                                          ↓ /var/log/nginx
                        Both managed by ASG          EFS /ecs/logs/nginx
                        MyECSCluster (PlacementStrategy: spread by instanceId)
```

---

### Deploy

```bash
aws cloudformation deploy \
  --template-file cf/ecs-ec2-multi-node-cf.yaml \
  --stack-name my-ecs-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

No parameters required — VPC, subnets, and all networking are created by the stack.

### Verify

```bash
aws cloudformation describe-stacks \
  --stack-name my-ecs-stack \
  --query "Stacks[0].Outputs" \
  --region us-east-1
```

---

### Clean Up

```bash
# Delete the stack (removes VPC, EFS, ASG, ECS cluster — everything)
aws cloudformation delete-stack \
  --stack-name my-ecs-stack \
  --region us-east-1

# Wait for full deletion
aws cloudformation wait stack-delete-complete \
  --stack-name my-ecs-stack \
  --region us-east-1
```

**Note:** ECS task definition revisions are not deleted by CloudFormation — deregister manually:

```bash
aws ecs list-task-definitions --family-prefix hello-world-task --region us-east-1

# Deregister each revision (replace N with revision number)
aws ecs deregister-task-definition --task-definition hello-world-task:N --region us-east-1
```

---

### Cost Notes

| Resource | Cost |
|---|---|
| EC2 `t3.small` × 2 | ~$0.023/hr each (~$0.046/hr total) |
| EFS | ~$0.30/GB-month (negligible for log volume) |
| ECS Cluster | Free |
| No ALB | Saves ~$0.008/hr + LCU charges |
