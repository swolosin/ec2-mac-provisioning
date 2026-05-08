# EC2 Mac Jamf Enrollment AMI — Headless Build

Fully headless AMI staging flow for EC2 Mac instances. Passwords pull from AWS Secrets Manager — never in argv, env vars, shell history, or on disk longer than necessary.

## Scripts

| Script | Purpose | Where it runs |
|---|---|---|
| `setup-user-userdata.sh` | Set password, enable Secure Token, configure auto-login | EC2 Launch Wizard (User Data) — runs as root |
| `setup-user.sh` | Same as above but for SSH — backup/testing only | Mac via SSH as ec2-user |
| `disable-sip.sh` | Disable SIP via AWS API, password from Secrets Manager | AWS CloudShell |
| `stage-enrollment.sh` | TCC injection, cliclick, enrollment script, LaunchAgent, ec2-macos-init config | Mac via SSH as ec2-user |

## Prerequisites

- AWS Secrets Manager secret named `mdmSecret` with these keys:
  - `mdmServerDomain` — Jamf server URL (no `https://`)
  - `mdmEnrollmentUser`
  - `mdmEnrollmentPassword`
  - `localAdmin` — `ec2-user`
  - `localAdminPassword` — strong random password
- IAM instance profile attached to the EC2 Mac with `secretsmanager:GetSecretValue` on `mdmSecret`
- EC2 Mac dedicated host (minimum 24 hour allocation)
- Key pair for SSH access

## Order of Operations

### Step 1 — Launch the staging instance

In the EC2 Launch Wizard:
- Choose a vanilla AWS macOS AMI
- Attach the IAM instance profile
- Under **Advanced Details → User Data**, paste the contents of `setup-user-userdata.sh`
- Set **Metadata version** to `V2 only (token required)`
- Launch

Wait for the instance to pass status checks (~6-20 min). The user data script will set the password, enable Secure Token, and configure auto-login automatically.

### Step 2 — Disable SIP from CloudShell

In AWS CloudShell, create the script with nano:

```bash
nano disable-sip.sh
```

Paste the contents of `disable-sip.sh`, then save (`Ctrl+O`, `Enter`, `Ctrl+X`). Make it executable and run it:

```bash
chmod +x disable-sip.sh
./disable-sip.sh <instance-id>
```

Monitor progress:

```bash
aws ec2 describe-mac-modification-tasks \
  --mac-modification-task-ids <task-id> \
  --region us-east-2 \
  --query 'MacModificationTasks[0].TaskState' \
  --output text
```

Plan for up to 2.5 hours. The instance will go through multiple reboots. When the task state shows `successful`, wait a few more minutes for the final boot to complete before SSHing in.

### Step 3 — Run stage-enrollment.sh

Copy the script to the instance and run it:

```bash
scp -i your-key.pem stage-enrollment.sh ec2-user@<instance-ip>:/tmp/
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x /tmp/stage-enrollment.sh
/tmp/stage-enrollment.sh
```

This script handles everything in one run:
- Injects TCC permissions for osascript (Accessibility + AppleEvents)
- Installs cliclick via Homebrew
- Downloads `enroll-ec2-mac.scpt` from the AWS sample repo
- Sets MMSecret
- Installs the LaunchAgent
- Sets `RandomizePassword = false` in ec2-macos-init config
- Clears ec2-macos-init instance history

### Step 4 — Take the AMI snapshot

Once `stage-enrollment.sh` completes successfully, create an AMI from the running instance in the EC2 console. **No reboot required** — use "No reboot" option.

Wait for the AMI status to show `available` and the backing snapshot to show `completed` at `100%`.

## What happens on instances launched from the AMI

1. AWS re-enables SIP (multiple reboots, up to 90 min)
2. ec2-macos-init runs fresh — `ManageEC2User` skips password randomization (`RandomizePassword = false`), SSH keys are injected, user data runs if specified
3. Auto-login fires for ec2-user
4. LaunchAgent triggers `enroll-ec2-mac.scpt`
5. Instance enrolls into Jamf automatically

## Testing / SSH fallback

If you need to set up a staging instance manually via SSH instead of user data:

```bash
scp -i your-key.pem setup-user.sh ec2-user@<instance-ip>:/tmp/
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x /tmp/setup-user.sh
/tmp/setup-user.sh
```

Then proceed with Steps 2-4 above.

## Verify AMI is ready before launching

```bash
# Check AMI state
aws ec2 describe-images --owners self \
  --query 'Images[*].{ID:ImageId,Name:Name,State:State,Created:CreationDate}' \
  --output table

# Check backing snapshot
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=description,Values=*<ami-id>*" \
  --query 'Snapshots[*].{ID:SnapshotId,State:State,Progress:Progress}' \
  --output table
```

Both `State: available` and `Progress: 100%` must be true before launching.

## Security notes

- Passwords never appear in argv, env vars, or shell history
- `setup-user-userdata.sh` runs as root via user data — no sudo needed
- `stage-enrollment.sh` runs as ec2-user — do not run as root (Homebrew refuses, user TCC.db ends up wrong)
- `disable-sip.sh` writes credentials to a `0600` temp file and shreds it immediately after use
- `enroll-ec2-mac.scpt` holds `localAdminPassword` in AppleScript runtime memory during enrollment — this is unchanged from the AWS sample and is out of scope to modify
