#!/usr/bin/env bash
set -euo pipefail

# Install prerequisites for fetching the GH CLI key
sudo apt update
sudo apt install -y wget

# Add GitHub CLI signing key to apt keyrings
sudo mkdir -p -m 755 /etc/apt/keyrings
out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$out" >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

# Register the GitHub CLI apt repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
| sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

# Install GitHub CLI
sudo apt update
sudo apt install -y gh

# Verify GH CLI installation
gh --version

###############################
# Authenticate GH CLI
gh auth login

######################
# Configure git integration for GH
gh auth setup-git


# Prefer HTTPS for git operations via GH
#### otherwise it fails when autocheking because it uses ssh by default
gh config set git_protocol https