# JPMC EC2 Mac — Headless MDM Enrollment

Fully headless, automated Jamf MDM enrollment for EC2 Mac instances. Instances launched from the AMI enroll automatically at first GUI login with no human interaction required.

Supports **macOS 14 (Sonoma)**, **macOS 15 (Sequoia)**, **macOS 26 (Tahoe)**, and **macOS 27 (Golden Gate)**.

> **Origin:** This workflow was inspired by and built upon the AWS sample script `enroll-ec2-mac.scpt` (see `EC2_AWS_Build/`). The JPMC implementation rewrites the enrollment logic with IMDS retry, multi-version macOS support, persistent logging, cliclick fallback, S3 status reporting, and machine-readable status output for downstream AWS automation.

---

## Repository Structure

```
/
├── JPMC-setup-user.sh           # Step 1 — run via SSM on new instance
├── JPMC-stage-enrollment.sh     # Step 3 — run via SSM after SIP disable
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
JPMC-setup-user.sh
  • Retrieves credentials from Secrets Manager
  • Sets ec2-user password + Secure Token
  • Configures auto-login
  • Disables screen saver (prevents lock before enrollment)
  • Creates /private/var/db/locationd (required by Jamf binary)
        │
        ▼
AWS SIP Disable API ──── AWS API ────► Instance reboots (~2.5 hrs)
        │
        ▼
JPMC-stage-enrollment.sh
  • Creates /Library/Logs/JPMC/ (persistent log directory)
  • Injects TCC permissions (Accessibility + AppleEvents) into SQLite
  • Installs cliclick via Homebrew, caches to /Users/Shared/._jpmc-tools/
  • Downloads JPMC-EC2-Enroll.applescript from GitHub, compiles to .scpt
  • Writes MMSecret + prodFlag to defaults
  • Writes LaunchAgent plist directly to /Library/LaunchAgents/
  • Disables RandomizePassword in ec2-macos-init
  • Clears ec2-macos-init instance history
  • Clears /Library/Logs/DiagnosticReports/ panic + ips files so the AMI
    doesn't ship with stale crash reports that trigger the boot dialog
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
  launchd holds LaunchAgent until network is ready
  (xpc.activity + RequireNetworkConnectivity, 30s delay, 1 hour grace)
        │
        ▼
  LaunchAgent fires → osascript JPMC-EC2-Enroll.scpt
        │
        ▼
  JPMC-EC2-Enroll.scpt
  • Reads MMSecret from defaults
  • scutil --nwi passive gate confirms interface is up (defense in depth)
  • Gets region from IMDS with --noproxy (12 retries / 10s — handles transient IMDS hiccups)
  • Retrieves all credentials from Secrets Manager
  • Authenticates with Jamf Pro via /api/oauth/token (OAuth client credentials)
  • Dismisses any "Your computer was restarted" dialog left by SIP-disable panic (bootout DiagnosticsReporter)
  • Dismisses the internal-SSD disk unlock prompt if the host carries a
    FileVault-locked volume group from a prior tenancy (see Troubleshooting)
  • Creates enrollment invitation via Jamf API
  • Builds .mobileconfig profile
  • Opens profile → on macOS 15/26, presses Return to dismiss "Profile Downloaded" popup (macOS 14 has no popup)
  • Navigates to Device Management via URL scheme (works on all macOS versions)
  • Finds MDM Profile row by name, double-clicks with cliclick
  • Clicks Install → enters admin password into SecurityAgent
  • Polls for enrollment confirmation (up to 5 minutes)
  • Enables screen sharing
  • Writes ENROLLMENT_STATUS JSON to log
  • Uploads enrollment status directly to S3
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

**IAM instance profile** with `secretsmanager:GetSecretValue` on the `mdmSecret` ARN and `s3:PutObject` on the enrollment logs bucket.

**EC2 Mac dedicated host** (minimum 24-hour allocation, mac2.metal recommended).

---

## Environment Configuration

All environment-specific settings are at the top of `JPMC-stage-enrollment.sh`:

```bash
readonly SECRET_ID="mdmSecret"      # AWS Secrets Manager secret name
readonly PROD_FLAG="1"              # Set to "1" for production cleanup
readonly ENROLL_SOURCE_URL="..."    # URL to JPMC-EC2-Enroll.applescript
readonly CLICLICK_SOURCE="brew"     # "brew" or direct URL for internal Artifactory/Bitbucket
```

The AppleScript never needs to be modified per environment — it reads everything from defaults written by the stage script. All credentials and URLs live in Secrets Manager. To rotate passwords or update the Jamf URL, update `mdmSecret` — no script changes needed.

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
2026-05-21 03:30:44  === JPMC-EC2-Enroll started | macOS 26 ===
2026-05-21 03:30:44  IMDS ok (attempt 1/12, waited 0s): placement/region = us-east-2
2026-05-21 03:31:00  MDM Profile found — opening install sheet...
2026-05-21 03:31:13  MDM enrollment confirmed via CLI (poll 2)
2026-05-21 03:31:13  === JPMC-EC2-Enroll: SUCCESS ===
2026-05-21 03:31:13  ENROLLMENT_STATUS: {"status":"SUCCESS",...}
```

The `waited Xs` value on the `IMDS ok` line is the elapsed time between `imdsGet` being called and IMDS returning. With launchd holding the agent until network is ready, this should be `0s` or `1s` in normal operation. A larger number means IMDS itself was slow to respond.

### Machine-Readable Status Line

The final line of every enrollment run contains a parseable JSON status:

```
ENROLLMENT_STATUS: {"status":"SUCCESS|FAILED","instance":"i-xxx","region":"us-east-2","mdm":"https://...","action":"none|terminate_and_rebuild"}
```

In addition to the log, enrollment status is uploaded directly to S3 (`enrollment-status/{instance_id}.json`) on completion. Downstream AWS systems can check S3 instead of parsing logs.

---

## Troubleshooting

### Network readiness — xpc.activity

The LaunchAgent does not use `RunAtLoad`. Instead it uses `xpc.activity` with `RequireNetworkConnectivity = true`, `Delay = 30`, and `GracePeriod = 3600` (1 hour). launchd holds the agent at boot until the network interface is confirmed ready in SCDynamicStore (same source that `scutil --nwi` reads from), then waits 30 seconds before firing. This is the same pattern Apple's own system daemons use (`softwareupdated`, `fairplaydeviceidentityd`, `online-auth-agent`). The script doesn't poll for network — launchd does.

### macOS panic dialog at boot ("Your computer was restarted because of a problem")

The AWS SIP-disable API forces an instance reboot which occasionally triggers a kernel panic in `IOSkywalkKernelPipeBSDClient` (60s busy timeout during shutdown). macOS writes a `.panic` file to `/Library/Logs/DiagnosticReports/`, and at the next boot the `Diagnostics Reporter` LaunchAgent shows a modal dialog that blocks System Settings UI automation.

This is handled in two places:

1. **`JPMC-stage-enrollment.sh` Phase 8** clears `*.panic` and `*.ips` files before AMI snapshot, so future AMIs ship clean.
2. **`JPMC-EC2-Enroll.applescript installProfile`** runs `launchctl bootout gui/$(id -u)/com.apple.DiagnosticsReporter` at the top, dismissing the dialog defensively if it ever appears. Idempotent — silently no-ops on healthy instances.

The combination means existing AMIs (with the panic file baked in) still enroll successfully via the runtime bootout, and new AMIs (built with the updated stage script) never have the file at all.

### Internal-SSD disk unlock prompt ("Enter a password to unlock the disk")

Some EC2 Mac dedicated hosts carry a **FileVault-locked APFS volume group on the Mac mini's own internal SSD** (`disk0` → container `disk3`), left behind by a previous tenancy. At every GUI login macOS attempts to mount it, has no key, and `SecurityAgent` presents a modal:

```
Enter a password to unlock the disk "InternalDisk - Data"
```

There is no password. The volume is not ours, is not in the AMI (which captures only `/dev/sda1`), and is not touched by any script in this repo.

**Symptom:** enrollment repeatedly fails at `ERROR: Install button not found after 10 seconds` even though `MDM Profile found` succeeded moments earlier. Accessibility *queries* do not need foreground focus, so the row lookup works, but cliclick sends a **physical click** which lands on whatever owns the screen.

**Two distinct failure modes:**

1. The modal owns the foreground. Observed at 430x194 at position (558,118), which spans x 558-988 and y 118-312 — covering the exact coordinates targeted for the MDM Profile row.
2. `SecurityAgent` serialises its authorization sessions. While this prompt holds one, the profile-install password prompt can never come forward.

**Handling:** `JPMC-EC2-Enroll.applescript` calls `dismissDiskUnlockPrompt()` in two places — at the top of `installProfile` before any UI interaction, and again at the top of `enterAdminPassword`. The second call is not redundant: the wait loop there only tests that `SecurityAgent` *has* a window, not which dialog it is, so without it the admin password could be pasted into the unlock prompt instead of the install prompt.

**Not fixable with `/etc/fstab`.** An `fstab` `noauto` entry does not suppress this. `fstab` is read by `diskarbitrationd` when deciding whether to mount a filesystem, but the FileVault unlock attempt happens *upstream* of that, so `fstab` is never consulted for an encrypted volume. AWS suggested this approach in case 178535629800759; it is the wrong mechanism for this disk. Deleting the volume is also not viable — `diskutil apfs deleteVolume` commonly returns `-69888` on locked volumes, and it would destroy host state we do not own.

**Not hardware or OS specific.** Originally reported to AWS as M4-only, based on an M2 comparison that turned out to be a false negative. Reproduced since on `mac2.metal` (M1, `Macmini9,1`) running macOS 27.0, on a host from a batch that previously ran 20 consecutive clean builds. Both macOS 26 and 27 show it on some hosts and not others; both M1/M2 and M4 families appear on both sides. **The variable is the individual dedicated host.**

The real fix has to come from AWS clearing the volume during the Dedicated Host scrubbing workflow, which their documentation states already erases the internal SSD. Tracked in **AWS case 179140454500900**. Dismissal is the only guest-side mitigation, and is what AWS's own team recommended on 2026-08-12.

**Diagnosing a suspect host:**

```bash
diskutil apfs list | grep -E "FileVault:.*Yes \(Locked\)"
lsappinfo list | grep -i "in front"
log show --last 30m --predicate 'process == "SecurityAgent"' | grep -i unlockDisk
```

A `DUAuthMechanismPrompt unlockDiskWithUser:password:rememberPassword:` entry confirms it. `diskarbitrationd -d` writes verbose decisions to `/var/log/diskarbitrationd.log` if deeper detail is needed.

### Automatic retry — ThrottleInterval

The LaunchAgent is also configured with `ThrottleInterval = 300` as a backstop. If the enrollment script exits with an error after launchd hands off (e.g. Jamf API unreachable, Secrets Manager auth fails), launchd automatically retries it every 5 minutes until it succeeds. You will see multiple `=== JPMC-EC2-Enroll started ===` entries in the log — this is expected behavior, not a problem. Once enrollment succeeds and prodFlag=1 cleanup runs, the LaunchAgent removes itself and retries stop.

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
| `IMDS unavailable after 12 attempts (Xs elapsed)` | Real IMDS failure (network is already confirmed up by launchd before script fires) | Check elapsed time — if long, investigate IMDS service health. LaunchAgent will retry automatically every 5 minutes |
| `Network interface not ready (scutil --nwi) — waiting...` | launchd fired the agent but interface flapped briefly | Defense-in-depth gate, will pass when interface returns. Should be rare |
| `MDM Profile not found` | Profile popup not dismissed correctly | Check log for navigation step, kickstart to retry |
| `Install button not found after 10 seconds`, with `MDM Profile found` logged just before | A modal owns the foreground, so cliclick's physical click misses System Settings. Usually the internal-SSD unlock prompt, or Setup Assistant on a first boot | See "Internal-SSD disk unlock prompt" above. Check `lsappinfo list \| grep -i "in front"` |
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
- LaunchAgent unloaded and plist deleted

**Only the log files at `/Library/Logs/JPMC/` are retained.**

---

## Security

- Passwords are never written to disk, never appear in env vars, or shell history
- Credentials live only in AppleScript runtime memory during enrollment
- Admin password is placed on clipboard for SecurityAgent, then immediately cleared twice
- All secrets are retrieved live from Secrets Manager at runtime — nothing is baked into the AMI
- The IAM instance profile provides temporary credentials — no long-lived keys anywhere
- Secrets Manager JSON parsed with `plutil` (Apple-native, no third-party deps) instead of Python + eval — eliminates shell evaluation of dynamically-constructed strings from the credential code path
- After fields are extracted, the full SecretString JSON is explicitly `unset` so the bundled credential set doesn't linger in process environment longer than the moment it's needed
- IMDS calls use `--noproxy '169.254.169.254'` so link-local metadata requests bypass any `http_proxy` env var (corporate proxy environments)

---

## Key Improvements Over AWS enroll-ec2-mac.scpt

| Issue | AWS Script | JPMC Script |
|---|---|---|
| Boot-time IMDS failure (exit code 7) | No retry — fails silently | launchd holds agent until network is ready (`xpc.activity` + `RequireNetworkConnectivity`), then 12 retries with 10s intervals + `scutil --nwi` gate + ThrottleInterval auto-retry |
| Curl through corporate proxy | Routes link-local through proxy, fails | `--noproxy '169.254.169.254'` on all IMDS calls — direct route regardless of env vars |
| No visibility into network wait time | Blind to delays like the v6 multi-hour hang | Elapsed time logged on every IMDS success and failure |
| macOS 26 Tahoe navigation | Crashes (`sidebarTarget` undefined) | URL scheme direct to Device Management |
| macOS 14/15 support | Limited | Full support — unified installation flow across all versions |
| Log persistence | `/tmp/` — wiped on reboot | `/Library/Logs/JPMC/` — persists |
| Log readability | No timestamps | Timestamped every line |
| cliclick reliability | Single attempt | Single surgical cliclick matching AWS approach |
| Machine-readable status | None | `ENROLLMENT_STATUS:` JSON line + S3 status file |
| Secret name fallback | Falls back to `"jamfSecret"` | Falls back to `"mdmSecret"`, logs warning |
| Post-enrollment cleanup | Removes cliclick via brew | Removes entire `._jpmc-tools/` cache + script + LaunchAgent plist |
| Panic dialog at boot | Blocks UI automation, no handling | Stage script clears `.panic` files pre-snapshot; enrollment script bootouts `DiagnosticsReporter` defensively at runtime |
| Internal-SSD FileVault unlock prompt | Not handled — enrollment fails on affected hosts | `dismissDiskUnlockPrompt()` clears it before UI automation and again before password entry |
| Per-user TCC database on macOS 27 | N/A | Stage script discovers the relocated ProtectedSystem container by metadata identity rather than a hardcoded UUID |
| Secrets Manager JSON parsing | Python + `eval` + `shlex.quote` (shell anti-pattern flagged by SAST) | `plutil -extract raw` — Apple-native, no eval, no third-party deps |
| Jamf authentication | Basic auth (deprecated in modern Jamf Pro) | OAuth client credentials via `/api/oauth/token`, parsed with `plutil` |
| Jamf XML invitation parsing | Fragile text-item-delimiter string splitting | `xmllint --xpath` — native macOS, schema-aware |
