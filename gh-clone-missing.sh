#!/usr/bin/env bash
set -euo pipefail

# upgiter — bulk GitHub repo manager
#
# Usage: upgiter [-d|--dry-run] [-f|--fetch | -u|--update] -o|--org <org-or-user>
#        (or: ./gh-clone-missing.sh ...  if you haven't set up the alias yet)
#
# Modes (mutually exclusive; default is CLONE):
#   CLONE   (no flag)   Clone every repo of <org> that is missing locally.
#   FETCH   (-f)        Fetch each existing repo and report which are stale.
#                       Read-only: no commits, branches, or files are touched.
#   UPDATE  (-u)        DESTRUCTIVE. The "nuclear button": clone missing repos
#                       AND hard-reset modified ones to the remote default
#                       branch (discards uncommitted work, untracked files, and
#                       stashes). Clean repos are left untouched. Makes local
#                       match remote in one shot. Use -d to preview.
#   -d / --dry-run      Print what would happen without making changes.
#   --serial            Fetch/clone one repo at a time. By DEFAULT upgiter runs
#                       the network work in parallel ((CPU cores - 2) jobs), which
#                       is much faster on a big org; --serial opts out.
#
# Folder layout (required): <base>/<org>/<repo>
#   This script must live at <base>/<org>/upgiter/ — it derives <base> by
#   walking up from its own location. Repos are cloned to <base>/<org>/<repo>.
#   Example: ~/GITHUB/gianboc/upgiter/  →  base = ~/GITHUB
#
# Run from anywhere by adding to ~/.bashrc:
#   alias upgiter='/home/<you>/GITHUB/gianboc/upgiter/gh-clone-missing.sh'

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

# Force a repo to exactly match origin/<branch>, no matter what state it's in.
# Handles the awkward cases that a plain "checkout + reset --hard" chokes on:
# an interrupted merge/rebase/cherry-pick leaves unmerged index entries, and
# git then refuses to switch branches ("you need to resolve your current index
# first"). We abort any in-progress operation and clear the index first, then
# force the checkout and reset.
#
# Returns non-zero on failure instead of letting `set -e` abort the whole run,
# so one wedged repo doesn't stop a sweep across an org of 100 repos.
force_reset_to_remote() {
  local target="$1" branch="$2"
  # Bail out of any half-finished operation that's holding the index hostage.
  git -C "$target" merge --abort       >/dev/null 2>&1 || true
  git -C "$target" rebase --abort      >/dev/null 2>&1 || true
  git -C "$target" cherry-pick --abort >/dev/null 2>&1 || true
  git -C "$target" am --abort          >/dev/null 2>&1 || true
  # Clear any remaining unmerged entries so the checkout below can proceed.
  git -C "$target" reset --hard        >/dev/null 2>&1 || true
  # Now force onto the default branch and pin to the remote tip.
  git -C "$target" checkout -f "$branch"          || return 1
  git -C "$target" reset --hard "origin/$branch"  || return 1
  git -C "$target" clean -fd                      || return 1
  git -C "$target" stash clear                    || true
  return 0
}

# Decide how many parallel jobs to use: (CPU cores - 2), floored at 1. Leaving
# two cores free keeps the machine responsive during a big sweep. Detecting the
# count is a single, sub-millisecond kernel query — negligible next to even one
# network fetch — so we just do it each run. `nproc` (GNU, honours cgroup/CPU
# affinity limits) with a POSIX fallback and a hard floor of 1.
detect_jobs() {
  local cores j
  cores="$( nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1 )"
  j=$((cores - 2))
  [ "$j" -lt 1 ] && j=1
  echo "$j"
}

# Print a full cheatsheet (so you don't have to re-read the source after a month).
show_help() {
  cat <<'EOF'
upgiter — bulk GitHub repo manager

Usage: upgiter [-d] [--serial] [-f | -u] -o <org-or-user>

Modes (pick at most one; default is CLONE):
  (none)  CLONE    Clone repos you're MISSING locally. Existing repos are left
                   alone. Safe — never changes files you already have.
  -f      FETCH    Report which local repos are stale (on another branch, behind
                   remote, dirty, or stashed). Read-only — changes nothing.
  -u      UPDATE   The "nuclear button": make your local folder EXACTLY match
                   GitHub. Clones anything missing AND hard-resets anything
                   modified back to the remote. DESTRUCTIVE — discards local
                   commits, uncommitted changes, untracked files, and stashes.
                   Clean repos and archived repos are left untouched.

Options:
  -d, --dry-run    Show what would happen; change nothing. Pair with -u to preview.
  --serial         Do the network work one repo at a time. By DEFAULT upgiter
                   fetches/clones in parallel ((cores-2) jobs) — much faster on a
                   big org; --serial opts out.
  -o, --org <name> GitHub org/user (required). Repos live in <base>/<name>/<repo>.
  -h, --help       This cheatsheet.

Examples:
  upgiter -o gianboc          # clone anything I'm missing
  upgiter -f -o gianboc       # fast, read-only "what's stale?" report
  upgiter -d -u -o gianboc    # PREVIEW a full sync (safe)
  upgiter -u -o gianboc       # make local match GitHub (destroys local changes)
EOF
}

# Parse flags
DRY_RUN=0
FETCH=0
UPDATE=0
PARALLEL=1   # parallel by default; --serial turns it off
ORG_ARG=""
USAGE="Usage: upgiter [-d|--dry-run] [--serial] [-f|--fetch | -u|--update] -o|--org <org-or-user>"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --dry-run|-d)
      DRY_RUN=1
      shift
      ;;
    --serial)
      PARALLEL=0
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
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done

# Modes are mutually exclusive
if [ "$((FETCH + UPDATE))" -gt 1 ]; then
  echo "Error: -f/--fetch and -u/--update are mutually exclusive." >&2
  echo "$USAGE" >&2
  exit 1
fi

# Resolve the parallel job count once. Parallel is the default; --serial sets
# PARALLEL=0 and pins JOBS=1 so the network work runs one repo at a time.
if [ "$PARALLEL" -eq 1 ]; then
  JOBS="$(detect_jobs)"
else
  JOBS=1
fi

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

  # Parallel pre-fetch (default): the per-repo `git fetch` is network-bound and
  # the calls are independent, so we fire them all through xargs -P first. The
  # analysis loop below then reads already-updated origin/* refs and skips its
  # own inline fetch. Null-delimited paths so folder names with spaces survive.
  # With --serial (PARALLEL=0) this is skipped and each repo is fetched inline.
  if [ "$PARALLEL" -eq 1 ]; then
    echo "Parallel fetch: $JOBS jobs"
    for target in "$TARGET_ROOT"/*/; do
      [ -d "$target/.git" ] || continue
      printf '%s\0' "$target"
    done | xargs -0 -r -P "$JOBS" -I{} git -C {} fetch origin >/dev/null 2>&1 || true
  fi

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
    # If origin/HEAD is not set (e.g. repo was git-init'd, not cloned), auto-detect it
    default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    if [ -z "$default_branch" ]; then
      git -C "$target" remote set-head origin --auto >/dev/null 2>&1 || true
      default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    fi
    if [ -z "$default_branch" ]; then
      warning_count=$((warning_count + 1))
      warning_list="$warning_list $repo"
      echo "  WARN: $repo — cannot detect default branch, skipping"
      continue
    fi

    # Fetch latest state from remote (skipped if the parallel pre-fetch ran)
    if [ "$PARALLEL" -eq 0 ]; then
      git -C "$target" fetch origin 2>/dev/null || true
    fi

    # Check each condition to build a reason string
    current_branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    local_head="$(git -C "$target" rev-parse HEAD 2>/dev/null || true)"
    remote_head="$(git -C "$target" rev-parse "origin/$default_branch" 2>/dev/null || true)"
    dirty="$(git -C "$target" status --porcelain 2>/dev/null || true)"
    stash_count_val="$(git -C "$target" stash list 2>/dev/null | wc -l || true)"

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
  # --- UPDATE MODE: clone missing + hard-reset modified ("nuclear button") ---
  # Archived repos are intentionally excluded (--no-archived): mothballed repos
  # should not be cloned or reset back onto your machine.
  echo "Updating org/user: $ORG (clone missing + hard-reset modified; archived repos skipped)"

  # Get all non-archived repo names from the org via GH CLI
  repos=$(gh repo list "$ORG" --no-archived --limit 1000 --json name -q '.[].name')

  if [ -z "$repos" ]; then
    echo "No repositories found for org: $ORG"
    exit 0
  fi

  # Initialize counters and printable lists
  cloned_count=0
  updated_count=0
  uptodate_count=0
  warning_count=0
  failed_count=0
  cloned_list=""
  updated_list=""
  uptodate_list=""
  warning_list=""
  failed_list=""

  # Parallel pre-pass (default): the network work — cloning missing repos and
  # fetching existing ones — is independent per repo, so we run it concurrently
  # through xargs -P. The serial loop below then does the staleness check and the
  # hard-reset (fast, local) plus all the bookkeeping. --serial (PARALLEL=0)
  # skips this and the loop clones/fetches inline. We snapshot which repos were
  # missing BEFORE cloning so the loop can still tell a freshly-cloned repo
  # (count it as Cloned) from one we already had (maybe reset it).
  cloned_before=" "
  if [ "$PARALLEL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "Parallel network: $JOBS jobs"
    while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      t="$TARGET_ROOT/$repo"
      if [ ! -d "$t/.git" ] && [ ! -e "$t" ]; then
        cloned_before="$cloned_before$repo "
      fi
    done <<EOF
$repos
EOF
    export TARGET_ROOT ORG
    printf '%s\n' "$repos" | grep -v '^[[:space:]]*$' | \
      xargs -r -P "$JOBS" -I{} bash -c '
        repo="$1"; t="$TARGET_ROOT/$repo"
        if [ -d "$t/.git" ]; then
          git -C "$t" fetch origin >/dev/null 2>&1
        elif [ ! -e "$t" ]; then
          gh repo clone "$ORG/$repo" "$t" >/dev/null 2>&1
        fi
      ' _ {} || true
  fi

  while IFS= read -r repo; do
    if [ -z "$repo" ]; then
      continue
    fi

    target="$TARGET_ROOT/$repo"

    # Skip this repo itself to avoid resetting the running script
    if [ -d "$target/.git" ] && [ "$(cd "$target" && pwd)" = "$REPO_ROOT" ]; then
      uptodate_count=$((uptodate_count + 1))
      uptodate_list="$uptodate_list $repo"
      continue
    fi

    # Freshly cloned in the parallel pre-pass? Count it as Cloned and move on
    # (a brand-new clone is already at the remote tip; nothing to reset).
    if [ "$PARALLEL" -eq 1 ]; then
      case "$cloned_before" in
        *" $repo "*)
          if [ -d "$target/.git" ]; then
            cloned_count=$((cloned_count + 1))
            cloned_list="$cloned_list $repo"
            continue
          fi
          ;;
      esac
    fi

    # CASE A: not a git repo locally
    if [ ! -d "$target/.git" ]; then
      # Path exists but isn't a git repo — don't overwrite, warn instead
      if [ -e "$target" ]; then
        warning_count=$((warning_count + 1))
        warning_list="$warning_list $repo"
        continue
      fi
      # Truly missing — clone
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY RUN: would clone $ORG/$repo -> $target"
      else
        gh repo clone "$ORG/$repo" "$target"
      fi
      cloned_count=$((cloned_count + 1))
      cloned_list="$cloned_list $repo"
      continue
    fi

    # CASE B: repo exists locally — fetch and reset only if stale
    default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    if [ -z "$default_branch" ]; then
      git -C "$target" remote set-head origin --auto >/dev/null 2>&1 || true
      default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    fi
    if [ -z "$default_branch" ]; then
      warning_count=$((warning_count + 1))
      warning_list="$warning_list $repo"
      echo "  WARN: $repo — cannot detect default branch, skipping"
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY RUN: would fetch $repo and reset to origin/$default_branch if stale"
      continue
    fi

    # Fetch latest state (skipped if the parallel pre-pass already fetched it)
    if [ "$PARALLEL" -eq 0 ]; then
      git -C "$target" fetch origin || true
    fi

    current_branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    local_head="$(git -C "$target" rev-parse HEAD 2>/dev/null || true)"
    remote_head="$(git -C "$target" rev-parse "origin/$default_branch" 2>/dev/null || true)"
    dirty="$(git -C "$target" status --porcelain 2>/dev/null || true)"
    stash_count="$(git -C "$target" stash list 2>/dev/null | wc -l || true)"

    if [ "$current_branch" = "$default_branch" ] && \
       [ "$local_head" = "$remote_head" ] && \
       [ -z "$dirty" ] && \
       [ "$stash_count" -eq 0 ]; then
      uptodate_count=$((uptodate_count + 1))
      uptodate_list="$uptodate_list $repo"
      continue
    fi

    echo "  Resetting $repo to origin/$default_branch ..."
    if force_reset_to_remote "$target" "$default_branch"; then
      updated_count=$((updated_count + 1))
      updated_list="$updated_list $repo"
    else
      failed_count=$((failed_count + 1))
      failed_list="$failed_list $repo"
      echo "  FAILED: $repo — could not reset to origin/$default_branch"
    fi
  done <<EOF
$repos
EOF

  echo ""
  echo "Summary:"
  echo "  Cloned:     $cloned_count"
  echo "  Updated:    $updated_count"
  echo "  Up to date: $uptodate_count"
  echo "  Warned:     $warning_count"
  echo "  Failed:     $failed_count (reset error)"

  if [ "$cloned_count" -gt 0 ]; then
    echo "  Cloned list: $cloned_list"
  fi
  if [ "$updated_count" -gt 0 ]; then
    echo "  Updated list: $updated_list"
  fi
  if [ "$uptodate_count" -gt 0 ]; then
    echo "  Up to date list: $uptodate_list"
  fi
  if [ "$warning_count" -gt 0 ]; then
    echo "  Warning list: $warning_list"
  fi
  if [ "$failed_count" -gt 0 ]; then
    echo "  Failed list: $failed_list"
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

  # Parallel pre-pass (default): clone all missing repos concurrently, since the
  # clones are independent. The serial loop below then just does the bookkeeping.
  # --serial (PARALLEL=0) skips this and clones inline. Snapshot missing repos
  # first so the loop can tell freshly-cloned (Cloned) from already-present (Skipped).
  cloned_before=" "
  if [ "$PARALLEL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "Parallel clone: $JOBS jobs"
    while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      t="$TARGET_ROOT/$repo"
      if [ ! -d "$t/.git" ] && [ ! -e "$t" ]; then
        cloned_before="$cloned_before$repo "
      fi
    done <<EOF
$repos
EOF
    export TARGET_ROOT ORG
    printf '%s\n' "$repos" | grep -v '^[[:space:]]*$' | \
      xargs -r -P "$JOBS" -I{} bash -c '
        repo="$1"; t="$TARGET_ROOT/$repo"
        if [ ! -e "$t" ]; then
          gh repo clone "$ORG/$repo" "$t" >/dev/null 2>&1
        fi
      ' _ {} || true
  fi

  # Loop over each repo and clone only if missing
  while IFS= read -r repo; do
    if [ -z "$repo" ]; then
      continue
    fi

    target="$TARGET_ROOT/$repo"

    # Freshly cloned in the parallel pre-pass? Count it as Cloned and move on.
    if [ "$PARALLEL" -eq 1 ]; then
      case "$cloned_before" in
        *" $repo "*)
          if [ -d "$target/.git" ]; then
            cloned_count=$((cloned_count + 1))
            cloned_list="$cloned_list $repo"
            continue
          fi
          ;;
      esac
    fi

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
