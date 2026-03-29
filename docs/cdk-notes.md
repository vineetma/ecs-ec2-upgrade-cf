# CDK Notes

CDK stack: `cdk/` — TypeScript equivalent of `cf/ecs-ec2-multi-node-cf.yaml`.

---

## Status

Build and synth are clean. All resources synthesize correctly.

```bash
cd cdk
npm run build   # tsc — compiles TypeScript
npm run synth   # cdk synth — generates CloudFormation template
```

---

## Key Design Decisions

### Why L1 (Cfn*) constructs instead of L2

The CDK L2 `Vpc` construct creates NAT Gateways by default — ~$0.045/hr each, ~$32/month. This stack is intentionally cost-minimal (public subnets only, no NAT). Using L1 `CfnVPC`, `CfnSubnet`, etc. gives exact parity with the CloudFormation template and avoids CDK adding resources we don't want.

Similarly, `CfnAutoScalingGroup`, `CfnLoadBalancer`, etc. are used to keep the output predictable and directly comparable with the CF template.

L2 constructs that are used where they add value without side effects:
- `iam.Role` — cleaner policy attachment syntax
- `logs.LogGroup` — `retention` and `removalPolicy` are ergonomic
- `efs.CfnFileSystem`, `elbv2.CfnLoadBalancer`, etc. — L1 throughout for full control

### Why SSM Association for EFS mount (not UserData)

The EFS mount (`yum install amazon-efs-utils`, `/etc/fstab` entry, `mount -a`) is done via an `AWS::SSM::Association` targeting instances by stack tag, not in UserData.

UserData is reserved for a single line: writing `/etc/ecs/ecs.config`. This is deliberate — calling `systemctl start ecs` from UserData (which runs inside `cloud-final.service`) causes a deadlock because `ecs.service` has `After=cloud-final.service` in its unit file. Keeping UserData minimal avoids this entirely; systemd starts the ECS agent automatically after cloud-final completes.

The SSM association runs ~60s after boot and is idempotent (uses `grep -q` before appending to `/etc/fstab`).

### IMDSv2 with hopLimit: 2

The launch template sets `httpTokens: required` (IMDSv2 only) and `httpPutResponseHopLimit: 2`. The default hop limit of 1 drops IMDSv2 token requests from inside bridge-networked containers (they add one extra network hop). Setting it to 2 allows containers to access instance metadata without switching to the less secure IMDSv1.

### Rolling update policy on the ASG

The ASG uses a raw `cfnOptions.updatePolicy` injection (not a CDK-native API) to produce the same `AutoScalingRollingUpdate` policy as the CF template:

```typescript
(asg as any).cfnOptions.updatePolicy = {
  AutoScalingRollingUpdate: {
    MaxBatchSize: 1,
    MinInstancesInService: 1,
    PauseTime: 'PT2M',
  },
};
```

CDK L2 `AutoScalingGroup` has native `updatePolicy` support, but since we're using L1 `CfnAutoScalingGroup`, direct injection is needed.

### AppImage as context parameter

The app image is not hardcoded — it is passed via CDK context:

```bash
cdk deploy --context appImage=vineetma/ecs-hello-world:1.4
```

Falls back to `vineetma/ecs-hello-world:latest` if not provided. This mirrors the `--parameter-overrides AppImage=...` pattern in the CF deploy workflow.

---

## Deploy Workflow

### Prerequisites

1. AWS credentials configured (`aws configure` or environment variables)
2. CDK bootstrapped in the target account/region (one-time):

```bash
cdk bootstrap aws://ACCOUNT_ID/us-east-1
```

### Deploy

```bash
cd cdk

# With a specific image version
npm run deploy -- --context appImage=vineetma/ecs-hello-world:1.4

# Or with the default (latest)
npm run deploy
```

CDK will show a diff of resources to be created/modified and prompt for confirmation before deploying.

### Diff (compare against deployed stack)

```bash
npm run diff -- --context appImage=vineetma/ecs-hello-world:1.4
```

### Destroy

```bash
npm run destroy
```

> **Note:** Scale the ECS service to 0 before destroying to avoid the 300s ALB deregistration drain timeout — same as with the CF template. See [infra-design.md](infra-design.md#clean-up) for the full cleanup sequence.

---

## CDK vs CloudFormation — What Changes

| Concern | CloudFormation | CDK |
|---|---|---|
| Resource naming | Explicit `LogicalId` | CDK appends an 8-char hash (e.g. `ECSInstanceRole5196E36E`) unless you set a `logicalId` override |
| IAM role ARN | String literal | `Fn::Join` with `AWS::Partition` — partition-agnostic (works in GovCloud/China) |
| Update policy on ASG | `UpdatePolicy:` top-level key | Injected via `cfnOptions.updatePolicy` (L1 workaround) |
| Bootstrap dependency | None | Requires CDK bootstrap stack (`/cdk-bootstrap/hnb659fds/version` SSM parameter) |
| Feature flags | N/A | 69 unconfigured flags (cosmetic warning — no functional impact) |

---

## AMI Upgrade (CDK)

Same process as the CF template — change `imageId` in the launch template and redeploy:

```typescript
// cdk/lib/ecs-stack.ts — MyLaunchTemplate
imageId: 'ami-07bb74bad4a7a0b7a',  // amzn2-ami-ecs-hvm-2.0.20260323 — upgrade target
```

Then:

```bash
npm run deploy
```

CDK detects the launch template change, updates the ASG, and the rolling update policy replaces instances one at a time — same zero-downtime behavior as `cloudformation deploy`.
