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

EFS is a distributed network filesystem (NFS) — not a single physical disk. AWS replicates its data across multiple AZs internally. The two mount targets in this template are simply **network entry points** into that distributed system, one per AZ. There is one logical filesystem, accessible from both instances simultaneously.

```
EFS (distributed internally across AZs)
           ↑                      ↑
 MountTarget (AZ-0)       MountTarget (AZ-1)    ← access points, not separate disks
           ↑                      ↑
    EC2 Instance 1          EC2 Instance 2
```

nginx logs are mapped from inside the container through the host and into EFS:

```
nginx container /var/log/nginx
        ↓  (MountPoint in task definition)
EC2 host /ecs/logs/nginx
        ↓  (EFS mount via /etc/fstab in UserData)
EFS FileSystem  ← persists independently of any EC2
```

Both instances write to EFS concurrently without contention because each nginx instance writes its own log stream — they are not writing to the same file simultaneously. NFS locking only becomes a concern when multiple writers target the same file.

---

##### Storage options compared

| | Local disk (instance store) | EBS | EFS |
|---|---|---|---|
| Latency | ~0.1ms | ~0.5ms | ~1–3ms |
| Throughput | Very high | High | Moderate |
| Shared across instances | No | No | Yes |
| Survives instance termination | No | Yes | Yes |

**Why not EBS?**
EBS is a block device attached to a single EC2 instance — it cannot be mounted by two instances at the same time (Multi-Attach exists but is limited to specific volume types and use cases, and is not suitable for a general shared filesystem). When an instance is terminated and replaced by the ASG, the EBS volume is detached and the new instance gets a fresh one. You would have to manually re-attach and re-mount the old volume, which defeats the purpose of automated rolling upgrades.

**Why EFS is fine here despite network overhead:**
nginx buffers log writes and flushes periodically — it is not doing random low-latency I/O. The 1–3ms network overhead of EFS is irrelevant for log workloads. The penalty would matter for databases, caches, or high-throughput binary I/O.

---

##### Alternatives if you needed more than EFS

| Approach | How | When to use |
|---|---|---|
| **EFS** (current) | Shared NFS mount, no extra agents | Simple log persistence, small-to-medium volume |
| **Fluent Bit sidecar** | Container alongside nginx reads its log files and ships to S3 or CloudWatch | Production: searchable, queryable logs at scale; decouples log storage from instance lifecycle entirely |
| **Local disk + accept loss** | No persistence, logs only available while instance is running | Fine if logs are only needed for live debugging, not audit or analysis |

A Fluent Bit sidecar would run as a second container in the same ECS task, sharing a volume with nginx, and stream logs out in real time — no EFS needed at all. That is the production pattern when log durability and queryability matter.

---

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

### Troubleshoot — view stack events

Stack events show what happened during create, update, or rollback. Most useful when a deploy fails — look for `CREATE_FAILED` or `UPDATE_FAILED` entries and their `ResourceStatusReason`.

```bash
# All events (most recent first)
aws cloudformation describe-stack-events \
  --stack-name my-ecs-stack \
  --region us-east-1

# Failures only — filters to just the error lines
aws cloudformation describe-stack-events \
  --stack-name my-ecs-stack \
  --region us-east-1 \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].{Time:Timestamp,Resource:LogicalResourceId,Status:ResourceStatus,Reason:ResourceStatusReason}" \
  --output table

# Watch events live during deploy (poll every 10s) — run in a second terminal
watch -n 10 'aws cloudformation describe-stack-events \
  --stack-name my-ecs-stack --region us-east-1 \
  --query "StackEvents[:5].{Time:Timestamp,Resource:LogicalResourceId,Status:ResourceStatus}" \
  --output table'
```

### Troubleshoot — verify ECS instances registered

If the ECS service reports "no container instances", the EC2 instances booted but the ECS agent failed to register. Check:

```bash
# Should return 2 instance ARNs once instances are healthy (~5 min after stack create)
aws ecs list-container-instances --cluster MyECSCluster --region us-east-1

# If empty, check UserData execution log on the instance
# EC2 Console → instance → Actions → Monitor and troubleshoot → Get system log
# Or read directly if SSM is available:
aws ssm start-session --target <instance-id> --region us-east-1
# then: cat /var/log/userdata.log
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

### Validate — Health Check After Deploy

Run these after the stack is `CREATE_COMPLETE` or `UPDATE_COMPLETE` to confirm everything is healthy.

```bash
# 1. Confirm 2 EC2 instances registered with the cluster
aws ecs list-container-instances --cluster MyECSCluster --region us-east-1

# 2. Confirm service is running 2/2 tasks
aws ecs describe-services \
  --cluster MyECSCluster \
  --services MyService \
  --query "services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount,Status:status}" \
  --region us-east-1

# 3. List running tasks
aws ecs list-tasks --cluster MyECSCluster --region us-east-1

# 4. Check task health (substitute task ARN from above)
aws ecs describe-tasks \
  --cluster MyECSCluster \
  --tasks <task-arn> \
  --query "tasks[0].{Status:lastStatus,Health:healthStatus,StoppedReason:stoppedReason}" \
  --region us-east-1
```

**Expected state:** 2 container instances registered, service shows `runningCount: 2`, tasks in `RUNNING` status.

#### Things to explore before the AMI upgrade exercise

```bash
# Shell into an instance (no key pair needed)
aws ssm start-session --target <instance-id> --region us-east-1

# Once inside — confirm nginx container is running
docker ps

# Hit nginx directly
curl http://localhost

# Confirm EFS is mounted
df -h | grep efs
mount | grep efs

# Check nginx logs are landing on EFS
ls /ecs/logs/nginx/
cat /ecs/logs/nginx/access.log

# Write a test file from instance 1, then SSM into instance 2 and read it
# (proves both instances share the same EFS filesystem)
echo "hello from instance 1" > /ecs/logs/nginx/test.txt
```

On instance 2:
```bash
cat /ecs/logs/nginx/test.txt   # should print "hello from instance 1"
```

This confirms EFS is working as a shared filesystem across both AZs.

---

### ECS-Optimized AMIs for Upgrade Exercise

The stack uses **ECS-optimized AMIs** (not plain AL2). These have the ECS agent pre-installed — no manual installation needed in UserData. This is more reliable than installing the agent at boot time.

The table below lists available ECS-optimized AL2 AMIs as of 2026-03-27, ordered oldest to newest — use these as the upgrade path.

| AMI ID | Version | Date | Role |
|---|---|---|---|
| `ami-0dc67873410203528` | 2.0.20240328 | 2024-03-28 | **Starting point (current in template)** |
| `ami-021fe45d6043e82c8` | 2.0.20240409 | 2024-04-10 | |
| `ami-057f57c2fcd14e5f4` | 2.0.20240424 | 2024-04-25 | |
| `ami-0cf60a53ad9cf9e40` | 2.0.20240515 | 2024-05-16 | |
| `ami-06cc69030d77088a1` | 2.0.20260226 | 2026-02-26 | |
| `ami-0605df8f00118a0df` | 2.0.20260307 | 2026-03-07 | |
| `ami-07bb74bad4a7a0b7a` | 2.0.20260323 | 2026-03-23 | **Upgrade target** |

To refresh this list at any time:

```bash
# Oldest available (starting points)
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-ecs-hvm-*-x86_64-ebs" \
  --query "sort_by(Images, &CreationDate)[*].{Name:Name,ImageId:ImageId,CreationDate:CreationDate}" \
  --region us-east-1 \
  --output table
```

---

### AMI Upgrade Exercise — Step by Step

This is the planned exercise to practice zero-downtime AMI rolling upgrades using the ASG update policy.

**Goal:** Replace both EC2 instances with a newer ECS-optimized AMI without dropping any running tasks.

#### How it works

The ASG `UpdatePolicy` replaces one instance at a time:
1. CloudFormation creates a new instance with the new AMI (cluster temporarily has 3 instances)
2. ECS reschedules the task from the old instance onto the new one
3. Old instance is drained and terminated
4. Repeat for the second instance

#### Step 1 — Pick a target AMI

Use the table above. The current starting point is `ami-0dc67873410203528` (2024-03-28). The intended upgrade target is `ami-07bb74bad4a7a0b7a` (2026-03-23). You can step through intermediate AMIs to practice multiple upgrades.

#### Step 2 — Update the template

In [cf/ecs-ec2-multi-node-cf.yaml](cf/ecs-ec2-multi-node-cf.yaml), change only this line in `MyLaunchTemplate`:

```yaml
ImageId: 'ami-07bb74bad4a7a0b7a'  # amzn2-ami-ecs-hvm-2.0.20260323 — upgrade target
```

#### Step 3 — Deploy

```bash
aws cloudformation deploy \
  --template-file cf/ecs-ec2-multi-node-cf.yaml \
  --stack-name my-ecs-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

#### Step 4 — Monitor the rolling update

Open a second terminal and watch events live while the update runs:

```bash
watch -n 10 'aws cloudformation describe-stack-events \
  --stack-name my-ecs-stack --region us-east-1 \
  --query "StackEvents[:8].{Time:Timestamp,Resource:LogicalResourceId,Status:ResourceStatus}" \
  --output table'
```

You should see:
- `MyASG UPDATE_IN_PROGRESS` — rolling update started
- A new instance launching (check EC2 console — temporarily 3 instances)
- Old instance terminating
- Repeat for second instance
- `MyASG UPDATE_COMPLETE`

#### Step 5 — Verify

```bash
# Confirm both instances are on the new AMI
aws ec2 describe-instances \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=my-ecs-stack" \
  --query "Reservations[*].Instances[*].{Id:InstanceId,AMI:ImageId,State:State.Name}" \
  --output table --region us-east-1

# Confirm ECS service stayed at 2 running tasks throughout
aws ecs describe-services \
  --cluster MyECSCluster --services MyService \
  --query "services[0].{Running:runningCount,Desired:desiredCount}" \
  --region us-east-1
```

Both instances should show the new AMI ID. `runningCount` should be 2 throughout the update (never dropped to 0 — that's the point of `MinInstancesInService: 1`).

---

### Cost Notes

| Resource | Cost |
|---|---|
| EC2 `t3.small` × 2 | ~$0.023/hr each (~$0.046/hr total) |
| EFS | ~$0.30/GB-month (negligible for log volume) |
| ECS Cluster | Free |
| No ALB | Saves ~$0.008/hr + LCU charges |
