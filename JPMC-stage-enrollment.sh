#!/bin/zsh
# ============================================================
# Author:  Stephen Wolosin
# Team:
# Date:    2026-05-21
#
# WARNING: Test thoroughly in non-production environments before
# deploying to production. This script modifies TCC databases,
# installs LaunchAgents, and configures ec2-macos-init on EC2 Mac
# instances. Misconfiguration may result in failed enrollment or
# broken instance state. The author and team assume no liability
# for damages arising from use outside of validated test environments.
# ============================================================
#
# JPMC-stage-enrollment.sh
#
# Prepares an EC2 Mac staging instance for headless Jamf MDM enrollment.
# Uses JPMC-EC2-Enroll.scpt instead of the AWS enroll-ec2-mac.scpt,
# which fixes:
#   - launchd xpc.activity gates the LaunchAgent until network is ready
#   - IMDS retry logic with --noproxy and elapsed-time logging
#   - macOS 26 Device Management navigation (sidebarTarget crash)
#   - cliclick cached locally so the AMI does not depend on Homebrew at boot
#   - per-user Setup Assistant ("Buddy") suppressed via the loginwindow
#     MiniBuddy gate plus a Setup Assistant pre-seed (Phase 7.5)
#
# Requirements:
#   - Run as ec2-user (NOT root)
#   - SIP must be disabled before running
#   - JPMC-setup-user.sh must have been run first
#   - Internet access
#
# Usage:
#   scp -i key.pem JPMC-stage-enrollment.sh ec2-user@<ip>:/tmp/
#   chmod +x /tmp/JPMC-stage-enrollment.sh && /tmp/JPMC-stage-enrollment.sh
#

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

set -euo pipefail

# =====================================================
# ENVIRONMENT CONFIGURATION
# Change SECRET_ID to match the AWS Secrets Manager secret name
# for the target environment (dev, staging, production).
#
# PROD_FLAG controls post-enrollment cleanup (TCC reset, auto-login
# off, LaunchAgent removal). Set to "1" only when everything is
# working end-to-end. Leave "0" during testing.
# =====================================================
# Version of the JPMC enrollment script set. Kept in lockstep with
# JPMC-setup-user.sh and JPMC-EC2-Enroll.applescript — bump all three
# together on each release.
readonly SCRIPT_VERSION="1.1.0"
readonly SECRET_ID="mdmSecret"
readonly PROD_FLAG="1"

# =====================================================
# SOURCE URLS
# When moving to internal infrastructure, update these
# two URLs — everything else stays the same.
#
# ENROLL_SOURCE_URL: raw URL to JPMC-EC2-Enroll.applescript
#   Current:  GitHub (public)
#   Future:   internal GitHub/Bitbucket raw URL
#
# CLICLICK_SOURCE: "brew" to install via Homebrew, or set to
#   a direct download URL for the cliclick binary
#   Current:  "brew"
#   Future:   "https://artifactory.internal/tools/cliclick"
# =====================================================
readonly ENROLL_SOURCE_URL="https://raw.githubusercontent.com/swolosin/ec2-mac-provisioning/main/JPMC-EC2-Enroll.applescript"
readonly CLICLICK_SOURCE="brew"

readonly ENROLL_SCRIPT="/Users/Shared/JPMC-EC2-Enroll.scpt"
readonly LAUNCHAGENT_PLIST="/Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist"

echo "$(/bin/date): JPMC-stage-enrollment v${SCRIPT_VERSION} started"
echo ""

# --- Preflight checks ---
[[ $EUID -eq 0 ]] && { echo "ERROR: run as ec2-user, not root" >&2; exit 1; }
/usr/bin/csrutil status | /usr/bin/grep -q disabled || { echo "ERROR: SIP must be disabled before running this script" >&2; exit 1; }

# =====================================================
# Log directory setup
# Create /Library/Logs/JPMC/ so the LaunchAgent can write
# persistent logs that survive beyond /tmp cleanup.
# =====================================================

echo "Creating log directory /Library/Logs/JPMC/..."
/usr/bin/sudo /bin/mkdir -p /Library/Logs/JPMC
/usr/bin/sudo /bin/chmod 777 /Library/Logs/JPMC
/usr/bin/sudo /usr/sbin/chown root:wheel /Library/Logs/JPMC
echo "Log directory ready."
echo ""

# =====================================================
# Phase 1: TCC Setup
# Pre-grant Accessibility and AppleEvents permissions for osascript
# so the enrollment script can drive System Settings headlessly.
# =====================================================

echo "=== Phase 1: TCC Setup ==="

readonly CLIENT="/usr/bin/osascript"
readonly SYS_DB="/Library/Application Support/com.apple.TCC/TCC.db"

# -----------------------------------------------------------------
# Locate the per-user TCC database.
#
# macOS 26 and earlier:  $HOME/Library/Application Support/com.apple.TCC/TCC.db
# macOS 27 and later:    the file moved into a ProtectedSystem container at
#   /private/var/containers/Data/ProtectedSystem/<UUID>/Data/Library/
#       Application Support/com.apple.TCC/TCC.db
#
# The UUID is assigned per install, so it must never be hardcoded. Identify the
# right container by its metadata instead: MCMMetadataIdentifier is
# "com.apple.tccd" and MCMMetadataOwnership.uid is the target user's uid.
# Verified on macOS 27.0 build 26A428 — lsof confirms the user tccd holds this
# exact file open read-write, so it is the live store and not a stale copy.
#
# The metadata plist is root-owned mode 600, hence the sudo on plutil.
# -----------------------------------------------------------------
find_user_tcc_db() {
  local uid="$1" d p ident owner
  for d in /private/var/containers/Data/ProtectedSystem/*/; do
    p="${d}.com.apple.containermanagerd.metadata.plist"
    [[ -f "$p" ]] || continue
    ident=$(/usr/bin/sudo /usr/bin/plutil -extract MCMMetadataIdentifier raw "$p" 2>/dev/null)
    owner=$(/usr/bin/sudo /usr/bin/plutil -extract MCMMetadataOwnership.uid raw "$p" 2>/dev/null)
    if [[ "$ident" == "com.apple.tccd" && "$owner" == "$uid" ]]; then
      printf '%s' "${d}Data/Library/Application Support/com.apple.TCC/TCC.db"
      return 0
    fi
  done
  return 1
}

USR_DB=$(find_user_tcc_db "$(/usr/bin/id -u)" || true)
if [[ -n "$USR_DB" && -f "$USR_DB" ]]; then
  echo "User TCC DB (macOS 27+ container): $USR_DB"
else
  USR_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  echo "User TCC DB (legacy path): $USR_DB"
fi
readonly USR_DB

if [[ ! -f "$USR_DB" ]]; then
  echo "ERROR: user TCC database not found at either location." >&2
  echo "       Checked the ProtectedSystem containers and the legacy \$HOME path." >&2
  echo "       Enrollment cannot drive System Settings without AppleEvents." >&2
  exit 1
fi

readonly TARGETS=(
  "com.apple.systemevents:/System/Library/CoreServices/System Events.app"
  "com.apple.finder:/System/Library/CoreServices/Finder.app"
  "com.apple.systempreferences:/System/Applications/System Settings.app"
  "com.apple.Safari:/Applications/Safari.app"
  "com.apple.BluetoothSetupAssistant:/System/Library/CoreServices/BluetoothSetupAssistant.app"
)

csreq_hex() {
  local path="$1"
  local req tmp
  req=$(/usr/bin/codesign -d -r- "$path" 2>&1 | /usr/bin/sed -n 's/^designated => //p')
  [[ -n "$req" ]] || return 1
  tmp=$(/usr/bin/mktemp)
  /bin/echo "$req" | /usr/bin/csreq -r- -b "$tmp" 2>/dev/null
  [[ -s "$tmp" ]] || { /bin/rm -f "$tmp"; return 1; }
  /usr/bin/xxd -p "$tmp" | /usr/bin/tr -d '\n'
  /bin/rm -f "$tmp"
}

# INSERT OR REPLACE rather than plain INSERT. The access table's primary key is
# (service, client, client_type, indirect_object_identifier), so a REPLACE
# overwrites any pre-existing row for the same tuple — including a recorded
# DENIAL (auth_value=0) that tccd may have written if something already tried
# and failed. A plain INSERT would hit a constraint violation and, under
# `set -euo pipefail`, abort the whole script.
#
# Columns are named explicitly so schema additions are tolerated. macOS 27 added
# one_time_reprompt_eligible and reminder_count (19 columns vs 17 previously);
# unnamed columns simply take their defaults.
tcc_insert() {
  local db="$1" use_sudo="$2" service="$3" target="$4" client_hex="$5" target_hex="$6"
  local target_blob="NULL"
  [[ -n "$target_hex" ]] && target_blob="X'$target_hex'"
  ${use_sudo} /usr/bin/sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO access (
  service, client, client_type, auth_value, auth_reason, auth_version,
  csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
  indirect_object_code_identity, flags, last_modified,
  pid, pid_version, boot_uuid, last_reminded
) VALUES (
  '$service', '$CLIENT', 1, 2, 3, 1,
  X'$client_hex', NULL, 0, '$target',
  $target_blob, 0, CAST(strftime('%s','now') AS INTEGER),
  NULL, NULL, 'UNUSED', 0
);
SQL
}

echo "Generating csreq for osascript..."
client_hex=$(csreq_hex "$CLIENT") || { echo "ERROR: failed to generate csreq" >&2; exit 1; }

echo "Writing kTCCServiceAccessibility to system DB..."
/usr/bin/sudo /usr/bin/sqlite3 "$SYS_DB" "DELETE FROM access WHERE client='$CLIENT' AND client_type=1 AND service='kTCCServiceAccessibility';"
tcc_insert "$SYS_DB" "/usr/bin/sudo" "kTCCServiceAccessibility" "UNUSED" "$client_hex" ""

echo "Writing kTCCServiceAppleEvents rows to user DB..."
/usr/bin/sqlite3 "$USR_DB" "DELETE FROM access WHERE client='$CLIENT' AND client_type=1 AND service='kTCCServiceAppleEvents';"

for entry in "${TARGETS[@]}"; do
  bid="${entry%%:*}"
  path="${entry#*:}"
  if [[ ! -e "$path" ]]; then
    echo "  skip (path missing): $bid"
    continue
  fi
  target_hex=$(csreq_hex "$path") || { echo "  skip (csreq failed): $bid"; continue; }
  tcc_insert "$USR_DB" "" "kTCCServiceAppleEvents" "$bid" "$client_hex" "$target_hex"
  echo "  added: $bid"
done

echo "Restarting tccd..."
/usr/bin/sudo /usr/bin/killall tccd 2>/dev/null || true
/usr/bin/killall tccd 2>/dev/null || true
echo "Waiting 10 seconds for tccd to settle..."
/bin/sleep 10

echo ""
echo "System DB osascript entries:"
/usr/bin/sudo /usr/bin/sqlite3 -header -column "$SYS_DB" \
  "SELECT service, auth_value, length(csreq) AS csreq_len FROM access WHERE client='$CLIENT';"
echo ""
echo "User DB osascript entries:"
/usr/bin/sqlite3 -header -column "$USR_DB" \
  "SELECT service, auth_value, length(csreq) AS client_csreq, indirect_object_identifier AS target, length(indirect_object_code_identity) AS target_csreq FROM access WHERE client='$CLIENT';"

# -----------------------------------------------------------------
# Verify the grants actually landed, and FAIL if they did not.
#
# This block used to only print the tables above. Two problems with that:
#   1. Nothing checked the result, so a silent TCC failure still let the
#      pipeline continue and snapshot an AMI that could never enroll.
#   2. jpmc-staging-check_ssm only surfaces stdout when the SSM command
#      reports Failed. On success the tables were written and discarded, so
#      the single most important signal was computed and thrown away.
#
# Failing loudly here means a TCC regression surfaces during staging, in
# minutes, instead of as 20 identical enrollment failures hours later.
# -----------------------------------------------------------------
echo ""
echo "Verifying TCC grants..."

acc_ok=$(/usr/bin/sudo /usr/bin/sqlite3 "$SYS_DB" \
  "SELECT COUNT(*) FROM access WHERE client='$CLIENT' AND service='kTCCServiceAccessibility' AND auth_value=2;")
if [[ "$acc_ok" -lt 1 ]]; then
  echo "ERROR: kTCCServiceAccessibility for $CLIENT is missing or not allowed in the system DB." >&2
  echo "       Expected one row with auth_value=2, found $acc_ok." >&2
  exit 1
fi
echo "  kTCCServiceAccessibility: OK"

ae_ok=$(/usr/bin/sqlite3 "$USR_DB" \
  "SELECT COUNT(*) FROM access WHERE client='$CLIENT' AND service='kTCCServiceAppleEvents' AND auth_value=2;")
if [[ "$ae_ok" -lt 1 ]]; then
  echo "ERROR: no allowed kTCCServiceAppleEvents rows for $CLIENT in the user DB." >&2
  echo "       DB: $USR_DB" >&2
  echo "       Without AppleEvents, osascript cannot drive System Settings." >&2
  exit 1
fi
echo "  kTCCServiceAppleEvents: OK ($ae_ok target(s) allowed)"

# A leftover auth_value=0 row for our own client would silently veto enrollment.
denied=$(/usr/bin/sqlite3 "$USR_DB" \
  "SELECT COUNT(*) FROM access WHERE client='$CLIENT' AND auth_value=0;")
if [[ "$denied" -gt 0 ]]; then
  echo "ERROR: found $denied DENIED row(s) for $CLIENT in the user DB." >&2
  /usr/bin/sqlite3 -header -column "$USR_DB" \
    "SELECT service, indirect_object_identifier, auth_value FROM access WHERE client='$CLIENT' AND auth_value=0;" >&2
  exit 1
fi

echo ""
echo "=== Phase 1 complete ==="
echo ""

echo "Waiting 10 seconds before enrollment setup..."
/bin/sleep 10

# =====================================================
# Phase 2: Install cliclick and cache for runtime
# cliclick is used as a coordinate-based click fallback
# when native AppleScript UI interaction fails on Tahoe.
# Binary is cached to /Users/Shared/._jpmc-tools/ so the
# LaunchAgent can use it without needing Homebrew in PATH.
# =====================================================

echo "=== Phase 2: Install cliclick ==="

BREW=""
if [[ "$CLICLICK_SOURCE" == "brew" ]]; then
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    BREW="/opt/homebrew/bin/brew"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    BREW="/usr/local/bin/brew"
  else
    echo "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
      BREW="/opt/homebrew/bin/brew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
      BREW="/usr/local/bin/brew"
    else
      echo "ERROR: Homebrew install completed but brew binary not found" >&2; exit 1
    fi
  fi
fi

if [[ "$CLICLICK_SOURCE" == "brew" ]]; then
  echo "Installing cliclick via Homebrew..."
  export HOMEBREW_NO_AUTO_UPDATE=1
  "$BREW" install cliclick
  CLICLICK_BIN=$("$BREW" --prefix cliclick)/bin/cliclick
  [[ -x "$CLICLICK_BIN" ]] || { echo "ERROR: cliclick not found after Homebrew install" >&2; exit 1; }
else
  echo "Downloading cliclick from $CLICLICK_SOURCE..."
  /usr/bin/curl -fsSL -o /tmp/cliclick "$CLICLICK_SOURCE"
  [[ -s /tmp/cliclick ]] || { echo "ERROR: cliclick download failed or empty" >&2; exit 1; }
  /bin/chmod +x /tmp/cliclick
  CLICLICK_BIN="/tmp/cliclick"
fi

echo "Caching cliclick to /Users/Shared/._jpmc-tools/..."
/usr/bin/sudo /bin/mkdir -p /Users/Shared/._jpmc-tools
/usr/bin/sudo /bin/cp "$CLICLICK_BIN" /Users/Shared/._jpmc-tools/cliclick
/usr/bin/sudo /usr/sbin/chown root:wheel /Users/Shared/._jpmc-tools/cliclick
/usr/bin/sudo /bin/chmod 755 /Users/Shared/._jpmc-tools/cliclick
echo "cliclick cached: $(/Users/Shared/._jpmc-tools/cliclick -V)"

echo ""
echo "=== Phase 2 complete ==="
echo ""

echo "Waiting 30 seconds for Homebrew to settle..."
/bin/sleep 30

# =====================================================
# Phase 3: Download and compile JPMC-EC2-Enroll.scpt
# Downloads the AppleScript source from GitHub and
# compiles it to a .scpt binary for osascript.
# =====================================================

echo "=== Phase 3: Download and compile JPMC-EC2-Enroll.scpt ==="

echo "Downloading JPMC-EC2-Enroll.applescript..."
/usr/bin/curl -fsSL -o /tmp/JPMC-EC2-Enroll.applescript "$ENROLL_SOURCE_URL"
[[ -s /tmp/JPMC-EC2-Enroll.applescript ]] || { echo "ERROR: download failed or empty" >&2; exit 1; }
echo "Downloaded: $(/usr/bin/wc -l < /tmp/JPMC-EC2-Enroll.applescript | /usr/bin/tr -d ' ') lines"

echo "Compiling to .scpt..."
/usr/bin/osacompile -o /tmp/JPMC-EC2-Enroll.scpt /tmp/JPMC-EC2-Enroll.applescript
[[ -s /tmp/JPMC-EC2-Enroll.scpt ]] || { echo "ERROR: compilation failed" >&2; exit 1; }

echo "Installing to /Users/Shared/..."
/usr/bin/sudo /bin/cp /tmp/JPMC-EC2-Enroll.scpt "$ENROLL_SCRIPT"
/usr/bin/sudo /usr/sbin/chown ec2-user:wheel "$ENROLL_SCRIPT"
/usr/bin/sudo /bin/chmod 644 "$ENROLL_SCRIPT"

echo "Installed: $ENROLL_SCRIPT ($(/usr/bin/wc -c < "$ENROLL_SCRIPT" | /usr/bin/tr -d ' ') bytes)"

echo ""
echo "=== Phase 3 complete ==="
echo ""

# =====================================================
# Phase 4: Configure MMSecret and prodFlag
# =====================================================

echo "=== Phase 4: Configure MMSecret ==="

/usr/bin/defaults write com.jpmc.ec2.mdm.enrollment MMSecret "$SECRET_ID"
/usr/bin/defaults write com.jpmc.ec2.mdm.enrollment prodFlag "$PROD_FLAG"

/bin/sleep 5
MMSECRET_CHECK=$(/usr/bin/defaults read com.jpmc.ec2.mdm.enrollment MMSecret 2>/dev/null)
[[ "$MMSECRET_CHECK" == "$SECRET_ID" ]] || { echo "ERROR: MMSecret did not persist" >&2; exit 1; }
echo "MMSecret set: $MMSECRET_CHECK"
echo "prodFlag set: $(/usr/bin/defaults read com.jpmc.ec2.mdm.enrollment prodFlag 2>/dev/null)"

echo ""
echo "=== Phase 4 complete ==="
echo ""

# =====================================================
# Phase 5: Preflight gate
# =====================================================

echo "=== Preflight gate ==="

GATE_OK=1
[[ -s "$ENROLL_SCRIPT" ]]                          || { echo "  FAIL: JPMC-EC2-Enroll.scpt missing"; GATE_OK=0; }
[[ "$MMSECRET_CHECK" == "$SECRET_ID" ]]            || { echo "  FAIL: MMSecret not configured"; GATE_OK=0; }
[[ -x /Users/Shared/._jpmc-tools/cliclick ]]      || { echo "  FAIL: cliclick not cached"; GATE_OK=0; }
[[ $GATE_OK -eq 1 ]] || { echo "ERROR: preflight failed" >&2; exit 1; }
echo "  JPMC-EC2-Enroll.scpt: OK"
echo "  MMSecret:             OK"
echo "  cliclick:             OK"
echo "All preflight checks passed."
echo ""

# =====================================================
# Phase 6: Install LaunchAgent
# Write the plist directly with sudo tee — no osascript,
# no aws CLI, no credential dependency from SSM context.
# =====================================================

echo "=== Phase 6: Install LaunchAgent ==="

/usr/bin/sudo /usr/bin/tee "$LAUNCHAGENT_PLIST" > /dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>com.jpmc.ec2.mdm.enrollment</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/osascript</string>
		<string>/Users/Shared/JPMC-EC2-Enroll.scpt</string>
	</array>
	<key>LaunchEvents</key>
	<dict>
		<key>com.apple.xpc.activity</key>
		<dict>
			<key>com.jpmc.ec2.mdm.enrollment.boot</key>
			<dict>
				<key>Delay</key>
				<integer>30</integer>
				<key>RequireNetworkConnectivity</key>
				<true/>
				<key>GracePeriod</key>
				<integer>3600</integer>
				<key>Priority</key>
				<string>Utility</string>
				<key>Repeating</key>
				<false/>
			</dict>
		</dict>
	</dict>
	<key>ThrottleInterval</key>
	<integer>300</integer>
	<key>StandardErrorPath</key>
	<string>/Library/Logs/JPMC/EC2-Enroll.log</string>
	<key>StandardOutPath</key>
	<string>/Library/Logs/JPMC/EC2-Enroll-out.log</string>
</dict>
</plist>
PLIST

/usr/bin/sudo /usr/sbin/chown root:wheel "$LAUNCHAGENT_PLIST"
/usr/bin/sudo /bin/chmod 644 "$LAUNCHAGENT_PLIST"

[[ -f "$LAUNCHAGENT_PLIST" ]] || { echo "ERROR: LaunchAgent plist not written" >&2; exit 1; }
echo "LaunchAgent installed."

echo ""
echo "=== Phase 6 complete ==="
echo ""

# =====================================================
# Phase 7: Verify
# =====================================================

echo "=== Phase 7: Verify ==="

echo ""
echo "LaunchAgent plist contents:"
/bin/cat "$LAUNCHAGENT_PLIST"

echo ""
# Match the exact label. A bare "enrollment" grep matches com.apple.betaenrollmentd,
# so this check reported success-looking output while verifying nothing.
LAUNCHCTL_CHECK=$(/bin/launchctl list | /usr/bin/grep "com.jpmc.ec2.mdm.enrollment" || true)
if [[ -z "$LAUNCHCTL_CHECK" ]]; then
  echo "  launchctl: OK (LaunchAgent not loaded — correct, no GUI session)"
else
  echo "  launchctl: $LAUNCHCTL_CHECK"
fi

echo ""
echo "=== Phase 7 complete ==="
echo ""

# =====================================================
# Phase 7.5: Suppress per-user Setup Assistant ("Buddy")
#
# THE PROBLEM
# On a fresh AMI boot, per-user Setup Assistant presents a nine-pane wizard and
# runs FRONTMOST as com.apple.SetupAssistant. Confirmed with lsappinfo on
# i-0dd72e64163595dd1: Setup Assistant held "(in front)" while System Settings
# sat at list position 49. cliclick sends PHYSICAL clicks, which land on
# whatever owns the screen, so enrollment failed 16 consecutive times at
# "Install button not found after 10 seconds" even though the preceding
# "MDM Profile found" succeeded (accessibility queries do not need focus).
#
# One pane is an Apple ID sign-in. There is no Apple ID, so it cannot be
# answered headlessly. "tell application settingsApp to activate" does NOT win
# the foreground back from Buddy; that was tested and it does not work.
#
# /var/db/.AppleSetupDone (already present in the AMI) suppresses the DEVICE
# Setup Assistant. It does nothing for the PER-USER Buddy flow, which is what
# we hit.
#
# WHAT WAS REMOVED HERE, AND WHY -- DO NOT PUT IT BACK
# This phase used to carry a "Layer 1" that wrote SkipSetupItems into
#     /Library/Managed Preferences/com.apple.SetupAssistant.managed.plist
# That is Apple's documented mechanism, but it cannot work without MDM. It was
# removed on 2026-10-08 after being disproved on i-0193db62a18036255.
# ManagedClient owns that directory and prunes anything with no backing MDM
# profile. After one boot the file was gone, /Library/Managed Preferences/ held
# only the ec2-user subdirectory, and the system log showed:
#     ManagedClient: Notifying CFPrefsD Of Updated Managed Preferences
#     RemoveObsoleteBMAIDAccounts: checking against 0 MDM profiles
# Zero profiles, so it reaps the file. Delivering it as a real configuration
# profile instead is circular: that needs the MDM enrollment Buddy is blocking.
#
# WHAT ACTUALLY WORKS -- three layers, in the order they take effect
#
# Layer A (below): delete MiniBuddyLaunch from the PER-USER
#   com.apple.loginwindow domain. This is the gate loginwindow actually reads.
#   Found in loginwindow's own log on 2026-10-08:
#       -[Login1 miniBuddyOption]_block_invoke | NOT mbsetupuser, checking pref
#       MiniBuddyLaunch pref is set, setting miniBuddyOption to
#           kMinibuddyOptionMBPrefSet
#       -[Login1 miniBuddyOption] | returning: 2
#       A minibuddy option is set, calling startMiniBuddy
#   After deleting the key, the same code path logged:
#       MiniBuddyLaunch pref is NOT set
#       -[Login1 miniBuddyOption] | returning: 0
#   The gate works. It is necessary but NOT sufficient: Buddy still appeared
#   once via a second launch path carrying no -MiniBuddyYes flag. That second
#   path is why Layer C exists.
#
# Layer B (below): pre-seed the per-user com.apple.SetupAssistant domain so
#   every pane is marked already-seen. Verified to survive the AMI snapshot --
#   on a fresh instance every DidSee* read 1 and every version key read 27.0,
#   including LastSeenGlassTintUpsellProductVersion.
#
#   Layer B is NOT simply "set every DidSee* to 1". macOS 27 tracks panes two
#   different ways, and after manually walking all nine panes these were STILL
#   0: DidSeeActivationLock, DidSeeAppStore, DidSeeApplePaySetup,
#   DidSeeLockdownMode, DidSeeSyncSetup, DidSeeSyncSetup2, DidSeeTermsOfAddress,
#   DidSeeTouchIDSetup. Several panes are gated instead on
#   LastSeen*ProductVersion strings, which re-trigger on every OS version bump.
#   That is why an AMI built in September still showed panes. Those values are
#   computed from sw_vers at runtime so a 27.1 or 28.0 AMI seeds itself.
#
#   The Liquid Glass pane has NO SkipSetupItems key at all. The Setup Assistant
#   binary on macOS 27.0.1 contains GlassSelection, GlassSelectionFlowItem,
#   GlassSelectionViewController and LastSeenGlassTintUpsellProductVersion, but
#   no matching entry in the skip-key vocabulary. Layer B is the only way to
#   suppress it.
#
# Layer C (runtime, in JPMC-EC2-Enroll.applescript): quitSetupAssistant() runs
#   at the top of installProfile and kills Buddy outright if it is on screen.
#   This is the only layer verified to clear it unconditionally. Measured on
#   i-0193db62a18036255: killall succeeded, process count went to 0, frontmost
#   went to none, and it did NOT respawn. Layers A and B reduce how often C has
#   to fire. C is what guarantees the screen is clear at the moment we click.
# =====================================================

echo "=== Phase 7.5: Suppress Setup Assistant ==="

SA_USER=$(/usr/bin/id -un)
SA_PRODUCT_VERSION=$(/usr/bin/sw_vers -productVersion)
SA_BUILD_VERSION=$(/usr/bin/sw_vers -buildVersion)
echo "  user:       ${SA_USER}"
echo "  running OS: ${SA_PRODUCT_VERSION} (${SA_BUILD_VERSION})"
echo ""

# -----------------------------------------------------
# Layer A: the loginwindow MiniBuddy gate
#
# MiniBuddyLaunch lives in the PER-USER com.apple.loginwindow domain, not in
# com.apple.SetupAssistant, which is why earlier versions of this phase never
# touched it and Buddy launched anyway.
#
# `defaults delete` on an absent key exits non-zero, so `|| true` is required
# under `set -euo pipefail`.
#
# The counters are belt-and-braces. loginwindow consults them when
# MiniBuddyLaunch is absent to decide whether a relaunch is still owed; a high
# value reads as "already launched plenty of times".
# -----------------------------------------------------
echo "Layer A: clearing the loginwindow MiniBuddy gate..."
/usr/bin/defaults delete com.apple.loginwindow MiniBuddyLaunch 2>/dev/null || true
/usr/bin/defaults write com.apple.loginwindow MiniBuddyLaunchCount -int 99
/usr/bin/defaults write com.apple.SetupAssistant MiniBuddyRelaunchCounter -int 99

# Fail loudly. If this key survives, every instance from this AMI stalls at
# Buddy's primary launch path and Layer C has to carry the whole load.
if /usr/bin/defaults read com.apple.loginwindow MiniBuddyLaunch > /dev/null 2>&1; then
  echo "ERROR: MiniBuddyLaunch still present in com.apple.loginwindow" >&2
  exit 1
fi
echo "  MiniBuddyLaunch absent, relaunch counters set."
echo ""

# -----------------------------------------------------
# Layer B: pre-seed the per-user Setup Assistant domain
# -----------------------------------------------------
echo "Layer B: pre-seeding com.apple.SetupAssistant for ${SA_USER}..."

# Boolean DidSee* flags. Covers the panes tracked as simple booleans.
for sa_key in \
  DidSeeAccessibility DidSeeActivationLock DidSeeAppStore DidSeeAppearanceSetup \
  DidSeeApplePaySetup DidSeeCloudSetup DidSeeLockdownMode DidSeePrivacy \
  DidSeeScreenTime DidSeeSiriSetup DidSeeSyncSetup DidSeeSyncSetup2 \
  DidSeeTermsOfAddress DidSeeTouchIDSetup DidSeeiCloudLoginForStorageServices \
  SkipExpressSettingsUpdating SkipFirstLoginOptimization
do
  /usr/bin/defaults write com.apple.SetupAssistant "$sa_key" -bool true
done

# Version-keyed panes. These re-present whenever the recorded version differs
# from the running OS, which is the mechanism that defeated the previous AMI.
# LastSeenGlassTintUpsellProductVersion is the Liquid Glass pane, which has no
# SkipSetupItems key and can only be suppressed here.
for sa_vkey in \
  LastSeenBuddyProductVersion LastSeenCloudProductVersion \
  LastSeenDiagnosticsProductVersion LastSeenAgeRangeSelectionProductVersion \
  LastSeenGlassTintUpsellProductVersion LastPreLoginTasksPerformedVersion \
  InitialSetupProductVersion
do
  /usr/bin/defaults write com.apple.SetupAssistant "$sa_vkey" -string "$SA_PRODUCT_VERSION"
done

for sa_bkey in \
  LastSeenBuddyBuildVersion LastPreLoginTasksPerformedBuild InitialSetupBuildVersion
do
  /usr/bin/defaults write com.apple.SetupAssistant "$sa_bkey" -string "$SA_BUILD_VERSION"
done

# MiniBuddyShouldLaunchToResumeSetup is the flag loginwindow checks to relaunch
# Buddy mid-setup. Observed as 0 on a fully-completed box; force it off so a
# partially-seeded state cannot resume the wizard.
/usr/bin/defaults write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false
/usr/bin/defaults write com.apple.SetupAssistant MiniBuddyLaunchedPostMigration -bool false

echo "  pre-seed written."
echo ""
echo "Setup Assistant state after seeding:"
# `grep -c` exits non-zero when the count is 0, and under `set -o pipefail` that
# would abort the whole script on what is only an informational line. The
# real check is the hard gate immediately below.
/usr/bin/defaults read com.apple.SetupAssistant 2>/dev/null | /usr/bin/grep -cE "DidSee|LastSeen|Skip" \
  | /usr/bin/awk '{print "  " $1 " keys set"}' || true

# Fail loudly if the pre-seed did not land. A silent miss means every instance
# from this AMI shows panes again.
if ! /usr/bin/defaults read com.apple.SetupAssistant DidSeeAccessibility > /dev/null 2>&1; then
  echo "ERROR: com.apple.SetupAssistant pre-seed did not persist" >&2
  exit 1
fi

echo ""
echo "  Layer C (runtime killall) lives in JPMC-EC2-Enroll.applescript."
echo ""
echo "=== Phase 7.5 complete ==="
echo ""

# =====================================================
# Phase 8: Configure ec2-macos-init
# =====================================================

echo "=== Phase 8: Configure ec2-macos-init ==="

echo "Setting RandomizePassword = false..."
/usr/bin/sudo /usr/bin/sed -i '' 's/RandomizePassword = true/RandomizePassword = false/' \
  /usr/local/aws/ec2-macos-init/init.toml
/usr/bin/grep "RandomizePassword" /usr/local/aws/ec2-macos-init/init.toml

echo "Clearing ec2-macos-init instance history (all instance IDs)..."
# -all flag is AWS's documented best practice for AMI creation. Removes
# every instance's history from /usr/local/aws/ec2-macos-init/instances/,
# not just the current instance ID. Guarantees the AMI ships with a fully
# blank ec2-macos-init state so the first boot from the AMI is treated as
# a true first boot (SSH key injection, init.toml steps re-run, etc.).
# Ref: https://github.com/aws/ec2-macos-init#clean
/usr/bin/sudo /usr/local/bin/ec2-macos-init clean -all 2>&1
echo "ec2-macos-init history cleared."

# Clear any kernel panic / crash reports written during this instance's lifetime
# (most commonly from the SIP-disable reboot's IOSkywalk 60s busy timeout panic).
# Leaving these on disk would cause every instance launched from the resulting
# AMI to show the "Your computer was restarted because of a problem" dialog at
# first boot, which can block System Settings UI automation during enrollment.
echo "Clearing diagnostic reports so they don't get baked into the AMI..."
# Use find rather than a glob. zsh errors on an unmatched glob and aborts the
# whole command before rm runs, so when no .panic file existed the .ips removal
# silently never happened and `|| true` hid it. Observed on 2026-10-07: three
# .ips files survived into ami-0a72bc453a63ca035.
/usr/bin/sudo /usr/bin/find /Library/Logs/DiagnosticReports -maxdepth 1 \
  \( -name '*.panic' -o -name '*.ips' \) -delete 2>/dev/null || true
echo "Diagnostic reports remaining:"
/usr/bin/sudo /bin/ls /Library/Logs/DiagnosticReports/ 2>/dev/null | /usr/bin/grep -iE "panic|ips" || echo "  (none)"

echo ""
echo "=== Phase 8 complete ==="
echo ""

echo "$(/bin/date): JPMC-stage-enrollment completed successfully."
echo ""
echo "This instance is ready for AMI creation."
echo "Instances launched from the AMI will run JPMC-EC2-Enroll.scpt"
echo "via the LaunchAgent on first GUI login and enroll automatically."
