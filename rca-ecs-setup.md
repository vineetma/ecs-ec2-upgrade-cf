# RCA — ECS Cluster Setup Failures

Date: 2026-03-27
Stack: `my-ecs-stack` (`cf/ecs-ec2-multi-node-cf.yaml`)

---

## Summary

Three separate root causes blocked the ECS cluster from registering container instances. Each required a different fix. All three needed to be resolved before the ECS service could place tasks.

---

## Issue 1 — AMI Deregistered by AWS

**Symptom:** `MyASG CREATE_FAILED` — AMI ID does not exist.

**Root cause:** The AMI ID hardcoded in `MyLaunchTemplate` (`ami-0c55b159cbfafe1f0`) had been deregistered by AWS. AWS retires old AMIs over time. Any stack using a hardcoded, old AMI ID will fail to launch instances.

**Fix:** Queried for the oldest currently-available ECS-optimized AL2 AMI and updated the template:

```bash
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-ecs-hvm-*-x86_64-ebs" \
  --query "sort_by(Images, &CreationDate)[*].{Name:Name,ImageId:ImageId,CreationDate:CreationDate}" \
  --region us-east-1 --output table
```

**Lesson:** AMI IDs are not permanent. Always verify an AMI exists before using it in a template. For production, use SSM Parameter Store (`/aws/service/ecs/optimized-ami/...`) to auto-resolve the latest AMI.

---

## Issue 2 — ECS Agent Not Installed on Standard AL2 AMI

**Symptom:** ECS service reported "no container instances in cluster" after stack deployed successfully.

**Root cause:** The initial template used a plain Amazon Linux 2 AMI. UserData attempted to install the ECS agent via `yum install -y amazon-ecs-init`, but that package is not available in the default AL2 yum repositories without additional repo configuration. The install silently failed with `No package amazon-ecs-init available`, so no ECS agent was ever running on the instances.

**Evidence from `/var/log/userdata.log`:**
```
No package amazon-ecs-init available.
Error: Nothing to do
Failed to start ecs.service: Unit not found.
```

**Fix:** Switched to **ECS-optimized AMIs** (`amzn2-ami-ecs-hvm-*-x86_64-ebs`). These AMIs have:
- `amazon-ecs-init` pre-installed at `/usr/libexec/amazon-ecs-init`
- `ecs.service` systemd unit pre-configured
- Docker pre-installed

UserData was simplified to only writing the cluster config — no installation needed:

```bash
echo "ECS_CLUSTER=MyECSCluster" > /etc/ecs/ecs.config
```

**Lesson:** Never install the ECS agent in UserData on a standard AMI when ECS-optimized AMIs exist. ECS-optimized AMIs are purpose-built for this and eliminate the installation problem entirely.

---

## Issue 3 — `systemctl start ecs` Deadlock in UserData

**Symptom:** After switching to ECS-optimized AMI, `systemctl start ecs` in UserData hung for several minutes. ECS agent remained `inactive (dead)`. No entries in `journalctl -u ecs`.

**Root cause:** A systemd ordering deadlock.

The `ecs.service` unit file contains:
```
After=cloud-final.service
```

UserData runs inside `cloud-final.service`. When UserData called `systemctl start ecs`, systemd refused to start `ecs.service` until `cloud-final.service` completed — but `cloud-final.service` could not complete because UserData was blocked waiting for `ecs.service` to start.

```
cloud-final.service (UserData running)
  └─ calls systemctl start ecs
        └─ systemd: "ecs must start After cloud-final"
              └─ waits for cloud-final to finish
                    └─ DEADLOCK
```

The same deadlock occurred when `systemctl restart ecs` was called in the original UserData. Even manual `systemctl start ecs` from an SSM session hung — because `cloud-final.service` was still marked as active (stuck), so the `After=` constraint was still blocking systemd from starting `ecs.service`.

**Diagnosis steps:**
1. `systemctl status ecs` → `inactive (dead)`, no journal entries
2. `journalctl -u ecs` → `-- No entries --` (service never ran)
3. `ls -la /usr/libexec/amazon-ecs-init` → binary exists, not a missing file problem
4. `curl https://ecs.us-east-1.amazonaws.com` → reachable, not a network problem
5. `cat /var/log/userdata.log` → empty (UserData froze before producing any output)
6. Read `/usr/lib/systemd/system/ecs.service` → revealed `After=cloud-final.service`

**Fix:** Removed all `systemctl` calls from UserData. The ECS service is already `enabled` (`WantedBy=multi-user.target`). systemd starts it automatically after `cloud-final.service` completes — at which point `/etc/ecs/ecs.config` is already written.

Final UserData (minimal):
```bash
#!/bin/bash
exec > >(tee /var/log/userdata.log) 2>&1
echo "ECS_CLUSTER=MyECSCluster" > /etc/ecs/ecs.config
# Mount EFS
yum install -y amazon-efs-utils
mkdir -p /ecs/logs/nginx
echo "${MyEFSFileSystem}:/ /ecs/logs efs defaults,_netdev,nofail 0 0" >> /etc/fstab
mount -a || echo "EFS mount failed — will retry on reconnect (nofail set)"
```

**Lesson:** Never call `systemctl start` on a service that has `After=cloud-final.service` from within UserData. Check the service unit file before adding lifecycle calls to UserData.

---

## Bonus — EFS DNS Resolution Failure on First Boot

**Symptom:** EFS mount failed at boot with DNS resolution error. UserData exited non-zero, blocking ECS registration in early iterations.

**Root cause:** EFS DNS (`fs-xxx.efs.us-east-1.amazonaws.com`) was not resolvable at the exact moment UserData executed the `mount -a` command — the EFS mount targets were still initialising.

**Fix:** Added `nofail` to the fstab entry and `|| echo` to prevent non-zero UserData exit:
```bash
echo "${EFSFileSystemId}:/ /ecs/logs efs defaults,_netdev,nofail 0 0" >> /etc/fstab
mount -a || echo "EFS mount failed — will retry on reconnect (nofail set)"
```

`nofail` means a mount failure at boot does not block the rest of the boot process. The mount retries automatically when connectivity is established.

---

## Timeline of Changes

| Change | Effect |
|---|---|
| Updated AMI from deregistered `ami-0c55b159cbfafe1f0` to available `ami-0fcb14c72c80bdef2` | Unblocked ASG instance launch |
| Added `nofail` to EFS fstab | Prevented EFS DNS failure from blocking UserData |
| Switched to ECS-optimized AMI `ami-0dc67873410203528` | Eliminated need to install ECS agent in UserData |
| Removed `systemctl start/restart ecs` from UserData | Resolved `After=cloud-final.service` deadlock |
