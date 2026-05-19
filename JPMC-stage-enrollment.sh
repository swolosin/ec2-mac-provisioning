#!/bin/zsh
#
# JPMC-stage-enrollment.sh
#
# Prepares an EC2 Mac staging instance for headless Jamf MDM enrollment.
# Uses JPMC-EC2-Enroll.scpt instead of the AWS enroll-ec2-mac.scpt,
# which fixes:
#   - IMDS retry logic (boot-time exit code 7 failure)
#   - macOS 26 Device Management navigation (sidebarTarget crash)
#   - No external dependencies (no cliclick required)
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
readonly SECRET_ID="mdmSecret"
readonly PROD_FLAG="0"

readonly ENROLL_SCRIPT="/Users/Shared/JPMC-EC2-Enroll.scpt"
readonly ENROLL_SOURCE_URL="https://raw.githubusercontent.com/swolosin/ec2-mac-provisioning/main/JPMC-EC2-Enroll.applescript"
readonly LAUNCHAGENT_PLIST="/Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist"

echo "$(/bin/date): JPMC-stage-enrollment started"
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
readonly USR_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

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

tcc_insert() {
  local db="$1" use_sudo="$2" service="$3" target="$4" client_hex="$5" target_hex="$6"
  local target_blob="NULL"
  [[ -n "$target_hex" ]] && target_blob="X'$target_hex'"
  ${use_sudo} /usr/bin/sqlite3 "$db" <<SQL
INSERT INTO access (
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

echo ""
echo "=== Phase 1 complete ==="
echo ""

echo "Waiting 10 seconds before enrollment setup..."
/bin/sleep 10

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
[[ $GATE_OK -eq 1 ]] || { echo "ERROR: preflight failed" >&2; exit 1; }
echo "  JPMC-EC2-Enroll.scpt: OK"
echo "  MMSecret:             OK"
echo "All preflight checks passed."
echo ""

# =====================================================
# Phase 6: Install LaunchAgent
# JPMC-EC2-Enroll.scpt handles LaunchAgent installation
# via its --launchagent flag, writing the plist directly.
# =====================================================

echo "=== Phase 6: Install LaunchAgent ==="

/usr/bin/env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  /usr/bin/osascript "$ENROLL_SCRIPT" --launchagent --no-first-run

/bin/sleep 5
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
LAUNCHCTL_CHECK=$(/bin/launchctl list | /usr/bin/grep enrollment || true)
if [[ -z "$LAUNCHCTL_CHECK" ]]; then
  echo "  launchctl: OK (LaunchAgent not loaded — correct, no GUI session)"
else
  echo "  launchctl: $LAUNCHCTL_CHECK"
fi

echo ""
echo "=== Phase 7 complete ==="
echo ""

# =====================================================
# Phase 8: Configure ec2-macos-init
# =====================================================

echo "=== Phase 8: Configure ec2-macos-init ==="

echo "Setting RandomizePassword = false..."
/usr/bin/sudo /usr/bin/sed -i '' 's/RandomizePassword = true/RandomizePassword = false/' \
  /usr/local/aws/ec2-macos-init/init.toml
/usr/bin/grep "RandomizePassword" /usr/local/aws/ec2-macos-init/init.toml

echo "Clearing ec2-macos-init instance history..."
/usr/bin/sudo /usr/local/bin/ec2-macos-init clean 2>&1
echo "ec2-macos-init history cleared."

echo ""
echo "=== Phase 8 complete ==="
echo ""

echo "$(/bin/date): JPMC-stage-enrollment completed successfully."
echo ""
echo "This instance is ready for AMI creation."
echo "Instances launched from the AMI will run JPMC-EC2-Enroll.scpt"
echo "via the LaunchAgent on first GUI login and enroll automatically."
