# EC2 Mac Jamf Enrollment AMI — Headless Build

Fully headless AMI staging flow for EC2 Mac instances. Passwords pull from AWS Secrets Manager — never in argv, env vars, shell history, or on disk longer than necessary.

## Scripts

| Script | Purpose | Where it runs |
|---|---|---|
| `setup-user.sh` | Set password, enable Secure Token, configure auto-login | Mac via SSH as ec2-user |
| `setup-user-userdata.sh` | Same as above for User Data — experimental, not currently used | EC2 Launch Wizard |
| `disable-sip.sh` | Disable SIP via AWS API, password from Secrets Manager | AWS CloudShell |
| `stage-enrollment.sh` | TCC injection, cliclick, place enroll-ec2-mac.scpt, install LaunchAgent, ec2-macos-init config | Mac via SSH as ec2-user |

> **Note:** `setup-user-userdata.sh` (User Data approach) has known issues — under certain reboot conditions ec2-macos-init re-runs the user data and disrupts the user account state. Current workflow uses `setup-user.sh` via SSH for reliability.

## Prerequisites

- AWS Secrets Manager secret named `mdmSecret` with keys:
  - `mdmServerDomain` — Jamf server URL (no `https://`)
  - `mdmEnrollmentUser`
  - `mdmEnrollmentPassword`
  - `localAdmin` — `ec2-user`
  - `localAdminPassword` — strong random password
- IAM instance profile with `secretsmanager:GetSecretValue` on the `mdmSecret` ARN
- EC2 Mac dedicated host (minimum 24 hour allocation)
- Key pair for SSH access

## Order of Operations

### Step 1 — Launch the staging instance

In the EC2 Launch Wizard:
- Choose a vanilla AWS macOS AMI
- Attach the IAM instance profile
- **Leave User Data blank**
- Set **Metadata version** to `V2 only (token required)`
- Launch

Wait for status checks to pass (~6–20 min).

### Step 2 — Run setup-user.sh via SSH

```bash
scp -i your-key.pem setup-user.sh ec2-user@<instance-ip>:/tmp/
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x /tmp/setup-user.sh
/tmp/setup-user.sh
```

Sets ec2-user's password (from `mdmSecret.localAdminPassword`), enables Secure Token, configures auto-login.

### Step 3 — Disable SIP from CloudShell

```bash
nano disable-sip.sh
# Paste contents, save (Ctrl+O, Enter, Ctrl+X)
chmod +x disable-sip.sh
./disable-sip.sh <instance-id>
```

Monitor:
```bash
aws ec2 describe-mac-modification-tasks \
  --mac-modification-task-ids <task-id> \
  --region us-east-2 \
  --query 'MacModificationTasks[0].TaskState' --output text
```

Plan for up to 2.5 hours. Instance reboots multiple times. When state shows `successful`, wait a few minutes for the final boot before SSHing in.

### Step 4 — Run stage-enrollment.sh

```bash
scp -i your-key.pem stage-enrollment.sh ec2-user@<instance-ip>:/tmp/
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x /tmp/stage-enrollment.sh
/tmp/stage-enrollment.sh
```

This:
- Pre-grants TCC permissions for osascript (no GUI to click "Allow")
- Installs cliclick (the enrollment script depends on it)
- Downloads `enroll-ec2-mac.scpt` from the AWS sample repo to `/Users/Shared/`
- Sets `MMSecret` and `prodFlag` defaults
- Installs the LaunchAgent (osascript runs directly via launchd)
- Sets `RandomizePassword = false` in `ec2-macos-init/init.toml`
- Clears ec2-macos-init instance history (fresh AMI instances boot like first launch)

### Step 5 — Snapshot the AMI

Create an AMI in the EC2 console with **No reboot** selected. Wait for AMI state `available` and snapshot `Progress: 100%` before launching test instances.

## What happens on instances launched from the AMI

1. Instance boots, SIP enabled by default (firmware-level, not on EBS)
2. ec2-macos-init runs fresh — injects SSH keys, skips password randomization
3. Auto-login fires for ec2-user
4. LaunchAgent runs `osascript /Users/Shared/enroll-ec2-mac.scpt`
5. Script retrieves credentials from Secrets Manager
6. Profile downloads, System Settings opens to Device Management
7. Profile installs, password prompt is auto-filled
8. `prodFlag=1` cleanup removes LaunchAgent, defaults, cliclick, and TCC entries

**Important:** The IAM instance profile must be attached when launching from the AMI.

## Troubleshooting

After an AMI test instance boots, SSH in and run:

```bash
echo "=== ENROLLMENT ===" && profiles status -type enrollment && \
echo && echo "=== DEFAULTS ===" && defaults read com.amazon.dsx.ec2.enrollment.automation 2>/dev/null || echo "cleaned (good)" && \
echo && echo "=== LAUNCHAGENT ===" && ls /Library/LaunchAgents/com.amazon.dsx.ec2.enrollment.automation.startup.plist 2>/dev/null || echo "removed (good)" && \
echo && echo "=== MMOutput.log ===" && cat /tmp/MMOutput.log 2>/dev/null || echo "empty" && \
echo && echo "=== MMErrors.log ===" && cat /tmp/MMErrors.log 2>/dev/null || echo "empty"
```

### Success looks like

- `MDM enrollment: Yes (User Approved)`
- DEFAULTS: cleaned
- LAUNCHAGENT: removed
- MMErrors.log: only `macOS 26` (informational, not an error)

### Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `MDM enrollment: No`, `NoCredentials` in MMErrors.log | IAM instance profile not attached | Attach in EC2 console: Actions → Security → Modify IAM role |
| `AccessDeniedException` on `secretsmanager:GetSecretValue` | IAM policy missing or wrong secret ARN | Update IAM policy with correct `mdmSecret` ARN |
| `MDM enrollment: No`, LaunchAgent still present | Enrollment failed mid-flow | Check MMErrors.log for the specific error |
| Script appears stuck (osascript running 5+ minutes, no progress) | GUI navigation hung | Use visual debugging below |

### Force-retrigger enrollment

If the LaunchAgent didn't fire or you want to retry:

```bash
launchctl bootout gui/$(id -u) /Library/LaunchAgents/com.amazon.dsx.ec2.enrollment.automation.startup.plist 2>/dev/null
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.amazon.dsx.ec2.enrollment.automation.startup.plist
```

### Visual debugging via VNC

Enable screen sharing on the instance:

```bash
sudo launchctl enable system/com.apple.screensharing
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

From your local Mac:

```bash
ssh -L 5900:localhost:5900 -i your-key.pem ec2-user@<instance-ip>
```

Then Finder → ⌘K → `vnc://localhost` — log in as `ec2-user` with the `localAdminPassword` from `mdmSecret`.

## Verify AMI is ready before launching

```bash
aws ec2 describe-images --owners self \
  --query 'Images[*].{ID:ImageId,Name:Name,State:State,Created:CreationDate}' --output table

aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=description,Values=*<ami-id>*" \
  --query 'Snapshots[*].{ID:SnapshotId,State:State,Progress:Progress}' --output table
```

Both `State: available` and `Progress: 100%` must be true.

## Security notes

- Passwords never appear in argv, env vars, or shell history
- `stage-enrollment.sh` runs as ec2-user — do not run as root (Homebrew refuses, user TCC.db ends up wrong)
- `disable-sip.sh` writes credentials to a `0600` temp file and shreds it immediately after use
- `enroll-ec2-mac.scpt` holds `localAdminPassword` in AppleScript runtime memory during enrollment — unchanged from AWS sample, out of scope to modify
