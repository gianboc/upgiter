#!/usr/bin/env bash
set -euo pipefail

# Usage: ./gh-clone-missing.sh [--dry-run|-d] [--fetch|-f] [--update|-u] --org|-o <org-or-user>
# Default mode: clones missing repos for a GitHub org/user into a sibling folder.
# Fetch mode (-f): fetches and reports which repos are stale (read-only, no changes).
# Update mode (-u): hard-resets every existing repo to its remote default branch.
# Folder layout: BASE_ROOT/ORG_ROOT/REPO_ROOT  (e.g. GITHUB/gianboc/upgiter)
# Repos are cloned into BASE_ROOT/<target-org>/<repo>

# Script folder
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Walk up from a directory to find the nearest .git root
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
FETCH=0
UPDATE=0
ORG_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-d)
      DRY_RUN=1
      shift
      ;;
    --fetch|-f)
      FETCH=1
      shift
      ;;
    --update|-u)
      UPDATE=1
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
      echo "Usage: ./gh-clone-missing.sh [--dry-run|-d] [--fetch|-f] [--update|-u] --org|-o <org-or-user>" >&2
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
  echo "DRY RUN: no changes will be made"
fi
echo "Target folder: $TARGET_ROOT"

if [ "$FETCH" -eq 1 ]; then
  # --- FETCH MODE: read-only check for stale repos ---
  echo "Checking repo status for org/user: $ORG"

  # Initialize counters and printable lists
  stale_count=0
  uptodate_count=0
  skipped_count=0
  warning_count=0
  stale_list=""
  uptodate_list=""
  skipped_list=""
  warning_list=""

  # Iterate over every subdirectory in the target org folder
  for target in "$TARGET_ROOT"/*/; do
    [ -d "$target" ] || continue
    repo="$(basename "$target")"

    # Skip this repo itself
    if [ "$(cd "$target" && pwd)" = "$REPO_ROOT" ]; then
      continue
    fi

    # Skip directories that are not git repos
    if [ ! -d "$target/.git" ]; then
      skipped_count=$((skipped_count + 1))
      skipped_list="$skipped_list $repo"
      continue
    fi

    # Detect default branch from origin/HEAD (e.g. "main" or "master")
    default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    if [ -z "$default_branch" ]; then
      warning_count=$((warning_count + 1))
      warning_list="$warning_list $repo"
      echo "  WARN: $repo — cannot detect default branch, skipping"
      continue
    fi

    # Fetch latest state from remote
    git -C "$target" fetch origin 2>/dev/null

    # Check each condition to build a reason string
    current_branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    local_head="$(git -C "$target" rev-parse HEAD 2>/dev/null)"
    remote_head="$(git -C "$target" rev-parse "origin/$default_branch" 2>/dev/null)"
    dirty="$(git -C "$target" status --porcelain 2>/dev/null)"
    stash_count_val="$(git -C "$target" stash list 2>/dev/null | wc -l)"

    reasons=""
    if [ "$current_branch" != "$default_branch" ]; then
      reasons="$reasons on branch '$current_branch' (not '$default_branch'),"
    fi
    if [ "$local_head" != "$remote_head" ]; then
      reasons="$reasons behind remote,"
    fi
    if [ -n "$dirty" ]; then
      reasons="$reasons dirty working tree,"
    fi
    if [ "$stash_count_val" -gt 0 ]; then
      reasons="$reasons $stash_count_val stash(es),"
    fi

    if [ -z "$reasons" ]; then
      uptodate_count=$((uptodate_count + 1))
      uptodate_list="$uptodate_list $repo"
    else
      # Remove trailing comma
      reasons="$(echo "$reasons" | sed 's/,$//')"
      stale_count=$((stale_count + 1))
      stale_list="$stale_list $repo"
      echo "  STALE: $repo —$reasons"
    fi
  done

  # Print a simple summary
  echo ""
  echo "Summary:"
  echo "  Stale:      $stale_count"
  echo "  Up to date: $uptodate_count"
  echo "  Skipped:    $skipped_count (not a git repo)"
  echo "  Warned:     $warning_count (no default branch)"

  if [ "$stale_count" -gt 0 ]; then
    echo "  Stale list: $stale_list"
  fi
  if [ "$uptodate_count" -gt 0 ]; then
    echo "  Up to date list: $uptodate_list"
  fi
  if [ "$skipped_count" -gt 0 ]; then
    echo "  Skipped list: $skipped_list"
  fi
  if [ "$warning_count" -gt 0 ]; then
    echo "  Warning list: $warning_list"
  fi

elif [ "$UPDATE" -eq 1 ]; then
  # --- UPDATE MODE: hard-reset existing repos to remote default branch ---
  echo "Updating existing repos for org/user: $ORG"

  # Initialize counters and printable lists
  updated_count=0
  uptodate_count=0
  skipped_count=0
  warning_count=0
  updated_list=""
  uptodate_list=""
  skipped_list=""
  warning_list=""

  # Iterate over every subdirectory in the target org folder
  for target in "$TARGET_ROOT"/*/; do
    [ -d "$target" ] || continue
    repo="$(basename "$target")"

    # Skip this repo itself to avoid resetting the running script
    if [ "$(cd "$target" && pwd)" = "$REPO_ROOT" ]; then
      continue
    fi

    # Skip directories that are not git repos
    if [ ! -d "$target/.git" ]; then
      skipped_count=$((skipped_count + 1))
      skipped_list="$skipped_list $repo"
      continue
    fi

    # Detect default branch from origin/HEAD (e.g. "main" or "master")
    default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    if [ -z "$default_branch" ]; then
      warning_count=$((warning_count + 1))
      warning_list="$warning_list $repo"
      echo "  WARN: $repo — cannot detect default branch, skipping"
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY RUN: would reset $repo to origin/$default_branch"
      updated_count=$((updated_count + 1))
      updated_list="$updated_list $repo"
    else
      # Fetch latest state from remote
      git -C "$target" fetch origin

      # Check if repo is already in sync: on default branch, at remote HEAD,
      # clean working tree, and no stashes
      current_branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      local_head="$(git -C "$target" rev-parse HEAD 2>/dev/null)"
      remote_head="$(git -C "$target" rev-parse "origin/$default_branch" 2>/dev/null)"
      dirty="$(git -C "$target" status --porcelain 2>/dev/null)"
      stash_count="$(git -C "$target" stash list 2>/dev/null | wc -l)"

      if [ "$current_branch" = "$default_branch" ] && \
         [ "$local_head" = "$remote_head" ] && \
         [ -z "$dirty" ] && \
         [ "$stash_count" -eq 0 ]; then
        uptodate_count=$((uptodate_count + 1))
        uptodate_list="$uptodate_list $repo"
        continue
      fi

      echo "  Resetting $repo to origin/$default_branch ..."
      # Switch to the default branch
      git -C "$target" checkout "$default_branch"
      # Discard all local commits and staged/unstaged changes
      git -C "$target" reset --hard "origin/$default_branch"
      # Remove untracked files and directories
      git -C "$target" clean -fd
      # Drop all stashes
      git -C "$target" stash clear

      updated_count=$((updated_count + 1))
      updated_list="$updated_list $repo"
    fi
  done

  # Print a simple summary
  echo ""
  echo "Summary:"
  echo "  Updated:    $updated_count"
  echo "  Up to date: $uptodate_count"
  echo "  Skipped:    $skipped_count (not a git repo)"
  echo "  Warned:     $warning_count (no default branch)"

  if [ "$updated_count" -gt 0 ]; then
    echo "  Updated list: $updated_list"
  fi
  if [ "$uptodate_count" -gt 0 ]; then
    echo "  Up to date list: $uptodate_list"
  fi
  if [ "$skipped_count" -gt 0 ]; then
    echo "  Skipped list: $skipped_list"
  fi
  if [ "$warning_count" -gt 0 ]; then
    echo "  Warning list: $warning_list"
  fi

else
  # --- CLONE MODE: clone missing repos ---
  echo "Cloning missing repos from org/user: $ORG"

  # Get all repo names from the org via GH CLI
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
fi
