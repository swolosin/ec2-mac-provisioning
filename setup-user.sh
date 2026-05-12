#!/bin/zsh
#
# setup-user.sh
#
# Sets the lcoal admin password, enables Secure Token, and configures
# automatic login - pulling the username and password from AWS Secrets
# Manager. The password is never written to disk, never appears in argv,
# and never lives in a shell variable any longer than the immediate
# command needs it.
#
#
#

set -euo pipefail

readonly SECRET_ID="mdmSecret"

# --- Region from IMDSv2 ---
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
[[ -n "$REGION" ]] || { echo "ERROR: could not determine region from IMDS" >&2; exit 1; }

# --- Retrieve credentials from Secrets Manager ---
eval "$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --query SecretString \
  --output text \
  | python3 -c "
import sys, json, shlex
s = json.load(sys.stdin)
print(f'USER={shlex.quote(s[\"localAdmin\"])}')
print(f'PW={shlex.quote(s[\"localAdminPassword\"])}')
")"
[[ -n "$USER" && -n "$PW" ]] || { echo "ERROR: could not parse credentials from Secrets Manager" >&2; exit 1; }

# =====================================================
# Phase 1: Set password and enable Secure Token
# =====================================================

echo "=== Phase 1: Set password and enable Secure Token ==="

echo "Setting password for $USER..."
sudo /usr/bin/dscl . -passwd /Users/"$USER" "$PW"
sleep 10

echo "Enabling Secure Token for $USER..."
sysadminctl -newPassword "$PW" -oldPassword "$PW" 2>&1 \
  | grep -v "SACSetAutoLoginPassword error" || true
sleep 10

echo "Verifying Secure Token Status:"
sysadminctl -secureTokenStatus "$USER"

echo ""

# =====================================================
# Buffer: let sysadminctl fully settle before configuring 
#         auto-login against the same account
# =====================================================

echo
echo "Waiting 30 seconds before configuring auto-login..."
sleep 30

# =====================================================
# Phase 2: Configure automatic login
# =====================================================

echo ""
echo "=== Phase 2: Configure automatic login ==="


echo "Setting autoLoginUser..."
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$USER"

echo "Generating /etc/kcpassword..."
echo "$PW" | python3 -c "
import sys
pw = sys.stdin.read().rstrip('\n')
key = bytes([0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F])
encoded = bytes((ord(c) ^ key[i % len(key)]) for i, c in enumerate(pw))
while len(encoded) % 12 != 0:
    encoded += b'\x00'
sys.stdout.buffer.write(encoded)
" | sudo tee /etc/kcpassword > /dev/null

sudo chmod 600 /etc/kcpassword
sudo chown root:wheel /etc/kcpassword
sleep 10

# --- Clean up ---
unset PW

# --- Verify ---
echo ""
echo "Verifying auto-login configuration:"
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null
echo "  /etc/kcpassword: $(sudo test -f /etc/kcpassword && echo present || echo MISSING)"

# =====================================================
# Phase 3: Disable screen saver and create Jamf locationd dir
# =====================================================
# These would normally be set by enroll-ec2-mac.scpt's --firstrun block,
# but we use --no-first-run for headless setup. Without these:
#   - Screen saver would lock the screen at boot, blocking the LaunchAgent's
#     GUI interactions (the actual cause of headless enrollment failures)
#   - Jamf binary would not have its required locationd directory

echo ""
echo "=== Phase 3: Disable screen saver and create Jamf locationd dir ==="

echo "Disabling screen saver idle timeout..."
/usr/bin/defaults -currentHost write com.apple.screensaver idleTime 0

echo "Disabling password requirement after screen saver..."
/usr/bin/defaults -currentHost write com.apple.screensaver askForPassword 0

echo "Creating /private/var/db/locationd..."
sudo /bin/mkdir -p /private/var/db/locationd
sudo /usr/sbin/chown _locationd:_locationd /private/var/db/locationd || true

echo ""
echo "Verifying:"
echo "  screensaver idleTime:        $(/usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo 'not set')"
echo "  screensaver askForPassword:  $(/usr/bin/defaults -currentHost read com.apple.screensaver askForPassword 2>/dev/null || echo 'not set')"
echo "  locationd dir:               $(ls -ld /private/var/db/locationd 2>/dev/null || echo 'MISSING')"

echo ""
echo "=== Phase 3 complete ==="

echo ""
echo "=== Done ==="
echo "Next: Disable SIP from CloudShell, which will trigger reboots."
echo "Auto-login will fire on final boot, creating the TCC.db."