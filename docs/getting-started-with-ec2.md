# Getting Started — Smoke Test: Single EC2 + Hello World Container

Template: `cf/ec2-hello-world.yaml`

Minimal CloudFormation template to validate the basics before deploying the full ECS stack.
Creates its own VPC, subnet, and internet gateway — no pre-existing infrastructure required.

| Resource | Detail |
|---|---|
| EC2 | `t2.micro` (free-tier eligible) |
| AMI | Latest Amazon Linux 2023 (auto-resolved via SSM) |
| Networking | New VPC (`10.0.0.0/16`) + public subnet + internet gateway (all created by this stack) |
| Container | `nginx:latest` via Docker on port 80 |
| Key pair | Optional (only needed for SSH debugging) |

## Deploy

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

## Verify

```bash
# Get the public URL from stack outputs
aws cloudformation describe-stacks \
  --stack-name hello-world-test \
  --query "Stacks[0].Outputs" \
  --region us-east-1
```

Open the `URL` output in a browser — you should see the nginx welcome page.

## Clean Up

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
