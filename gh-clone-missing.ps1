# Usage: .\gh-clone-missing.ps1 [--dry-run|-n] --org|-o <org-or-user>
# Clones missing repos for a GitHub org/user into a sibling folder. Defaults to this repo's name.
# Folder layout: baseRoot/orgRoot/repoRoot  (e.g. GITHUB/gianboc/upgiter)
# Repos are cloned into baseRoot/<target-org>/<repo>

# Script folder
$scriptDir = $PSScriptRoot

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

# Parse flags
$dryRun = $false
$orgArg = $null
for ($i = 0; $i -lt $args.Count; $i++) {
  $arg = $args[$i]
  if ($arg -eq "--dry-run" -or $arg -eq "-n") {
    $dryRun = $true
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
  Write-Host "Usage: .\gh-clone-missing.ps1 [--dry-run|-n] --org|-o <org-or-user>"
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
  Write-Host "DRY RUN: no clones will be performed"
}
Write-Host "Cloning missing repos from org/user: $org"
Write-Host "Target folder: $targetRoot"

# Get all repo names from the org/user
$repos = gh repo list $org --limit 1000 --json name -q '.[].name'

if (-not $repos) {
  Write-Host "No repositories found for org/user: $org"
  exit 0
}

# Initialize counters and printable lists
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
