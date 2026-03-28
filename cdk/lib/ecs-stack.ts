import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as efs from 'aws-cdk-lib/aws-efs';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

export interface EcsEc2StackProps extends cdk.StackProps {
  /**
   * Docker Hub image for the Node.js app.
   * Build and push with: docker build -t ecs-hello-world . && docker push <user>/ecs-hello-world:latest
   */
  appImage: string;
}

export class EcsEc2Stack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: EcsEc2StackProps) {
    super(scope, id, props);

    // -------------------------------------------------------------------------
    // VPC — stack-owned; 2 public subnets across 2 AZs; no NAT Gateway (cost).
    // CDK's Vpc L2 construct normally creates NAT Gateways — we use L1 (Cfn*)
    // to exactly replicate the CF template: IGW + single route table, public only.
    // -------------------------------------------------------------------------

    const vpc = new ec2.CfnVPC(this, 'MyVPC', {
      cidrBlock: '10.0.0.0/16',
      enableDnsSupport: true,
      enableDnsHostnames: true,
      tags: [{ key: 'Name', value: 'MyECSVPC' }],
    });

    const igw = new ec2.CfnInternetGateway(this, 'MyInternetGateway', {});

    new ec2.CfnVPCGatewayAttachment(this, 'MyVPCGatewayAttachment', {
      vpcId: vpc.ref,
      internetGatewayId: igw.ref,
    });

    const routeTable = new ec2.CfnRouteTable(this, 'MyRouteTable', {
      vpcId: vpc.ref,
    });

    const defaultRoute = new ec2.CfnRoute(this, 'MyDefaultRoute', {
      routeTableId: routeTable.ref,
      destinationCidrBlock: '0.0.0.0/0',
      gatewayId: igw.ref,
    });
    // Route needs the IGW attachment to exist first (mirrors CF DependsOn).
    defaultRoute.addDependency(
      this.node.findChild('MyVPCGatewayAttachment') as cdk.CfnResource,
    );

    // Two subnets — one per AZ.  MapPublicIpOnLaunch so ASG instances get
    // public IPs and can reach ECR / Docker Hub for image pulls.
    const subnet1 = new ec2.CfnSubnet(this, 'MySubnet1', {
      vpcId: vpc.ref,
      cidrBlock: '10.0.1.0/24',
      // Fn::Select [0, Fn::GetAZs] — CDK resolves AZs at synth time via context.
      // availabilityZone left implicit so CDK picks the first AZ for the region.
      availabilityZone: cdk.Fn.select(0, cdk.Fn.getAzs('')),
      mapPublicIpOnLaunch: true,
      tags: [{ key: 'Name', value: 'MyECSSubnet1' }],
    });

    const subnet2 = new ec2.CfnSubnet(this, 'MySubnet2', {
      vpcId: vpc.ref,
      cidrBlock: '10.0.2.0/24',
      availabilityZone: cdk.Fn.select(1, cdk.Fn.getAzs('')),
      mapPublicIpOnLaunch: true,
      tags: [{ key: 'Name', value: 'MyECSSubnet2' }],
    });

    new ec2.CfnSubnetRouteTableAssociation(this, 'MySubnet1RouteTableAssoc', {
      subnetId: subnet1.ref,
      routeTableId: routeTable.ref,
    });

    new ec2.CfnSubnetRouteTableAssociation(this, 'MySubnet2RouteTableAssoc', {
      subnetId: subnet2.ref,
      routeTableId: routeTable.ref,
    });

    // -------------------------------------------------------------------------
    // IAM — instance role; EC2 assumes it so instances can register with ECS
    // and be accessed via SSM (no SSH / no key pair).
    // -------------------------------------------------------------------------

    const instanceRole = new iam.Role(this, 'ECSInstanceRole', {
      roleName: 'ECSInstanceRole',
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        // Allows the instance to register/deregister with ECS, pull task data, etc.
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          'service-role/AmazonEC2ContainerServiceforEC2Role',
        ),
        // SSM Session Manager — shell access without SSH or open port 22.
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    const instanceProfile = new iam.CfnInstanceProfile(this, 'ECSInstanceProfile', {
      roles: [instanceRole.roleName],
    });

    // -------------------------------------------------------------------------
    // ECS Cluster
    // -------------------------------------------------------------------------

    const cluster = new ecs.CfnCluster(this, 'MyECSCluster', {
      clusterName: 'MyECSCluster',
    });

    // -------------------------------------------------------------------------
    // Security Groups
    // Using L1 so we can reference the L1 VPC ref directly (no L2 VPC object).
    // -------------------------------------------------------------------------

    // ALB SG: accepts HTTP from the internet.
    const albSg = new ec2.CfnSecurityGroup(this, 'MyALBSecurityGroup', {
      groupDescription: 'Allow inbound HTTP from the internet to the ALB',
      vpcId: vpc.ref,
      securityGroupIngress: [
        {
          ipProtocol: 'tcp',
          fromPort: 80,
          toPort: 80,
          cidrIp: '0.0.0.0/0',
        },
      ],
    });

    // EC2 SG: port 80 from ALB SG only — direct internet access intentionally blocked.
    const ec2Sg = new ec2.CfnSecurityGroup(this, 'MyEC2SecurityGroup', {
      groupDescription: 'Allow HTTP from ALB only - no direct internet access to container port',
      vpcId: vpc.ref,
      securityGroupIngress: [
        {
          ipProtocol: 'tcp',
          fromPort: 80,
          toPort: 80,
          sourceSecurityGroupId: albSg.ref,
        },
      ],
    });

    // EFS SG: NFS (2049) from EC2 instances only.
    const efsSg = new ec2.CfnSecurityGroup(this, 'MyEFSSecurityGroup', {
      groupDescription: 'Allow NFS access to EFS from EC2 instances',
      vpcId: vpc.ref,
      securityGroupIngress: [
        {
          ipProtocol: 'tcp',
          fromPort: 2049,
          toPort: 2049,
          sourceSecurityGroupId: ec2Sg.ref,
        },
      ],
    });

    // -------------------------------------------------------------------------
    // EFS — encrypted, generalPurpose, one mount target per subnet/AZ.
    // Persistent storage for /ecs/logs across instance replacements.
    // Cost note: EFS standard storage ~$0.30/GB-month; negligible for log files.
    // -------------------------------------------------------------------------

    const efsFs = new efs.CfnFileSystem(this, 'MyEFSFileSystem', {
      encrypted: true,
      performanceMode: 'generalPurpose',
    });

    const efsMt1 = new efs.CfnMountTarget(this, 'MyEFSMountTarget1', {
      fileSystemId: efsFs.ref,
      subnetId: subnet1.ref,
      securityGroups: [efsSg.ref],
    });

    const efsMt2 = new efs.CfnMountTarget(this, 'MyEFSMountTarget2', {
      fileSystemId: efsFs.ref,
      subnetId: subnet2.ref,
      securityGroups: [efsSg.ref],
    });

    // -------------------------------------------------------------------------
    // CloudWatch Log Group — retains ECS agent / container logs.
    // -------------------------------------------------------------------------

    new logs.LogGroup(this, 'ECSLogGroup', {
      logGroupName: `/ecs/${cdk.Stack.of(this).stackName}`,
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // -------------------------------------------------------------------------
    // ALB — internet-facing, spans both public subnets.
    // Cost note: ALB ~$0.008/hr base + LCU charges (~$0.008/LCU-hr). ~$6-7/month.
    // -------------------------------------------------------------------------

    const alb = new elbv2.CfnLoadBalancer(this, 'MyALB', {
      type: 'application',
      scheme: 'internet-facing',
      securityGroups: [albSg.ref],
      subnets: [subnet1.ref, subnet2.ref],
    });

    // Target group in instance mode — correct for EC2 launch type with bridge networking.
    // ECS registers each EC2 instance + host port 80 automatically when tasks start.
    const targetGroup = new elbv2.CfnTargetGroup(this, 'MyTargetGroup', {
      vpcId: vpc.ref,
      protocol: 'HTTP',
      port: 80,
      targetType: 'instance', // bridge networking → register the instance, not the container IP
      healthCheckProtocol: 'HTTP',
      healthCheckPath: '/',
      healthCheckIntervalSeconds: 30,
      healthyThresholdCount: 2,
      unhealthyThresholdCount: 3,
      targetGroupAttributes: [
        // Default is 300s — reduced for faster task shutdown in dev clusters.
        { key: 'deregistration_delay.timeout_seconds', value: '30' },
      ],
    });

    // HTTP listener: all port 80 traffic → target group.
    const listener = new elbv2.CfnListener(this, 'MyListener', {
      loadBalancerArn: alb.ref,
      protocol: 'HTTP',
      port: 80,
      defaultActions: [
        {
          type: 'forward',
          targetGroupArn: targetGroup.ref,
        },
      ],
    });

    // -------------------------------------------------------------------------
    // LaunchTemplate — ECS-optimized AMI (deliberately old — AMI upgrade exercise).
    // ami-0dc67873410203528 = amzn2-ami-ecs-hvm-2.0.20240328 (starting point).
    // UserData is intentionally minimal: only writes /etc/ecs/ecs.config.
    // Do NOT call `systemctl start ecs` here — see system prompt RCA notes for why.
    // -------------------------------------------------------------------------

    const userData = cdk.Fn.base64(
      [
        '#!/bin/bash',
        '# Minimal UserData: only ECS cluster registration.',
        '# Do NOT call systemctl start ecs here: ecs.service has After=cloud-final.service,',
        '# so starting it from UserData (which runs inside cloud-final) causes a deadlock.',
        '# systemd will auto-start ecs after cloud-final completes.',
        'echo "ECS_CLUSTER=MyECSCluster" > /etc/ecs/ecs.config',
      ].join('\n'),
    );

    const launchTemplate = new ec2.CfnLaunchTemplate(this, 'MyLaunchTemplate', {
      launchTemplateData: {
        instanceType: 't3.small',
        // Deliberately old AMI — starting point for AMI rolling upgrade exercise.
        // To upgrade: change to ami-07bb74bad4a7a0b7a (amzn2-ami-ecs-hvm-2.0.20260323)
        // and run `cdk deploy` — the ASG rolling update policy handles the replacement.
        imageId: 'ami-0dc67873410203528',
        // NO KeyName — SSM Session Manager provides shell access without key pairs.
        iamInstanceProfile: { arn: instanceProfile.attrArn },
        securityGroupIds: [ec2Sg.ref],
        metadataOptions: {
          // IMDSv2 only — more secure than IMDSv1.
          httpTokens: 'required',
          // Default hop limit is 1; bridge-networked containers add an extra hop,
          // so IMDSv2 calls from inside containers would be dropped without this.
          httpPutResponseHopLimit: 2,
        },
        userData,
      },
    });

    // -------------------------------------------------------------------------
    // ASG — 2 instances across 2 AZs; rolling update (MaxBatchSize=1) so at least
    // 1 instance stays healthy during AMI upgrades.
    // Cost note: 2x t3.small = ~$0.0208/hr each = ~$0.042/hr total (~$30/month).
    // -------------------------------------------------------------------------

    const asg = new autoscaling.CfnAutoScalingGroup(this, 'MyASG', {
      minSize: '2',
      // MaxSize 3 temporarily allows the extra replacement instance during a rolling upgrade.
      maxSize: '3',
      desiredCapacity: '2',
      launchTemplate: {
        launchTemplateId: launchTemplate.ref,
        version: launchTemplate.attrLatestVersionNumber,
      },
      vpcZoneIdentifier: [subnet1.ref, subnet2.ref],
    });

    // Rolling update policy: replace one instance at a time; keep >=1 running.
    (asg as any).cfnOptions.updatePolicy = {
      AutoScalingRollingUpdate: {
        MaxBatchSize: 1,
        MinInstancesInService: 1,
        PauseTime: 'PT2M',
      },
    };

    // ASG must wait for EFS mount targets — instances need NFS reachable at boot.
    asg.addDependency(efsMt1);
    asg.addDependency(efsMt2);

    // -------------------------------------------------------------------------
    // SSM State Manager Association — installs amazon-efs-utils and mounts EFS.
    // Runs on every instance ~60s after boot via SSM agent. Keeping this out of
    // UserData keeps UserData minimal and makes the setup step re-runnable/auditable.
    // Target: all instances in this stack (by cloudformation:stack-name tag).
    // -------------------------------------------------------------------------

    const efsSetupAssoc = new ssm.CfnAssociation(this, 'MyEFSSetupAssociation', {
      associationName: `${cdk.Stack.of(this).stackName}-efs-setup`,
      name: 'AWS-RunShellScript',
      targets: [
        {
          key: 'tag:aws:cloudformation:stack-name',
          values: [cdk.Stack.of(this).stackName],
        },
      ],
      parameters: {
        commands: [
          'yum install -y amazon-efs-utils',
          'mkdir -p /ecs/logs',
          // grep -q before append keeps the script idempotent on re-runs.
          `grep -q "${efsFs.ref}" /etc/fstab || echo "${efsFs.ref}:/ /ecs/logs efs defaults,_netdev,nofail 0 0" >> /etc/fstab`,
          'mount -a || echo "EFS mount failed - will retry on reconnect (nofail set)"',
          'mkdir -p /ecs/logs/nginx /ecs/logs/data',
        ],
      },
      waitForSuccessTimeoutSeconds: 300,
    });

    efsSetupAssoc.addDependency(asg);

    // -------------------------------------------------------------------------
    // ECS Task Definition — bridge networking, 1 task per instance (HostPort 80).
    // HostPort is fixed (not 0) because we have exactly 1 task per EC2 instance
    // and the ALB target group registers instances on port 80 in instance mode.
    // -------------------------------------------------------------------------

    const taskDef = new ecs.CfnTaskDefinition(this, 'MyTaskDefinition', {
      family: 'hello-world-task',
      networkMode: 'bridge',
      volumes: [
        {
          name: 'efs-data',
          host: {
            // EFS-backed via SSM association above — shared across all instances.
            sourcePath: '/ecs/logs/data',
          },
        },
      ],
      containerDefinitions: [
        {
          name: 'hello-world-container',
          image: props.appImage,
          memory: 256,
          cpu: 256,
          essential: true,
          environment: [
            { name: 'PORT', value: '3000' },
            // DATA_FILE points to the EFS mount — both containers read/write same file.
            { name: 'DATA_FILE', value: '/data/records.json' },
          ],
          portMappings: [
            {
              // ALB target group registers instance:80; host maps 80 → container 3000.
              containerPort: 3000,
              hostPort: 80,
              protocol: 'tcp',
            },
          ],
          mountPoints: [
            {
              sourceVolume: 'efs-data',
              containerPath: '/data',
              readOnly: false,
            },
          ],
          stopTimeout: 10,
        },
      ],
    });

    // -------------------------------------------------------------------------
    // ECS Service — 2 tasks spread across 2 EC2 instances, registered with ALB.
    // DeploymentConfiguration mirrors the CF template: stop 1 task at a time,
    // never exceed desired count (prevents two tasks competing for HostPort 80).
    // -------------------------------------------------------------------------

    const ecsService = new ecs.CfnService(this, 'MyService', {
      cluster: cluster.ref,
      desiredCount: 2,
      taskDefinition: taskDef.ref,
      launchType: 'EC2',
      // Gives the container time to start before ALB health checks count.
      healthCheckGracePeriodSeconds: 60,
      deploymentConfiguration: {
        // Stop 1 of 2 tasks at a time — frees HostPort 80 on that instance.
        minimumHealthyPercent: 50,
        // Never run old + new tasks together — prevents HostPort 80 conflict.
        maximumPercent: 100,
      },
      loadBalancers: [
        {
          containerName: 'hello-world-container',
          containerPort: 3000,
          targetGroupArn: targetGroup.ref,
        },
      ],
      placementStrategies: [
        {
          // Spread across instances — 1 task per EC2, so ALB sees both instances.
          type: 'spread',
          field: 'instanceId',
        },
      ],
    });

    // ECS service needs the listener before it can register tasks with the target group.
    ecsService.addDependency(listener);
    ecsService.addDependency(asg);

    // -------------------------------------------------------------------------
    // Outputs — mirrors CF template Outputs section
    // -------------------------------------------------------------------------

    new cdk.CfnOutput(this, 'ALBDNSName', {
      description: 'ALB DNS name — open in a browser or use with curl to validate round-robin',
      value: cdk.Fn.sub('http://${DNS}', { DNS: alb.attrDnsName }),
    });

    new cdk.CfnOutput(this, 'ClusterName', {
      description: 'Name of the ECS Cluster',
      value: cluster.ref,
    });

    new cdk.CfnOutput(this, 'EFSFileSystemId', {
      description: 'EFS File System ID (logs persist here across instance replacements)',
      value: efsFs.ref,
    });

    new cdk.CfnOutput(this, 'ASGName', {
      description: 'Auto Scaling Group name',
      value: asg.ref,
    });

    new cdk.CfnOutput(this, 'TaskDefinitionArn', {
      description: 'ARN of the Task Definition',
      value: taskDef.ref,
    });

    new cdk.CfnOutput(this, 'ServiceName', {
      description: 'Name of the ECS Service',
      value: ecsService.ref,
    });
  }
}
