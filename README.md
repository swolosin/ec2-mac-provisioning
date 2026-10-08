# JPMC EC2 Mac — Headless MDM Enrollment

Fully headless, automated Jamf MDM enrollment for EC2 Mac instances. Instances launched from the AMI enroll automatically at first GUI login with no human interaction required.

Supports **macOS 14 (Sonoma)**, **macOS 15 (Sequoia)**, **macOS 26 (Tahoe)**, and **macOS 27 (Golden Gate)**.

> **Origin:** This workflow was inspired by and built upon the AWS sample script `enroll-ec2-mac.scpt` (see `EC2_AWS_Build/`). The JPMC implementation rewrites the enrollment logic with IMDS retry, multi-version macOS support, persistent logging, cliclick fallback, S3 status reporting, and machine-readable status output for downstream AWS automation.

---

## Repository Structure

```
/
├── JPMC-setup-user.sh           # Step 1 — run as ec2-user via SSM on a new instance
├── JPMC-stage-enrollment.sh     # Step 3 — run as ec2-user via SSM after SIP disable
├── JPMC-EC2-Enroll.applescript  # Step 4 — downloaded and compiled by the stage script
├── jpmc_pwpolicy.sh             # Password policy helper (standalone, optional)
└── EC2_AWS_Build/               # Original AWS sample scripts (reference only)
```

All three numbered scripts carry the same `SCRIPT_VERSION` and are bumped together. Current version: **1.1.0**.

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
  • Suppresses per-user Setup Assistant: clears the loginwindow MiniBuddyLaunch
    gate and pre-seeds com.apple.SetupAssistant with version values computed
    from sw_vers (see Troubleshooting)
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
  • Quits per-user Setup Assistant if it is still on screen (see Troubleshooting)
  • Creates enrollment invitation via Jamf API
  • Builds .mobileconfig profile
  • Opens profile → on macOS 15/26, presses Return to dismiss "Profile Downloaded" popup (macOS 14 has no popup)
  • Navigates to Device Management via URL scheme (works on all macOS versions)
  • Finds the NEWEST downloaded MDM Profile row, double-clicks with cliclick
  • Clicks Install → enters admin password into SecurityAgent
  • Polls for enrollment confirmation (up to 5 minutes)
  • Enables screen sharing
  • Writes ENROLLMENT_STATUS JSON to log (also on an unhandled error, so the
    pipeline is never left polling a run that already died)
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

## Running It End to End

Two ways to run this: the Step Functions pipeline, which is the normal path, and by hand over SSM, which is for debugging. Everything lives in **us-east-2**.

### The pipeline

| State machine | Purpose |
|---|---|
| `jpmc-ec2-staging-pipeline` | Launch, setup, SIP disable, stage, snapshot AMI |
| `jpmc-ec2-test-pipeline` | Launch instances from an AMI and verify enrollment (20 iterations) |

Start a build:

```bash
aws stepfunctions start-execution \
  --region us-east-2 \
  --state-machine-arn arn:aws:states:us-east-2:767405844957:stateMachine:jpmc-ec2-staging-pipeline \
  --input '{}'
```

`{}` builds the **latest** macOS available as an EC2 Mac AMI. That is deliberate: this account is a sandbox and testing the newest OS is the point. The `jpmc-staging-launch` Lambda picks the dedicated **host first**, because host firmware caps what can boot, and only then picks the newest AMI that host supports.

> **Never sort the AMI lookup on `CreationDate`.** macOS 15.8 was published 8 seconds *after* 27.0, so date order lies about which is newer. The Lambda sorts on a version tuple parsed out of the AMI name.

To pin a version instead of taking the latest:

```bash
--input '{"macos_version":"27"}'
```

Lambdas run in this order:

```
launch → check_instance → check_ssm → run_setup → disable_sip → check_sip
      → run_stage → create_ami → check_ami → trigger_tests → terminate_instance

trigger_tests fans out to the test pipeline:
      test_launch → test_wait_enrollment → test_pull_logs → test_terminate
```

Follow an execution:

```bash
aws stepfunctions describe-execution --region us-east-2 \
  --execution-arn <execution-arn> \
  --query '{Status:status,Started:startDate,Stopped:stopDate,Error:error,Cause:cause}'
```

### By hand over SSM

Use this when you need to iterate on a single box. **Both shell scripts must run as `ec2-user`, not root.** SSM runs commands as root, so every invocation has to drop privileges.

**Step 1 — user setup**

```bash
aws ssm send-command --region us-east-2 \
  --instance-ids i-xxxxxxxxxxxx \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "rm -f /tmp/JPMC-setup-user.sh",
    "curl -fsSL <raw-url>/JPMC-setup-user.sh -o /tmp/JPMC-setup-user.sh",
    "chown ec2-user:staff /tmp/JPMC-setup-user.sh",
    "chmod +x /tmp/JPMC-setup-user.sh",
    "sudo -u ec2-user /tmp/JPMC-setup-user.sh"
  ]'
```

> **Always `rm -f` the target path first.** If the pipeline already ran, `/tmp/JPMC-*.sh` is owned by root and `ec2-user` cannot overwrite it. `curl` then fails with `curl: (56) Failure writing output`, and because the old file is still sitting there the stale version runs instead. That has cost real debugging time. Confirm you are running what you think you are:
>
> ```bash
> grep -c find_user_tcc_db /tmp/JPMC-stage-enrollment.sh
> ```

**Step 2 — disable SIP**

The supported call is `create-mac-system-integrity-protection-modification-task`. The instance reboots into recovery and back, which takes roughly 2.5 hours on Apple silicon.

```bash
aws ec2 create-mac-system-integrity-protection-modification-task \
  --region us-east-2 \
  --instance-id i-xxxxxxxxxxxx \
  --mac-system-integrity-protection-status disabled \
  --mac-credentials '{"rootVolumeUsername":"ec2-user","rootVolumePassword":"..."}'
```

> This puts the admin password in your shell history, which is exactly what the rest of this project avoids. Prefer the pipeline, where `jpmc-staging-disable_sip` reads it from Secrets Manager and it never touches a terminal.

Confirm before continuing:

```bash
aws ec2 describe-instances --region us-east-2 --instance-ids i-xxxxxxxxxxxx \
  --query 'Reservations[0].Instances[0].MacSystemIntegrityProtectionStatus'
```

**Step 3 — stage**

Same pattern as step 1, with `JPMC-stage-enrollment.sh`. It downloads and compiles `JPMC-EC2-Enroll.applescript`, writes the LaunchAgent, and runs the Phase 7 and 7.5 verification gates. It exits non-zero if any gate fails, so read the tail of its output.

**Step 4 — snapshot, then launch from the AMI**

Enrollment fires on its own at first GUI login. Nothing else to run.

### Re-running enrollment on a live instance

The enrollment job is a **LaunchAgent**, not a daemon, because it needs the GUI session:

```bash
sudo launchctl bootout   gui/501/com.jpmc.ec2.mdm.enrollment
sudo launchctl bootstrap gui/501 /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist
tail -f /Library/Logs/JPMC/EC2-Enroll.log
```

If it is already registered, this is quicker:

```bash
sudo launchctl kickstart -k gui/501/com.jpmc.ec2.mdm.enrollment
```

`501` is `ec2-user`. Confirm with `id -u ec2-user` if you are unsure.

If the agent cannot write its log, fix ownership rather than loosening permissions:

```bash
sudo chown -R ec2-user:staff /Library/Logs/JPMC
```

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

### Setup Assistant blocks enrollment on first login (macOS 27)

On a fresh AMI boot, **per-user Setup Assistant ("Buddy")** presents a nine-pane wizard and runs **frontmost** as `com.apple.SetupAssistant`. Confirmed with `lsappinfo`: Setup Assistant held `(in front)` while System Settings sat at list position 49. Enrollment failed 16 consecutive times at `Install button not found after 10 seconds`.

`/var/db/.AppleSetupDone` is already in the AMI and suppresses the **device** Setup Assistant. It does nothing for the **per-user** Buddy flow.

Panes observed on macOS 27.0: Accessibility → **Apple ID sign-in** → Age (child/teen/adult) → Appearance → Analytics → Screen Time → Software updates → **Liquid Glass** → Welcome.

The Apple ID pane cannot be answered headlessly. And `tell application settingsApp to activate` does **not** win the foreground back from Buddy. That was tested.

#### What does not work, and why — do not retry these

| Approach | Result |
|---|---|
| `SkipSetupItems` written to `/Library/Managed Preferences/com.apple.SetupAssistant.managed.plist` | **Disproved 2026-10-08.** `ManagedClient` owns that directory and prunes anything with no backing MDM profile. Gone after one boot |
| Delivering `SkipSetupItems` as a real configuration profile | Circular. Needs the MDM enrollment Buddy is blocking |
| `tell application "System Settings" to activate` | Does not take the foreground from Buddy |
| Setting every `DidSee*` key to `1` and nothing else | Insufficient. Several panes are gated on `LastSeen*ProductVersion` strings instead |

The managed-preference route looked right because it is Apple's documented mechanism. The system log is unambiguous about why it fails:

```
ManagedClient: Notifying CFPrefsD Of Updated Managed Preferences
RemoveObsoleteBMAIDAccounts: checking against 0 MDM profiles
```

Zero profiles, so the file is reaped. After a reboot `/Library/Managed Preferences/` held only the `ec2-user` subdirectory.

#### What does work — three layers

**Layer A — the loginwindow gate.** `MiniBuddyLaunch` in the **per-user** `com.apple.loginwindow` domain, not in `com.apple.SetupAssistant`. That is why earlier versions of Phase 7.5 missed it entirely. Found in loginwindow's own log:

```
-[Login1 miniBuddyOption]_block_invoke | NOT mbsetupuser, checking pref
MiniBuddyLaunch pref is set, setting miniBuddyOption to kMinibuddyOptionMBPrefSet
-[Login1 miniBuddyOption] | returning: 2
A minibuddy option is set, calling startMiniBuddy
```

After deleting the key, the same code path logged:

```
MiniBuddyLaunch pref is NOT set
-[Login1 miniBuddyOption] | returning: 0
```

So the gate works. It is **necessary but not sufficient**: Buddy still appeared once through a second launch path carrying no `-MiniBuddyYes` flag, which has not been identified. That second path is why Layer C exists.

**Layer B — per-user pre-seed.** Marks every pane already-seen in `com.apple.SetupAssistant`. Verified to survive the AMI snapshot: on a fresh instance every `DidSee*` read `1` and every version key read `27.0`, including `LastSeenGlassTintUpsellProductVersion`.

Layer B is not simply "set every `DidSee*` to 1". macOS 27 tracks panes two different ways. After manually completing all nine panes, these were still `0`:

```
DidSeeActivationLock  DidSeeAppStore  DidSeeApplePaySetup  DidSeeLockdownMode
DidSeeSyncSetup  DidSeeSyncSetup2  DidSeeTermsOfAddress  DidSeeTouchIDSetup
```

Several panes are gated on `LastSeen*ProductVersion` strings instead, which **re-trigger on every OS version bump**. That is why an AMI built in September still showed panes. Those values are computed from `sw_vers` at runtime rather than hardcoded, so a 27.1 or 28.0 AMI seeds itself correctly.

The **Liquid Glass pane has no skip key at all.** The macOS 27.0.1 Setup Assistant binary contains `GlassSelection`, `GlassSelectionFlowItem`, `GlassSelectionViewController` and `LastSeenGlassTintUpsellProductVersion`, but nothing matching in the skip-key vocabulary. Layer B is the only way to suppress it.

**Layer C — kill it at runtime.** `quitSetupAssistant()` in `JPMC-EC2-Enroll.applescript` runs at the top of `installProfile` and again at the top of `enterAdminPassword`, and kills Buddy outright if it is on screen. This is the only layer verified to clear it unconditionally. Measured on `i-0193db62a18036255`: `killall` succeeded, process count went to `0`, frontmost went to none, and it did **not** respawn.

`quit` via Apple events is not used. Buddy logs `reasserting frontmostness for MiniBuddy!` and does not honour a polite quit. Nothing of value is lost by killing it: there is no Apple ID on these instances, no user to onboard, and device setup is already marked complete.

Layers A and B reduce how often C has to fire. C is what guarantees the screen is clear at the moment we click.

Phase 7.5 exits non-zero if Layer A or B fails to land, because a silent miss means every instance from that AMI leans entirely on C.

**Verifying on a fresh instance:**

```bash
# Layer A — should print nothing and exit non-zero
defaults read com.apple.loginwindow MiniBuddyLaunch

# Layer B — every DidSee* should be 1, version keys should match sw_vers
defaults read com.apple.SetupAssistant

# Layer C — is it on screen right now?
ps aux | grep -i "[S]etup Assistant"
lsappinfo list | grep -i "in front"

# What decision did loginwindow actually make this boot?
log show --last 1h --predicate 'process == "loginwindow"' | grep -i minibuddy
```

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

**Handling (verified working 2026-10-08** on `i-0193db62a18036255`, which logged `Disk unlock prompt detected — dismissing` then `Disk unlock prompt cancelled` with no persistence warning**).** `JPMC-EC2-Enroll.applescript` calls `dismissDiskUnlockPrompt()` in two places — at the top of `installProfile` before any UI interaction, and again at the top of `enterAdminPassword`. The second call is not redundant: the wait loop there only tests that `SecurityAgent` *has* a window, not which dialog it is, so without it the admin password could be pasted into the unlock prompt instead of the install prompt.

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

### Stale downloaded profiles accumulate across retries

Every `open` of a `.mobileconfig` appends another entry to **System Settings → General → Device Management → Downloaded**, and nothing removes the old ones. Because the LaunchAgent retries every 5 minutes, a box that has been failing for a while builds up a list.

Measured on `i-0193db62a18036255` after nine attempts, the outline held 3 rows:

```
row 1  Downloaded                                          <- section header
row 2  MDM Profile / Profile not installed. Double-click to review.
row 3  MDM Profile / Profile not installed. Double-click to review.
```

The script used to hardcode `row 2`, which is correct only on the very first attempt. From the second attempt onward row 2 is the **oldest** download, carrying a spent enrollment invitation, while the profile the current run just created sits at the bottom.

**Fixed** by targeting the last row instead. The log now reports how many accumulated, so this is visible rather than silent:

```
MDM Profile found - using the newest of 2 downloaded profile(s) - opening install sheet...
```

If that count is above 1 on a box you are debugging, earlier attempts already failed.

### Never drive the UI over SSM

**Run UI automation from the LaunchAgent, or via a LaunchAgent bootstrapped into `gui/501`. Never over SSM, and never over SSH.**

TCC authorises on the **responsible process**, not the process making the call. From the LaunchAgent, the responsible process is `osascript`, which the stage script grants:

```
AUTHREQ_SUBJECT: subject=/usr/bin/osascript
Evaluated composed authorization from kTCCServicePostEvent
  to parent service kTCCServiceAccessibility: Auth:Allowed (User Set)
```

That inheritance also covers `cliclick`, even though `cliclick` has no TCC entry of its own, which is why no grant is needed for it:

```
AttributionChain: responsible={osascript}, accessing={cliclick}, requesting={cliclick}
```

Run the same `osascript` over SSM and the responsible process becomes `amazon-ssm-agent`, which has no AppleEvents grant. TCC then raises a consent dialog:

```
"amazon-ssm-agent" wants access to control "System Events".
```

**That dialog is the trap.** It is drawn by `tccd`, which is not a visible application, so it does not appear in:

```applescript
every process whose visible is true
```

It sits on screen covering the click target, invisible to any probe that filters on visibility, and every subsequent click silently lands on the back of it. On 2026-10-08 two such dialogs were left over the MDM Profile row at (628,231):

```
universalAccessAuthWarn  win "Screen Recording"  pos=(281,154) size=(461x181)
UserNotificationCenter   win ""                  pos=(382,133) size=(260x272)
```

Both contained the target. Enrollment attempts during that window failed for that reason alone and the results were worthless.

To enumerate what is really on screen, drop the filter:

```applescript
tell application "System Events" to set allProcs to every process
```

Same trap over SSH, where TCC blames `sshd-keygen-wrapper` and `osascript` times out with `-1712`.

### Automatic retry — ThrottleInterval

The LaunchAgent is also configured with `ThrottleInterval = 300` as a backstop. If the enrollment script exits with an error after launchd hands off (e.g. Jamf API unreachable, Secrets Manager auth fails), launchd automatically retries it every 5 minutes until it succeeds. You will see multiple `=== JPMC-EC2-Enroll started ===` entries in the log — this is expected behavior, not a problem. Once enrollment succeeds and prodFlag=1 cleanup runs, the LaunchAgent removes itself and retries stop.

### Force-retrigger enrollment

See [Re-running enrollment on a live instance](#re-running-enrollment-on-a-live-instance). It is a LaunchAgent in `gui/501`, not a daemon, so `system/` targets will not find it.

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
| `Install button not found after 10 seconds`, with `MDM Profile found` logged just before | A modal owns the foreground, so cliclick's physical click misses System Settings. Usually the internal-SSD unlock prompt, Setup Assistant on a first boot, or a TCC consent dialog left behind by someone running osascript over SSM | Enumerate **every** process with a window, not just visible ones. See "Never drive the UI over SSM" and "Internal-SSD disk unlock prompt" above |
| `using the newest of N downloaded profile(s)` where N > 1 | Earlier attempts already failed and left stale downloads behind | Not itself a fault. Read back through the log for the first failure |
| `ABORTED - unhandled error <n>` | An unhandled AppleScript error. Status is still reported, so the pipeline terminates and rebuilds rather than hanging | Read the error number and message in the log line |
| `WARNING: Setup Assistant respawned after killall` | Buddy is being restarted by the unidentified second launch path | Layers A and B did not hold. Check `defaults read com.apple.loginwindow MiniBuddyLaunch` on the AMI |
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
- The top-level error handler redacts the admin password out of error text before anything is logged or uploaded. `do shell script` failures can echo the failing command, and some of those commands carry the password. The value is held in memory only for the duration of the run and cleared when it ends
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
| Per-user Setup Assistant on macOS 27 | Not handled — blocks the foreground on every first login | Three layers: Phase 7.5 clears the loginwindow `MiniBuddyLaunch` gate and pre-seeds `com.apple.SetupAssistant` with runtime-computed version values; `quitSetupAssistant()` kills it at runtime if it still appears |
| Stale downloaded profiles on retry | Clicks a fixed row index, so retries click a spent profile | Targets the newest downloaded profile and logs how many accumulated |
| Unhandled script error | No status written, caller left guessing | Top-level handler still writes `ENROLLMENT_STATUS` and the S3 object, with secrets redacted and the reason JSON-escaped |
| Per-user TCC database on macOS 27 | N/A | Stage script discovers the relocated ProtectedSystem container by metadata identity rather than a hardcoded UUID |
| Secrets Manager JSON parsing | Python + `eval` + `shlex.quote` (shell anti-pattern flagged by SAST) | `plutil -extract raw` — Apple-native, no eval, no third-party deps |
| Jamf authentication | Basic auth (deprecated in modern Jamf Pro) | OAuth client credentials via `/api/oauth/token`, parsed with `plutil` |
| Jamf XML invitation parsing | Fragile text-item-delimiter string splitting | `xmllint --xpath` — native macOS, schema-aware |
