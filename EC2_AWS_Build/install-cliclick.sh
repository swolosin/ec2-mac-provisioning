#!/bin/zsh
#
# install-cliclick.sh
#
# Install cliclick via Homebrew on an EC2 Mac for use by the Jamf enrollment
# script (enroll-ec2-mac.scpt).
#
# Requires:
#   Run as ec2-user (NOT sudo - Homebrew refuses to run as root)
#   Internet access to brew.sh and GitHub
#
# Idempotent: skips work if cliclick is already installed.
#

set -e

readonly INSTALL_PATH="/usr/local/bin/cliclick"
readonly BREW_APPLE_SILICON="/opt/homebrew/bin/brew"
readonly BREW_INTEL="/usr/local/bin/brew"

[[ $EUID -eq 0 ]] && { echo "ERROR: do not run as root/sudo (Homebrew refuses)" >&2; exit 1; }

# Already installed?
if [[ -x "$INSTALL_PATH" ]] && "$INSTALL_PATH" -V >/dev/null 2>&1; then
  echo "cliclick already installed at $INSTALL_PATH"
  "$INSTALL_PATH" -V
  exit 0
fi

# Locate brew (Apple silicon vs Intel paths differ)
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

# brew puts it at /opt/homebrew/bin or /usr/local/bin depending on arch.
# Symlink to /usr/local/bin/cliclick so the enrollment script finds it.
BREW_CLICLICK=$("$BREW" --prefix cliclick)/bin/cliclick
if [[ "$BREW_CLICLICK" != "$INSTALL_PATH" ]]; then
  echo "Symlinking $BREW_CLICLICK -> $INSTALL_PATH"
  /usr/bin/sudo /bin/mkdir -p /usr/local/bin
  /usr/bin/sudo /bin/ln -sf "$BREW_CLICLICK" "$INSTALL_PATH"
fi

echo
"$INSTALL_PATH" -V
