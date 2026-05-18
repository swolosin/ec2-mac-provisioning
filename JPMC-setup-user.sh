#!/bin/zsh
#
# JPMC-setup-user.sh
#
# Sets the local admin password, enables Secure Token, configures
# auto-login, disables screen saver, and creates the Jamf locationd
# directory — pulling credentials from AWS Secrets Manager.
#
# Passwords are never written to disk, never appear in argv, and
# never live in a shell variable longer than the immediate command needs.
#
# Run via SSH as ec2-user after launching a vanilla macOS EC2 instance.
# Do NOT run as root or via User Data.
#
# Usage:
#   scp -i key.pem JPMC-setup-user.sh ec2-user@<ip>:/tmp/
#   ssh -i key.pem ec2-user@<ip>
#   chmod +x /tmp/JPMC-setup-user.sh && /tmp/JPMC-setup-user.sh
#

set -euo pipefail

readonly SECRET_ID="mdmSecret"

# =====================================================
# Retrieve credentials from Secrets Manager via IMDSv2
# =====================================================

echo "Getting region from IMDS..."
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
[[ -n "$REGION" ]] || { echo "ERROR: could not determine region from IMDS" >&2; exit 1; }
echo "Region: $REGION"

echo "Retrieving credentials from Secrets Manager..."
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
[[ -n "$USER" && -n "$PW" ]] || { echo "ERROR: could not parse credentials" >&2; exit 1; }
echo "User: $USER"

# =====================================================
# Phase 1: Set password and enable Secure Token
# Secure Token is required by the AWS API to disable SIP.
# =====================================================

echo ""
echo "=== Phase 1: Set password and enable Secure Token ==="

echo "Setting password..."
sudo /usr/bin/dscl . -passwd /Users/"$USER" "$PW"
sleep 10

echo "Enabling Secure Token..."
sysadminctl -newPassword "$PW" -oldPassword "$PW" 2>&1 \
  | grep -v "SACSetAutoLoginPassword error" || true
sleep 10

echo "Verifying Secure Token:"
sysadminctl -secureTokenStatus "$USER"

echo ""
echo "Waiting 30 seconds before configuring auto-login..."
sleep 30

# =====================================================
# Phase 2: Configure automatic login
# Required for the LaunchAgent to fire at boot.
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

# Clean up password from memory
unset PW

echo ""
echo "Verifying:"
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null
echo "  /etc/kcpassword: $(sudo test -f /etc/kcpassword && echo present || echo MISSING)"

# =====================================================
# Phase 3: Disable screen saver and create Jamf locationd dir
#
# Screen saver: the --firstrun block in enroll-ec2-mac.scpt sets
# idleTime=0 via -currentHost, but -currentHost writes per-hardware-UUID
# preferences that don't transfer to new AMI instances. Writing both
# -currentHost AND the regular domain ensures the setting applies
# regardless of UUID.
#
# locationd: Jamf binary requires /private/var/db/locationd to exist.
# =====================================================

echo ""
echo "=== Phase 3: Disable screen saver and create Jamf locationd dir ==="

echo "Disabling screen saver (currentHost + user domain)..."
/usr/bin/defaults -currentHost write com.apple.screensaver idleTime 0
/usr/bin/defaults -currentHost write com.apple.screensaver askForPassword 0
/usr/bin/defaults write com.apple.screensaver idleTime 0
/usr/bin/defaults write com.apple.screensaver askForPassword 0

echo "Creating /private/var/db/locationd..."
sudo /bin/mkdir -p /private/var/db/locationd
sudo /usr/sbin/chown _locationd:_locationd /private/var/db/locationd || true

echo ""
echo "Verifying:"
echo "  screensaver idleTime (currentHost): $(/usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo 'not set')"
echo "  screensaver idleTime (user):        $(/usr/bin/defaults read com.apple.screensaver idleTime 2>/dev/null || echo 'not set')"
echo "  locationd dir:                      $(ls -ld /private/var/db/locationd 2>/dev/null || echo 'MISSING')"

echo ""
echo "=== Phase 3 complete ==="

echo ""
echo "=== Done ==="
echo "Next: Disable SIP from CloudShell, then run JPMC-stage-enrollment.sh."
