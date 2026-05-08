#!/bin/zsh
#
# stage-enrollment.sh
#
# Prepares a staging EC2 Mac instance for MDM enrollment AMI creation:
#   1. Pre-grant TCC permissions for osascript (Accessibility + AppleEvents)
#   2. Install cliclick via Homebrew
#   3. Download enroll-ec2-mac.scpt from the AWS sample repo
#   4. Configure MMSecret
#   5. Install the LaunchAgent
#   6. Verify everything is in place
#
# Requirements:
#   - Run as ec2-user (NOT root/sudo)
#   - SIP must be disabled
#   - Internet access
#

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

set -euo pipefail

readonly ENROLL_SCRIPT="/Users/Shared/enroll-ec2-mac.scpt"
readonly ENROLL_SCRIPT_URL="https://raw.githubusercontent.com/aws-samples/amazon-ec2-mac-mdm-enrollment-automation/main/enroll-ec2-mac.scpt"
readonly LAUNCHAGENT_PLIST="/Library/LaunchAgents/com.amazon.dsx.ec2.enrollment.automation.startup.plist"
readonly CLICLICK="/usr/local/bin/cliclick"
readonly BREW_APPLE_SILICON="/opt/homebrew/bin/brew"
readonly BREW_INTEL="/usr/local/bin/brew"

echo "$(/bin/date): stage-enrollment started"
echo ""

# --- Preflight checks ---
[[ $EUID -eq 0 ]] && { echo "ERROR: run as ec2-user, not root" >&2; exit 1; }
/usr/bin/csrutil status | /usr/bin/grep -q disabled || { echo "ERROR: SIP must be disabled before running this script" >&2; exit 1; }

# =====================================================
# Phase 1: TCC Setup
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
client_hex=$(csreq_hex "$CLIENT") || { echo "ERROR: failed to generate csreq for $CLIENT" >&2; exit 1; }

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

# =====================================================
# Phase 2: Install cliclick
# =====================================================

echo "=== Phase 2: Install cliclick ==="

if [[ -x "$CLICLICK" ]] && "$CLICLICK" -V >/dev/null 2>&1; then
  echo "cliclick already installed at $CLICLICK"
  "$CLICLICK" -V
else
  if [[ -x "$BREW_APPLE_SILICON" ]]; then
    BREW="$BREW_APPLE_SILICON"
  elif [[ -x "$BREW_INTEL" ]]; then
    BREW="$BREW_INTEL"
  else
    echo "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x "$BREW_APPLE_SILICON" ]]; then
      BREW="$BREW_APPLE_SILICON"
    elif [[ -x "$BREW_INTEL" ]]; then
      BREW="$BREW_INTEL"
    else
      echo "ERROR: Homebrew install completed but brew binary not found" >&2
      exit 1
    fi
  fi

  echo "Installing cliclick via $BREW..."
  "$BREW" install cliclick

  BREW_CLICLICK=$("$BREW" --prefix cliclick)/bin/cliclick
  if [[ "$BREW_CLICLICK" != "$CLICLICK" ]]; then
    echo "Symlinking $BREW_CLICLICK -> $CLICLICK"
    /usr/bin/sudo /bin/mkdir -p /usr/local/bin
    /usr/bin/sudo /bin/ln -sf "$BREW_CLICLICK" "$CLICLICK"
  fi
fi

[[ -x "$CLICLICK" ]] && "$CLICLICK" -V >/dev/null 2>&1 || { echo "ERROR: cliclick not functional after install" >&2; exit 1; }
echo "cliclick: $("$CLICLICK" -V)"
echo "Waiting 10 seconds for cliclick install to settle..."
/bin/sleep 10

echo ""
echo "=== Phase 2 complete ==="
echo ""

# =====================================================
# Buffer: let Homebrew and tccd fully settle
# =====================================================

echo "Waiting 30 seconds before enrollment setup..."
/bin/sleep 30

# =====================================================
# Phase 3: Download Enrollment Script
# =====================================================

echo "=== Phase 3: Download enroll-ec2-mac.scpt ==="

/usr/bin/sudo /usr/bin/curl -fsSL -o "$ENROLL_SCRIPT" "$ENROLL_SCRIPT_URL"
/usr/bin/sudo /usr/sbin/chown root:wheel "$ENROLL_SCRIPT"
/usr/bin/sudo /bin/chmod 644 "$ENROLL_SCRIPT"

[[ -s "$ENROLL_SCRIPT" ]] || { echo "ERROR: enroll-ec2-mac.scpt download failed or empty" >&2; exit 1; }
echo "Downloaded: $ENROLL_SCRIPT ($(/usr/bin/wc -c < "$ENROLL_SCRIPT" | /usr/bin/tr -d ' ') bytes)"
echo "Waiting 5 seconds for filesystem to settle..."
/bin/sleep 5

echo ""
echo "=== Phase 3 complete ==="
echo ""

# =====================================================
# Phase 4: Configure MMSecret
# =====================================================

echo "=== Phase 4: Configure MMSecret ==="

/usr/bin/defaults write com.amazon.dsx.ec2.enrollment.automation MMSecret "mdmSecret"

echo "Waiting 5 seconds for defaults to commit..."
/bin/sleep 5
MMSECRET_CHECK=$(/usr/bin/defaults read com.amazon.dsx.ec2.enrollment.automation MMSecret 2>/dev/null)
[[ "$MMSECRET_CHECK" == "mdmSecret" ]] || { echo "ERROR: MMSecret did not persist after write" >&2; exit 1; }
echo "MMSecret set: $MMSECRET_CHECK"

echo ""
echo "=== Phase 4 complete ==="
echo ""

# =====================================================
# Phase 5: Preflight gate before grand finale
# =====================================================

echo "=== Preflight gate ==="

GATE_OK=1

[[ -x "$CLICLICK" ]] && "$CLICLICK" -V >/dev/null 2>&1 || { echo "  FAIL: cliclick not ready"; GATE_OK=0; }
[[ -s "$ENROLL_SCRIPT" ]]                               || { echo "  FAIL: enroll-ec2-mac.scpt missing"; GATE_OK=0; }
[[ "$MMSECRET_CHECK" == "mdmSecret" ]]                  || { echo "  FAIL: MMSecret not configured"; GATE_OK=0; }

[[ $GATE_OK -eq 1 ]] || { echo "ERROR: preflight checks failed, aborting" >&2; exit 1; }
echo "  cliclick:          OK"
echo "  enroll-ec2-mac:    OK"
echo "  MMSecret:          OK"
echo "All preflight checks passed."
echo ""

# =====================================================
# Phase 6: Install LaunchAgent
# =====================================================

echo "=== Phase 6: Install LaunchAgent ==="

/usr/bin/env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/osascript "$ENROLL_SCRIPT" --launchagent --no-first-run
echo "Waiting 5 seconds for LaunchAgent plist to be written..."
/bin/sleep 5

[[ -f "$LAUNCHAGENT_PLIST" ]] || { echo "ERROR: LaunchAgent plist not written" >&2; exit 1; }

echo ""
echo "=== Phase 6 complete ==="
echo ""

# =====================================================
# Phase 7: Verify
# =====================================================

echo "=== Phase 7: Verify ==="

FIRSTRUN_COUNT=$(/usr/bin/grep -c firstrun "$LAUNCHAGENT_PLIST" 2>/dev/null || true)
[[ "$FIRSTRUN_COUNT" -eq 0 ]] || { echo "ERROR: LaunchAgent plist contains 'firstrun' — --no-first-run flag may not have worked" >&2; exit 1; }
echo "  firstrun check:    OK (count=$FIRSTRUN_COUNT)"

echo ""
echo "LaunchAgent plist contents:"
/bin/cat "$LAUNCHAGENT_PLIST"

echo ""
LAUNCHCTL_CHECK=$(/bin/launchctl list | /usr/bin/grep enrollment || true)
if [[ -z "$LAUNCHCTL_CHECK" ]]; then
  echo "  launchctl:         OK (LaunchAgent not loaded — correct, no GUI session)"
else
  echo "  launchctl:         $LAUNCHCTL_CHECK"
fi

echo ""
echo "=== Phase 7 complete ==="
echo ""

# =====================================================
# Done
# =====================================================

echo "$(/bin/date): stage-enrollment completed successfully."
echo ""
echo "This instance is ready for AMI creation."
echo "Next: create the AMI from this instance. Instances launched from that AMI"
echo "will run the LaunchAgent on first GUI login and enroll automatically."
