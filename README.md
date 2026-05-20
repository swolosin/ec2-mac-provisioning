# JPMC EC2 Mac — Headless MDM Enrollment

Fully headless, automated Jamf MDM enrollment for EC2 Mac instances. Instances launched from the AMI enroll automatically at first GUI login with no human interaction required.

> **Origin:** This workflow was inspired by and built upon the AWS sample script `enroll-ec2-mac.scpt` (see `EC2_AWS_Build/`). The JPMC implementation rewrites the enrollment logic with IMDS retry, macOS 26 Tahoe support, persistent logging, cliclick fallback with retry, and machine-readable status output for downstream AWS automation.

---

## Repository Structure

```
/
├── JPMC-setup-user.sh           # Step 1 — run via SSH on new instance
├── JPMC-stage-enrollment.sh     # Step 3 — run via SSH after SIP disable
├── JPMC-EC2-Enroll.applescript  # Compiled and installed by stage script
└── EC2_AWS_Build/               # Original AWS scripts (reference only)
```

---

## How It Works

### Architecture Flow

```
New EC2 Mac Instance
        │
        ▼
JPMC-setup-user.sh (SSH)
  • Retrieves credentials from Secrets Manager
  • Sets ec2-user password + Secure Token
  • Configures auto-login
  • Disables screen saver (prevents lock before enrollment)
  • Creates /private/var/db/locationd (required by Jamf binary)
        │
        ▼
disable-sip.sh (CloudShell) ──── AWS API ────► Instance reboots (~2.5 hrs)
        │
        ▼
JPMC-stage-enrollment.sh (SSH)
  • Creates /Library/Logs/JPMC/ (persistent log directory)
  • Injects TCC permissions (Accessibility + AppleEvents) into SQLite
  • Installs cliclick via Homebrew, caches to /Users/Shared/._jpmc-tools/
  • Downloads JPMC-EC2-Enroll.applescript from GitHub, compiles to .scpt
  • Writes MMSecret + prodFlag to defaults
  • Installs LaunchAgent (com.jpmc.ec2.mdm.enrollment)
  • Disables RandomizePassword in ec2-macos-init
  • Clears ec2-macos-init instance history
        │
        ▼
   Snapshot AMI
        │
        ▼
Instance launched from AMI
        │
        ▼
  ec2-macos-init runs
  • Injects SSH keys
  • Skips password randomization
        │
        ▼
  Auto-login fires (ec2-user)
        │
        ▼
  LaunchAgent fires → osascript JPMC-EC2-Enroll.scpt
        │
        ▼
  JPMC-EC2-Enroll.scpt
  • Reads MMSecret from defaults
  • Gets region from IMDS (6 retries, fixes boot-time timing failure)
  • Retrieves all credentials from Secrets Manager
  • Authenticates with Jamf Pro (OAuth, falls back to Basic)
  • Creates enrollment invitation via Jamf API
  • Builds .mobileconfig profile
  • Opens profile → presses Return on "Profile Downloaded" popup
  • Navigates to Device Management via URL scheme + reveal pane id
  • Finds MDM Profile row by name, double-clicks with cliclick (5 retries)
  • Clicks Install → enters admin password into SecurityAgent
  • Polls for enrollment confirmation (up to 5 minutes)
  • Enables screen sharing
  • Writes ENROLLMENT_STATUS JSON to log
  • Runs cleanup if prodFlag = 1
        │
        ▼
  MDM enrollment: Yes (User Approved)
```

---

## Prerequisites

**AWS Secrets Manager** secret named `mdmSecret` with keys:
| Key | Value |
|---|---|
| `mdmServerDomain` | Jamf server URL (no `https://`) |
| `mdmEnrollmentUser` | Jamf API client ID |
| `mdmEnrollmentPassword` | Jamf API client secret |
| `localAdmin` | `ec2-user` |
| `localAdminPassword` | Strong random password |

**IAM instance profile** with `secretsmanager:GetSecretValue` on the `mdmSecret` ARN.

**EC2 Mac dedicated host** (minimum 24-hour allocation, mac2.metal recommended).

---

## Order of Operations

### Step 1 — Launch the staging instance

In the EC2 Launch Wizard:
- Choose a vanilla AWS macOS AMI
- Attach the IAM instance profile
- **Leave User Data blank**
- Set Metadata version to `V2 only (token required)`
- Launch and wait for status checks (~6–20 min)

### Step 2 — Run JPMC-setup-user.sh via SSH

```bash
scp -i key.pem JPMC-setup-user.sh ec2-user@<ip>:/tmp/
ssh -i key.pem ec2-user@<ip>
chmod +x /tmp/JPMC-setup-user.sh && /tmp/JPMC-setup-user.sh
```

**What it does:** Sets password, enables Secure Token (required for SIP disable API), configures auto-login, disables screen saver on both `-currentHost` and user domain, creates `/private/var/db/locationd`.

**Verify success:**
- `Secure token is ENABLED for user ec2-user`
- `autoLoginUser: ec2-user`
- `/etc/kcpassword: present`
- `screensaver idleTime: 0` (both domains)

### Step 3 — Disable SIP from CloudShell

```bash
chmod +x disable-sip.sh
./EC2_AWS_Build/disable-sip.sh <instance-id>
```

Monitor status:
```bash
aws ec2 describe-mac-modification-tasks \
  --mac-modification-task-ids <task-id> \
  --region us-east-2 \
  --query 'MacModificationTasks[0].TaskState' --output text
```

Plan for up to 2.5 hours. Instance reboots multiple times. When state shows `successful`, wait a few minutes before SSHing back in.

### Step 4 — Run JPMC-stage-enrollment.sh via SSH

```bash
scp -i key.pem JPMC-stage-enrollment.sh ec2-user@<ip>:/tmp/
ssh -i key.pem ec2-user@<ip>
chmod +x /tmp/JPMC-stage-enrollment.sh && /tmp/JPMC-stage-enrollment.sh
```

**Preflight gate checks:**
- `JPMC-EC2-Enroll.scpt: OK`
- `MMSecret: OK`
- `cliclick: OK`

### Step 5 — Snapshot the AMI

Create AMI in EC2 console with **No reboot** selected. Wait for:
- AMI State: `available`
- Snapshot Progress: `100%`

```bash
aws ec2 describe-images --owners self \
  --query 'Images[*].{ID:ImageId,Name:Name,State:State}' --output table
```

### Step 6 — Launch test instance from AMI

- Attach IAM instance profile
- Wait for boot, auto-login fires, LaunchAgent runs
- Enrollment completes automatically (~30–60 seconds after GUI login)

---

## Environment Configuration

All environment-specific settings are at the top of `JPMC-stage-enrollment.sh`:

```bash
readonly SECRET_ID="mdmSecret"      # AWS Secrets Manager secret name
readonly PROD_FLAG="0"              # Set to "1" when ready for production cleanup
readonly ENROLL_SOURCE_URL="..."    # URL to JPMC-EC2-Enroll.applescript
readonly CLICLICK_SOURCE="brew"     # "brew" or direct URL for internal Artifactory/Bitbucket
```

The AppleScript never needs to be modified per environment — it reads everything from defaults written by the stage script.

---

## Verifying Enrollment

SSH into the instance after boot and run:

```bash
echo "=== ENROLLMENT ===" && profiles status -type enrollment && \
echo "" && \
echo "=== LOG ===" && cat /Library/Logs/JPMC/EC2-Enroll.log && \
echo "" && \
echo "=== LAUNCHAGENT ===" && ls /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist 2>/dev/null || echo "removed (prodFlag=1)" && \
echo "" && \
echo "=== DEFAULTS ===" && defaults read com.jpmc.ec2.mdm.enrollment 2>/dev/null || echo "cleaned (prodFlag=1)"
```

### Success looks like

```
MDM enrollment: Yes (User Approved)
MDM server: https://your-jamf-server.jamfcloud.com/mdm/ServerURL
```

And at the end of `/Library/Logs/JPMC/EC2-Enroll.log`:
```
ENROLLMENT_STATUS: {"status":"SUCCESS","instance":"i-xxx","region":"us-east-2","mdm":"https://...","action":"none"}
```

### Failure looks like

```
MDM enrollment: No
```

And at the end of the log:
```
ENROLLMENT_STATUS: {"status":"FAILED","instance":"i-xxx","region":"us-east-2","reason":"enrollment did not complete within 5 minutes","action":"terminate_and_rebuild"}
```

---

## Log Files

All logs are written to `/Library/Logs/JPMC/` which persists across reboots and is not cleared by macOS `/tmp` cleanup.

| File | Contents |
|---|---|
| `/Library/Logs/JPMC/EC2-Enroll.log` | Full timestamped enrollment log (main log) |
| `/Library/Logs/JPMC/EC2-Enroll-out.log` | stdout from LaunchAgent (typically empty) |

Every log entry is timestamped:
```
2026-05-19 17:52:28  === JPMC-EC2-Enroll started | macOS 26 ===
2026-05-19 17:52:28  IMDS ok (attempt 1/6): placement/region = us-east-2
2026-05-19 17:52:45  Tahoe: MDM Profile found by name at row 2
2026-05-19 17:52:53  Row click succeeded on attempt 3
2026-05-19 17:53:05  MDM enrollment confirmed via CLI (poll 2)
2026-05-19 17:53:06  === JPMC-EC2-Enroll: SUCCESS ===
2026-05-19 17:53:07  ENROLLMENT_STATUS: {"status":"SUCCESS",...}
```

### Machine-Readable Status Line

The final line of every enrollment run contains a parseable JSON status:

```
ENROLLMENT_STATUS: {"status":"SUCCESS|FAILED","instance":"i-xxx","region":"us-east-2","mdm":"https://...","action":"none|terminate_and_rebuild"}
```

Downstream AWS systems (Lambda, Step Functions, CloudWatch Logs Insights) can grep for `ENROLLMENT_STATUS:` and parse the `action` field to determine whether to keep or terminate and rebuild the instance.

---

## Troubleshooting

### Automatic retry — ThrottleInterval

The LaunchAgent is configured with `ThrottleInterval = 300`. If the enrollment script exits with an error (e.g. IMDS not ready at boot), launchd automatically retries it every 5 minutes until it succeeds. You will see multiple `=== JPMC-EC2-Enroll started ===` entries in the log — this is expected behavior, not a problem. Once enrollment succeeds and prodFlag=1 cleanup runs, the LaunchAgent removes itself and retries stop.

### Force-retrigger enrollment

If the LaunchAgent didn't fire or you need to retry manually:

```bash
sudo chmod 777 /Library/Logs/JPMC
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist
```

Or kickstart if already registered:
```bash
launchctl kickstart -k gui/501/com.jpmc.ec2.mdm.enrollment
```

### Enable VNC for visual debugging

```bash
sudo launchctl enable system/com.apple.screensharing
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

Then from your local Mac:
```bash
ssh -L 5900:localhost:5900 -i key.pem ec2-user@<ip>
```

Finder → ⌘K → `vnc://localhost` — log in as `ec2-user`.

### Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `NoCredentials` in log | IAM instance profile not attached | EC2 console → Actions → Security → Modify IAM role |
| `AccessDeniedException` | IAM policy missing or wrong secret ARN | Update IAM policy |
| `IMDS unavailable after 6 attempts` | Network not ready at boot | LaunchAgent will not retry automatically — kickstart manually |
| `MDM Profile not found` | Profile popup not dismissed correctly | Check log for navigation step, kickstart to retry |
| `cliclick failed on all paths` | cliclick binary missing from AMI | Re-stage — Phase 2 of stage script installs and caches it |

---

## Production Cleanup (prodFlag = 1)

When `PROD_FLAG="1"` is set in the stage script, after successful enrollment the following are removed:

- TCC Accessibility and AppleEvents permissions
- Auto-login disabled
- `com.jpmc.ec2.mdm.enrollment` defaults domain deleted
- `/tmp/enrollmentProfile.mobileconfig` deleted
- `/Users/Shared/._jpmc-tools/` (cliclick cache) deleted
- `/Users/Shared/JPMC-EC2-Enroll.scpt` deleted
- LaunchAgent unloaded

**Only the log files at `/Library/Logs/JPMC/` are retained.**

---

## Security

- Passwords are never written to disk, never appear in argv, env vars, or shell history
- Credentials live only in AppleScript runtime memory during enrollment
- Admin password is placed on clipboard for SecurityAgent, then immediately cleared twice
- All secrets are retrieved live from Secrets Manager at runtime — nothing is baked into the AMI
- The IAM instance profile provides temporary credentials — no long-lived keys anywhere

---

## Key Improvements Over AWS enroll-ec2-mac.scpt

| Issue | AWS Script | JPMC Script |
|---|---|---|
| Boot-time IMDS failure (exit code 7) | No retry — fails silently | 6 retries with 5s intervals |
| macOS 26 Tahoe navigation | Crashes (`sidebarTarget` undefined) | URL scheme direct to Device Management |
| Log persistence | `/tmp/` — wiped on reboot | `/Library/Logs/JPMC/` — persists |
| Log readability | No timestamps | Timestamped every line |
| cliclick reliability | Single attempt | 5-attempt retry loop |
| Machine-readable status | None | `ENROLLMENT_STATUS:` JSON line |
| Secret name fallback | Falls back to `"jamfSecret"` | Falls back to `"mdmSecret"`, logs warning |
| Post-enrollment cleanup | Removes cliclick via brew | Removes entire `._jpmc-tools/` cache + script |
