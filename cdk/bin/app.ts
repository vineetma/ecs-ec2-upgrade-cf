#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { EcsEc2Stack } from '../lib/ecs-stack';

const app = new cdk.App();

// AppImage is required — pass via --context appImage=<dockerhub-image> or cdk.json
const appImage = app.node.tryGetContext('appImage') ?? 'vineetma/ecs-hello-world:latest';

new EcsEc2Stack(app, 'my-ecs-stack', {
  appImage,
  env: {
    // Explicit region — CDK needs this for AZ lookups. Override via CDK_DEFAULT_ACCOUNT/CDK_DEFAULT_REGION
    // or pass --profile / --region at deploy time.
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
  },
  description: 'ECS Cluster with ASG-managed EC2 instances, EFS-backed log persistence, and an ALB for round-robin traffic. (CDK equivalent of cf/ecs-ec2-multi-node-cf.yaml)',
});
