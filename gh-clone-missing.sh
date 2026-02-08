#!/usr/bin/env bash
set -euo pipefail

# Usage: ./gh-clone-missing.sh [--dry-run|-d] --org|-o <org-or-user>
# Clones missing repos for a GitHub org/user into a sibling folder. Defaults to this repo's name.
# Folder layout: BASE_ROOT/ORG_ROOT/REPO_ROOT  (e.g. GITHUB/gianboc/upgiter)
# Repos are cloned into BASE_ROOT/<target-org>/<repo>
# Script folder
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

get_repo_root() {
  local dir="$1"
  while true; do
    if [ -d "$dir/.git" ]; then
      echo "$dir"
      return 0
    fi
    local parent
    parent="$(dirname "$dir")"
    if [ "$parent" = "$dir" ]; then
      return 1
    fi
    dir="$parent"
  done
}

# Parse flags
DRY_RUN=0
ORG_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-d)
      DRY_RUN=1
      shift
      ;;
    --org|-o)
      if [ -z "${2:-}" ]; then
        echo "Missing value for --org" >&2
        exit 1
      fi
      ORG_ARG="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: ./gh-clone-missing.sh [--dry-run|-d] --org|-o <org-or-user>" >&2
      exit 1
      ;;
  esac
done

# Determine repo root and base folder that contains org folders
REPO_ROOT="$(get_repo_root "$SCRIPT_DIR" || true)"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$SCRIPT_DIR"
fi
ORG_ROOT="$(dirname "$REPO_ROOT")"
BASE_ROOT="$(dirname "$ORG_ROOT")"

# Pick the org/user name (required via --org, fallback: repo folder name)
if [ -n "$ORG_ARG" ]; then
  ORG="$ORG_ARG"
else
  ORG="$(basename "$REPO_ROOT")"
fi

# Target org folder is a sibling of this repo (e.g., .../GITHUB/<org>)
TARGET_ROOT="$BASE_ROOT/$ORG"
mkdir -p "$TARGET_ROOT"

# Make sure the GH CLI is installed
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Run gh-cli-setup.sh first." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: no clones will be performed"
fi
echo "Cloning missing repos from org/user: $ORG"
echo "Target folder: $TARGET_ROOT"

# Get all repo names from the org
repos=$(gh repo list "$ORG" --limit 1000 --json name -q '.[].name')

if [ -z "$repos" ]; then
  echo "No repositories found for org: $ORG"
  exit 0
fi

# Initialize counters and printable lists
cloned_count=0
skipped_count=0
warning_count=0
cloned_list=""
skipped_list=""
warning_list=""

# Loop over each repo and clone only if missing
while IFS= read -r repo; do
  if [ -z "$repo" ]; then
    continue
  fi

  target="$TARGET_ROOT/$repo"

  # Skip if repo already exists
  if [ -d "$target/.git" ]; then
    skipped_count=$((skipped_count + 1))
    skipped_list="$skipped_list $repo"
    continue
  fi

  # Warn if path exists but is not a git repo
  if [ -e "$target" ] && [ ! -d "$target/.git" ]; then
    warning_count=$((warning_count + 1))
    warning_list="$warning_list $repo"
    continue
  fi

  # Clone the missing repo (or just print in dry-run)
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: would clone $ORG/$repo -> $target"
  else
    gh repo clone "$ORG/$repo" "$target"
  fi
  
  cloned_count=$((cloned_count + 1))
  cloned_list="$cloned_list $repo"
done <<EOF
$repos
EOF

# Print a simple summary
echo ""
echo "Summary:"
echo "  Cloned:  $cloned_count"
echo "  Skipped: $skipped_count"
echo "  Warned:  $warning_count"

if [ "$cloned_count" -gt 0 ]; then
  echo "  Cloned list: $cloned_list"
fi

if [ "$skipped_count" -gt 0 ]; then
  echo "  Skipped list: $skipped_list"
fi

if [ "$warning_count" -gt 0 ]; then
  echo "  Warning (path exists without .git): $warning_list"
fi