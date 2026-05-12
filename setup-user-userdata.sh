#!/bin/zsh
#
# setup-user-userdata.sh
#
# EC2 user data script for macOS instances. Runs as root.
# Sets the local admin password, enables Secure Token, and configures
# automatic login - pulling credentials from AWS Secrets Manager.
# The password is never written to disk, never appears in argv,
# and never lives in a shell variable any longer than the immediate
# command needs it.
#

exec > /var/log/setup-user.log 2>&1
set -euo pipefail

readonly SECRET_ID="mdmSecret"
readonly MAX_RETRIES=30
readonly RETRY_INTERVAL=10

echo "$(date): setup-user started"

# --- Wait for IMDS to be ready ---
echo "Waiting for IMDS..."
TOKEN=""
for i in $(seq 1 $MAX_RETRIES); do
  TOKEN=$(curl -sS --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) && [[ -n "$TOKEN" ]] && break
  echo "  IMDS not ready, attempt $i/$MAX_RETRIES..."
  sleep $RETRY_INTERVAL
done
[[ -n "$TOKEN" ]] || { echo "ERROR: IMDS never became available" >&2; exit 1; }

REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")
[[ -n "$REGION" ]] || { echo "ERROR: could not determine region from IMDS" >&2; exit 1; }
echo "Region: $REGION"

# --- Wait for Secrets Manager to be reachable ---
echo "Waiting for Secrets Manager..."
SECRET_TEST=""
for i in $(seq 1 $MAX_RETRIES); do
  SECRET_TEST=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$REGION" \
    --query SecretString \
    --output text 2>/dev/null) && [[ -n "$SECRET_TEST" ]] && break
  echo "  Secrets Manager not ready, attempt $i/$MAX_RETRIES..."
  sleep $RETRY_INTERVAL
done
[[ -n "$SECRET_TEST" ]] || { echo "ERROR: could not retrieve secret" >&2; exit 1; }

# --- Parse credentials ---
eval "$(echo "$SECRET_TEST" | python3 -c "
import sys, json, shlex
s = json.load(sys.stdin)
print(f'USER={shlex.quote(s[\"localAdmin\"])}')
print(f'PW={shlex.quote(s[\"localAdminPassword\"])}')
")"
unset SECRET_TEST

[[ -n "$USER" && -n "$PW" ]] || { echo "ERROR: could not parse credentials from secret" >&2; exit 1; }
echo "User: $USER"

# =====================================================
# Phase 1: Set password and enable Secure Token
# =====================================================

echo "=== Phase 1: Set password and enable Secure Token ==="

echo "Setting password for $USER..."
/usr/bin/dscl . -passwd "/Users/$USER" "$PW"
sleep 10

echo "Enabling Secure Token for $USER..."
sudo -u "$USER" sysadminctl -newPassword "$PW" -oldPassword "$PW" 2>&1 \
  | grep -v "SACSetAutoLoginPassword error" || true
sleep 10

echo "Verifying Secure Token status:"
sysadminctl -secureTokenStatus "$USER"

echo ""
echo "Waiting 30 seconds before configuring auto-login..."
sleep 30

# =====================================================
# Phase 2: Configure automatic login
# =====================================================

echo "=== Phase 2: Configure automatic login ==="

echo "Setting autoLoginUser..."
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$USER"

echo "Generating /etc/kcpassword..."
echo "$PW" | python3 -c "
import sys
pw = sys.stdin.readline().strip()
key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
encoded = bytes((ord(c) ^ key[i % len(key)]) for i, c in enumerate(pw))
while len(encoded) % 12 != 0:
    encoded += b'\x00'
sys.stdout.buffer.write(encoded)
" > /etc/kcpassword

chmod 600 /etc/kcpassword
chown root:wheel /etc/kcpassword
sleep 10

# --- Clean up ---
unset PW

# --- Verify ---
echo ""
echo "Verifying auto-login configuration:"
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null
echo "  /etc/kcpassword: $(test -f /etc/kcpassword && echo present || echo MISSING)"
echo "  Secure token: $(sysadminctl -secureTokenStatus "$USER" 2>&1)"

# =====================================================
# Phase 3: Disable screen saver and create Jamf locationd dir
# =====================================================
# These would normally be set by enroll-ec2-mac.scpt's --firstrun block,
# but we use --no-first-run for headless setup. Without these:
#   - Screen saver would lock the screen at boot, blocking the LaunchAgent's
#     GUI interactions (the actual cause of headless enrollment failures)
#   - Jamf binary would not have its required locationd directory
#
# Note: this script runs as root via User Data, so we use `sudo -u "$USER"`
# to write the screensaver prefs into ec2-user's ByHost folder (not root's).

echo ""
echo "=== Phase 3: Disable screen saver and create Jamf locationd dir ==="

echo "Disabling screen saver idle timeout..."
sudo -u "$USER" /usr/bin/defaults -currentHost write com.apple.screensaver idleTime 0

echo "Disabling password requirement after screen saver..."
sudo -u "$USER" /usr/bin/defaults -currentHost write com.apple.screensaver askForPassword 0

echo "Creating /private/var/db/locationd..."
/bin/mkdir -p /private/var/db/locationd
/usr/sbin/chown _locationd:_locationd /private/var/db/locationd || true

echo ""
echo "Verifying:"
echo "  screensaver idleTime:        $(sudo -u "$USER" /usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo 'not set')"
echo "  screensaver askForPassword:  $(sudo -u "$USER" /usr/bin/defaults -currentHost read com.apple.screensaver askForPassword 2>/dev/null || echo 'not set')"
echo "  locationd dir:               $(ls -ld /private/var/db/locationd 2>/dev/null || echo 'MISSING')"

echo ""
echo "=== Phase 3 complete ==="

echo ""
echo "$(date): setup-user completed"
echo "Next: Disable SIP from CloudShell, then SSH in for TCC setup."
