#!/bin/bash
#
# disable-sip.sh
#
# Disable SIP on an EC2 Mac instance, pulling the local admin password from
# AWS Secrets Manager. Replaces the manual `echo > tmpCredentials` flow
# from the runbook's Step 2.
#
# IMPORTANT: This script runs in AWS CloudShell, NOT on the Mac itself.
# The AWS CLI's create-mac-system-integrity-protection-modification-task
# requires --mac-credentials as a file path; there is no stdin or inline
# alternative. We minimize on-disk exposure by writing to a 0600 temp file
# and deleting it immediately on success or failure.
#
# Usage:
#   ./disable-sip.sh <instance-id>
#
# Example:
#   ./disable-sip.sh i-0722683db9551fed7
#
# Requires:
#   AWS CloudShell (or any host with AWS CLI configured)
#   AWS_REGION env var or pass --region flag separately
#   Permission to call ec2:CreateMacSystemIntegrityProtectionModificationTask
#

set -euo pipefail

INSTANCE_ID="${1:-}"
SECRET_ID="${SECRET_ID:-mdmSecret}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 <instance-id>"
  echo "  Optional env vars: SECRET_ID (default: mdmSecret), AWS_REGION (default: us-east-2)"
  exit 1
fi

# Temp file with mode 0600, in user's HOME (NOT /tmp on shared systems)
TMP_FILE=$(mktemp -t mac-creds-XXXXXX)
chmod 600 "$TMP_FILE"
trap 'shred -u "$TMP_FILE" 2>/dev/null || rm -f "$TMP_FILE"' EXIT

echo "Building credentials file from Secrets Manager..."
aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --query SecretString \
  --output text \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)
print(json.dumps({
    'rootVolumeUsername': s['localAdmin'],
    'rootVolumePassword': s['localAdminPassword']
}))
" > "$TMP_FILE"

echo "Submitting SIP disable task for $INSTANCE_ID..."
RESULT=$(aws ec2 create-mac-system-integrity-protection-modification-task \
  --instance-id "$INSTANCE_ID" \
  --mac-credentials "file://$TMP_FILE" \
  --mac-system-integrity-protection-status disabled \
  --region "$REGION" \
  --output json)

TASK_ID=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['MacModificationTask']['MacModificationTaskId'])")

echo
echo "Task created: $TASK_ID"
echo "Plan for up to 2.5 hours. Monitor with:"
echo
echo "  aws ec2 describe-mac-modification-tasks \\"
echo "    --mac-modification-task-ids $TASK_ID \\"
echo "    --region $REGION \\"
echo "    --query 'MacModificationTasks[0].TaskState' \\"
echo "    --output text"
