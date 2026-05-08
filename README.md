# EC2 Mac Jamf Enrollment AMI - POC Scripts (v2)

Scripts for the headless AMI staging flow. **All passwords pull from AWS
Secrets Manager via stdin pipes — no passwords in argv, env vars, shell
variables (longer than necessary), or shell history.**

This is the CWE-798 remediation pass over the v1 scripts.

## Files

| Script | Purpose | Where to run | Runbook Step |
|---|---|---|---|
| `disable-sip.sh` | Disable SIP via AWS API, password from Secrets Manager | CloudShell | Step 2 |
| `set-password.sh` | Set ec2-user password and enable secure token | Mac via SSH | Step 1 (replaces manual commands) |
| `configure-autologin.sh` | Configure auto-login via `sysadminctl` (macOS 13+) | Mac via SSH | Step 3 |
| `setup-tcc.sh` | Pre-grant TCC permissions for osascript | Mac via SSH | Step 5 |
| `install-cliclick.sh` | Install cliclick via Homebrew | Mac via SSH | Step 6 |

All scripts are idempotent.

## Prerequisites

The following must already exist before any script runs:

- AWS Secrets Manager secret named `mdmSecret` in your region with these keys:
  - `mdmServerDomain` (Jamf URL, no `https://`)
  - `mdmEnrollmentUser`
  - `mdmEnrollmentPassword`
  - `localAdmin` (= `ec2-user`)
  - `localAdminPassword`
- IAM instance profile attached to the EC2 Mac with `secretsmanager:GetSecretValue` on `mdmSecret`

## How passwords flow

```
AWS Secrets Manager
       │
       ▼
   aws secretsmanager get-secret-value
       │  (json on stdout)
       ▼
   python3 -c "json.load(...)['localAdminPassword']"
       │  (just the password on stdout)
       ▼
   sudo sysadminctl ... -password -    (or dscl ... -passwd, etc.)
       │
       ▼
   macOS authorization framework
```

Password is never in argv, env, or shell history. Lives momentarily in
the Python interpreter's memory and the consuming command's stdin buffer.

## Order of operations

### In AWS CloudShell

```
./disable-sip.sh <instance-id>
```

Wait up to 2.5 hours for SIP disable task to complete (see runbook Step 2 for monitoring command).

### On the Mac via SSH

```
./set-password.sh
./configure-autologin.sh
sudo reboot
# wait ~1 minute, SSH back in
./setup-tcc.sh
./install-cliclick.sh
# continue with runbook Steps 7-12
```

## Delivery to the Mac

From your laptop:

```
scp -i your-key.pem *.sh ec2-user@<mac-ip>:/tmp/
ssh -i your-key.pem ec2-user@<mac-ip> "chmod +x /tmp/*.sh"
```

## Region detection

On the Mac: scripts read region from instance metadata (IMDSv2). No hardcoded region.
In CloudShell: scripts read region from `AWS_REGION` env var, falling back to `us-east-2`.

## Known residual exposure

`enroll-ec2-mac.scpt` (the AWS-provided enrollment script) holds the
`localAdminPassword` in the AppleScript runtime's memory throughout
enrollment, used in many `do shell script ... user name X password Y
with administrator privileges` calls. This is unchanged from the AWS
sample. The `prodFlag=1` cleanup wipes derived state (TCC, autologin,
MMSecret) after enrollment completes.

Eliminating this exposure would require modifying the AWS-provided
script — out of scope for POC.

## Run as ec2-user, never sudo

Each script self-elevates with `sudo` for the specific commands that need
root. Running these with `sudo` at the top level will break things (Homebrew
refuses, user TCC.db ends up wrong, etc.).
