#!/bin/zsh
#
# setup-tcc.sh
#
# Pre-grant TCC permissions for /usr/bin/osascript so that the EC2 Mac
# Jamf enrollment script (enroll-ec2-mac.scpt) can run headlessly without
# prompting for Accessibility or Automation approvals.
#
# Inserts:
#   System TCC.db: kTCCServiceAccessibility for osascript
#   User TCC.db:   kTCCServiceAppleEvents for osascript -> {System Events,
#                  Finder, System Settings, Safari, BluetoothSetupAssistant}
#
# Requires:
#   SIP disabled
#   Run as ec2-user (NOT sudo) so the user TCC.db is correct
#   sudo available for system DB writes
#
# Idempotent: running multiple times produces the same end state.
#

set -e

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
  '$service', '$CLIENT', 1, 2, 4, 1,
  X'$client_hex', NULL, 0, '$target',
  $target_blob, 0, CAST(strftime('%s','now') AS INTEGER),
  NULL, NULL, 'UNUSED', 0
);
SQL
}

[[ $EUID -eq 0 ]] && { echo "ERROR: do not run as root/sudo (user TCC.db must belong to ec2-user)" >&2; exit 1; }
/usr/bin/csrutil status | /usr/bin/grep -q disabled || { echo "ERROR: SIP must be disabled" >&2; exit 1; }

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
/bin/sleep 2

echo
echo "System DB osascript entries:"
/usr/bin/sudo /usr/bin/sqlite3 -header -column "$SYS_DB" \
  "SELECT service, auth_value, length(csreq) AS csreq_len FROM access WHERE client='$CLIENT';"
echo
echo "User DB osascript entries:"
/usr/bin/sqlite3 -header -column "$USR_DB" \
  "SELECT service, auth_value, length(csreq) AS client_csreq, indirect_object_identifier AS target, length(indirect_object_code_identity) AS target_csreq FROM access WHERE client='$CLIENT';"
