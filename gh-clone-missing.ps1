# Usage: .\gh-clone-missing.ps1 [--dry-run|-d] [--fetch|-f | --update|-u] --org|-o <org-or-user>
# Default mode: clones missing repos for a GitHub org/user into a sibling folder.
# Fetch mode (-f): fetches and reports which repos are stale (read-only, no changes).
# Update mode (-u): DESTRUCTIVE. The "nuclear button": clone missing repos AND
#   hard-reset modified ones to the remote default branch (discards uncommitted
#   work, untracked files, and stashes). Clean repos are left untouched. Makes
#   local match remote in one shot. Use -d to preview.
# Modes (-f / -u) are mutually exclusive; default is CLONE.
# Folder layout: baseRoot/orgRoot/repoRoot  (e.g. GITHUB/gianboc/upgiter)
# Repos are cloned into baseRoot/<target-org>/<repo>

# Script folder
$scriptDir = $PSScriptRoot

# Walk up from a directory to find the nearest .git root
function Get-RepoRoot {
  param([string]$startDir)

  $current = Resolve-Path $startDir
  while ($true) {
    if (Test-Path (Join-Path $current ".git")) {
      return $current
    }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) {
      return $null
    }
    $current = $parent
  }
}

# Force a repo to exactly match origin/<branch>, no matter what state it's in.
# An interrupted merge/rebase/cherry-pick leaves unmerged index entries, and
# git then refuses to switch branches ("you need to resolve your current index
# first"). We abort any in-progress operation and clear the index first, then
# force the checkout and reset. Returns $true on success, $false on failure
# (so one wedged repo doesn't stop a sweep across the whole org).
function Reset-RepoToRemote {
  param([string]$target, [string]$branch)

  # All git output is redirected to $null (*> $null). In PowerShell a function
  # returns everything written to the output stream, so leaking git's stdout
  # here would make the function return an array instead of a clean boolean —
  # and a non-empty array always tests truthy, masking the failure path below.
  # We rely on $LASTEXITCODE (unaffected by the redirection) for success.

  # Bail out of any half-finished operation that's holding the index hostage.
  git -C $target merge --abort       *> $null
  git -C $target rebase --abort      *> $null
  git -C $target cherry-pick --abort *> $null
  git -C $target am --abort          *> $null
  # Clear any remaining unmerged entries so the checkout below can proceed.
  git -C $target reset --hard        *> $null
  # Now force onto the default branch and pin to the remote tip.
  git -C $target checkout -f $branch *> $null
  if ($LASTEXITCODE -ne 0) { return $false }
  git -C $target reset --hard "origin/$branch" *> $null
  if ($LASTEXITCODE -ne 0) { return $false }
  git -C $target clean -fd *> $null
  if ($LASTEXITCODE -ne 0) { return $false }
  git -C $target stash clear *> $null
  return $true
}

# Parse flags
$dryRun = $false
$fetch = $false
$update = $false
$orgArg = $null
for ($i = 0; $i -lt $args.Count; $i++) {
  $arg = $args[$i]
  if ($arg -eq "--dry-run" -or $arg -eq "-d") {
    $dryRun = $true
    continue
  }
  if ($arg -eq "--fetch" -or $arg -eq "-f") {
    $fetch = $true
    continue
  }
  if ($arg -eq "--update" -or $arg -eq "-u") {
    $update = $true
    continue
  }
  if ($arg -eq "--org" -or $arg -eq "-o") {
    if ($i + 1 -ge $args.Count) {
      Write-Error "Missing value for --org"
      exit 1
    }
    $orgArg = $args[$i + 1]
    $i++
    continue
  }
  Write-Error "Unknown argument: $arg"
  Write-Host "Usage: .\gh-clone-missing.ps1 [--dry-run|-d] [--fetch|-f | --update|-u] --org|-o <org-or-user>"
  exit 1
}

# Modes are mutually exclusive
if ($fetch -and $update) {
  Write-Error "-f/--fetch and -u/--update are mutually exclusive."
  Write-Host "Usage: .\gh-clone-missing.ps1 [--dry-run|-d] [--fetch|-f | --update|-u] --org|-o <org-or-user>"
  exit 1
}

# Determine repo root and base folder that contains org folders
$repoRoot = Get-RepoRoot $scriptDir
if (-not $repoRoot) {
  $repoRoot = $scriptDir
}
$orgRoot = Split-Path -Parent $repoRoot
$baseRoot = if ($orgRoot) { Split-Path -Parent $orgRoot } else { Split-Path -Parent $repoRoot }

# Pick the org/user name (required via --org, fallback: repo folder name)
$org = if ($orgArg) { $orgArg } else { Split-Path -Leaf $repoRoot }

# Target org folder is a sibling of this repo (e.g., .../GITHUB/<org>)
$targetRoot = Join-Path $baseRoot $org
if (-not (Test-Path $targetRoot)) {
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
}

# Make sure the GH CLI is installed
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error "gh CLI not found. Run gh-cli-setup.sh (WSL) or install GH CLI for Windows first."
  exit 1
}

if ($dryRun) {
  Write-Host "DRY RUN: no changes will be made"
}
Write-Host "Target folder: $targetRoot"

if ($fetch) {
  # --- FETCH MODE: read-only check for stale repos ---
  Write-Host "Checking repo status for org/user: $org"

  # Initialize counters
  $stale = @()
  $uptodate = @()
  $skipped = @()
  $warnings = @()

  # Iterate over every subdirectory in the target org folder
  Get-ChildItem -Path $targetRoot -Directory | ForEach-Object {
    $repo = $_.Name
    $target = $_.FullName
    $gitDir = Join-Path $target ".git"

    # Skip this repo itself
    if ($target -eq $repoRoot) {
      return
    }

    # Skip directories that are not git repos
    if (-not (Test-Path $gitDir)) {
      $skipped += $repo
      return
    }

    # Detect default branch from origin/HEAD (e.g. "main" or "master")
    # If origin/HEAD is not set (e.g. repo was git-init'd, not cloned), auto-detect it
    $defaultBranch = git -C $target symbolic-ref refs/remotes/origin/HEAD 2>$null
    if ($defaultBranch) {
      $defaultBranch = $defaultBranch -replace '^refs/remotes/origin/', ''
    }
    if (-not $defaultBranch) {
      git -C $target remote set-head origin --auto 2>$null
      $defaultBranch = git -C $target symbolic-ref refs/remotes/origin/HEAD 2>$null
      if ($defaultBranch) {
        $defaultBranch = $defaultBranch -replace '^refs/remotes/origin/', ''
      }
    }
    if (-not $defaultBranch) {
      $warnings += $repo
      Write-Host "  WARN: $repo - cannot detect default branch, skipping"
      return
    }

    # Fetch latest state from remote
    git -C $target fetch origin 2>$null

    # Check each condition to build a reason string
    $currentBranch = git -C $target rev-parse --abbrev-ref HEAD 2>$null
    $localHead = git -C $target rev-parse HEAD 2>$null
    $remoteHead = git -C $target rev-parse "origin/$defaultBranch" 2>$null
    $dirty = git -C $target status --porcelain 2>$null
    $stashList = git -C $target stash list 2>$null

    $reasons = @()
    if ($currentBranch -ne $defaultBranch) {
      $reasons += "on branch '$currentBranch' (not '$defaultBranch')"
    }
    if ($localHead -ne $remoteHead) {
      $reasons += "behind remote"
    }
    if ($dirty) {
      $reasons += "dirty working tree"
    }
    if ($stashList) {
      $stashCount = ($stashList | Measure-Object -Line).Lines
      $reasons += "$stashCount stash(es)"
    }

    if ($reasons.Count -eq 0) {
      $uptodate += $repo
    } else {
      $stale += $repo
      Write-Host "  STALE: $repo - $($reasons -join ', ')"
    }
  }

  # Print a simple summary
  Write-Host ""
  Write-Host "Summary:"
  Write-Host "  Stale:      $($stale.Count)"
  Write-Host "  Up to date: $($uptodate.Count)"
  Write-Host "  Skipped:    $($skipped.Count) (not a git repo)"
  Write-Host "  Warned:     $($warnings.Count) (no default branch)"

  if ($stale.Count -gt 0) {
    Write-Host "  Stale list: $($stale -join ' ')"
  }
  if ($uptodate.Count -gt 0) {
    Write-Host "  Up to date list: $($uptodate -join ' ')"
  }
  if ($skipped.Count -gt 0) {
    Write-Host "  Skipped list: $($skipped -join ' ')"
  }
  if ($warnings.Count -gt 0) {
    Write-Host "  Warning list: $($warnings -join ' ')"
  }

} elseif ($update) {
  # --- UPDATE MODE: clone missing + hard-reset modified ("nuclear button") ---
  # Archived repos are intentionally excluded (--no-archived): mothballed repos
  # should not be cloned or reset back onto your machine.
  Write-Host "Updating org/user: $org (clone missing + hard-reset modified; archived repos skipped)"

  # Get all non-archived repo names from the org via GH CLI
  $repos = gh repo list $org --no-archived --limit 1000 --json name -q '.[].name'

  if (-not $repos) {
    Write-Host "No repositories found for org/user: $org"
    exit 0
  }

  # Initialize counters
  $cloned = @()
  $updated = @()
  $uptodate = @()
  $warnings = @()
  $failed = @()

  $repos -split "`n" | ForEach-Object {
    $repo = $_.Trim()
    if (-not $repo) { return }

    $target = Join-Path $targetRoot $repo
    $gitDir = Join-Path $target ".git"

    # Skip this repo itself to avoid resetting the running script
    if ((Test-Path $gitDir) -and ($target -eq $repoRoot)) {
      $uptodate += $repo
      return
    }

    # CASE A: not a git repo locally
    if (-not (Test-Path $gitDir)) {
      # Path exists but isn't a git repo - don't overwrite, warn instead
      if (Test-Path $target) {
        $warnings += $repo
        return
      }
      # Truly missing - clone
      if ($dryRun) {
        Write-Host "DRY RUN: would clone $org/$repo -> $target"
      } else {
        gh repo clone "$org/$repo" $target
      }
      $cloned += $repo
      return
    }

    # CASE B: repo exists locally - fetch and reset only if stale
    $defaultBranch = git -C $target symbolic-ref refs/remotes/origin/HEAD 2>$null
    if ($defaultBranch) {
      $defaultBranch = $defaultBranch -replace '^refs/remotes/origin/', ''
    }
    if (-not $defaultBranch) {
      git -C $target remote set-head origin --auto 2>$null
      $defaultBranch = git -C $target symbolic-ref refs/remotes/origin/HEAD 2>$null
      if ($defaultBranch) {
        $defaultBranch = $defaultBranch -replace '^refs/remotes/origin/', ''
      }
    }
    if (-not $defaultBranch) {
      $warnings += $repo
      Write-Host "  WARN: $repo - cannot detect default branch, skipping"
      return
    }

    if ($dryRun) {
      Write-Host "DRY RUN: would fetch $repo and reset to origin/$defaultBranch if stale"
      return
    }

    # Fetch latest state from remote
    git -C $target fetch origin

    # Check if repo is already in sync: on default branch, at remote HEAD,
    # clean working tree, and no stashes
    $currentBranch = git -C $target rev-parse --abbrev-ref HEAD 2>$null
    $localHead = git -C $target rev-parse HEAD 2>$null
    $remoteHead = git -C $target rev-parse "origin/$defaultBranch" 2>$null
    $dirty = git -C $target status --porcelain 2>$null
    $stashList = git -C $target stash list 2>$null

    if ($currentBranch -eq $defaultBranch -and `
        $localHead -eq $remoteHead -and `
        -not $dirty -and `
        -not $stashList) {
      $uptodate += $repo
      return
    }

    Write-Host "  Resetting $repo to origin/$defaultBranch ..."
    if (Reset-RepoToRemote $target $defaultBranch) {
      $updated += $repo
    } else {
      $failed += $repo
      Write-Host "  FAILED: $repo - could not reset to origin/$defaultBranch"
    }
  }

  # Print a simple summary
  Write-Host ""
  Write-Host "Summary:"
  Write-Host "  Cloned:     $($cloned.Count)"
  Write-Host "  Updated:    $($updated.Count)"
  Write-Host "  Up to date: $($uptodate.Count)"
  Write-Host "  Warned:     $($warnings.Count)"
  Write-Host "  Failed:     $($failed.Count) (reset error)"

  if ($cloned.Count -gt 0) {
    Write-Host "  Cloned list: $($cloned -join ' ')"
  }
  if ($updated.Count -gt 0) {
    Write-Host "  Updated list: $($updated -join ' ')"
  }
  if ($uptodate.Count -gt 0) {
    Write-Host "  Up to date list: $($uptodate -join ' ')"
  }
  if ($warnings.Count -gt 0) {
    Write-Host "  Warning list: $($warnings -join ' ')"
  }
  if ($failed.Count -gt 0) {
    Write-Host "  Failed list: $($failed -join ' ')"
  }

} else {
  # --- CLONE MODE: clone missing repos ---
  Write-Host "Cloning missing repos from org/user: $org"

  # Get all repo names from the org via GH CLI
  $repos = gh repo list $org --limit 1000 --json name -q '.[].name'

  if (-not $repos) {
    Write-Host "No repositories found for org/user: $org"
    exit 0
  }

  # Initialize counters
  $cloned = @()
  $skipped = @()
  $warnings = @()

  # Loop over each repo and clone only if missing
  $repos -split "`n" | ForEach-Object {
    $repo = $_.Trim()
    if (-not $repo) { return }

    $target = Join-Path $targetRoot $repo
    $gitDir = Join-Path $target ".git"

    # Skip if repo already exists
    if (Test-Path $gitDir) {
      $skipped += $repo
      return
    }

    # Warn if path exists but is not a git repo
    if ((Test-Path $target) -and -not (Test-Path $gitDir)) {
      $warnings += $repo
      return
    }

    # Clone the missing repo (or just print in dry-run)
    if ($dryRun) {
      Write-Host "DRY RUN: would clone $org/$repo -> $target"
    } else {
      gh repo clone "$org/$repo" $target
    }
    $cloned += $repo
  }

  # Print a simple summary
  Write-Host ""
  Write-Host "Summary:"
  Write-Host "  Cloned:  $($cloned.Count)"
  Write-Host "  Skipped: $($skipped.Count)"
  Write-Host "  Warned:  $($warnings.Count)"

  if ($cloned.Count -gt 0) {
    Write-Host "  Cloned list: $($cloned -join ' ')"
  }
  if ($skipped.Count -gt 0) {
    Write-Host "  Skipped list: $($skipped -join ' ')"
  }
  if ($warnings.Count -gt 0) {
    Write-Host "  Warning (path exists without .git): $($warnings -join ' ')"
  }
}
