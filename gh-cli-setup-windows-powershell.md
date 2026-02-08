# GitHub CLI setup (Windows + PowerShell)

This guide installs the GitHub CLI (`gh`) on Windows, ensures it is on your PowerShell PATH (including VS Code terminals), and authenticates to GitHub.

## 1) Install GitHub CLI

Use Winget:

- `winget install --id GitHub.cli -e`

Verify it is installed:

- `winget list --name "GitHub CLI"`

## 2) Ensure `gh` is on PATH (permanent)

Sometimes VS Code terminals do not pick up new PATH entries. Ensure the install folder is on your user PATH and restart VS Code.

The default location is:

- `C:\Program Files\GitHub CLI`

Add it to the user PATH (PowerShell):

- `$ghPath = 'C:\Program Files\GitHub CLI'`
- `$currentUserPath = [Environment]::GetEnvironmentVariable('Path','User')`
- `if ($currentUserPath -notmatch [Regex]::Escape($ghPath)) { [Environment]::SetEnvironmentVariable('Path', ($currentUserPath.TrimEnd(';') + ';' + $ghPath), 'User') }`

Restart VS Code, then verify:

- `where.exe gh`
- `gh --version`

## 3) Authenticate

Start login:

- `gh auth login`

Recommended answers:

- GitHub.com
- HTTPS
- Authenticate Git with your GitHub credentials: Yes
- Login with a web browser

Complete the browser flow quickly (device code expires). When done, verify:

- `gh auth status`

## 4) Optional: set default Git protocol

`gh` usually sets this automatically. To confirm:

- `gh config set -h github.com git_protocol https`

## Troubleshooting

**`gh` not found in VS Code terminal**
- Confirm `C:\Program Files\GitHub CLI` is on your user PATH.
- Restart VS Code to refresh its environment.

**`device_code` expired**
- Re-run `gh auth login` and complete the browser step immediately.

**Using a token instead of browser login**
- Create a classic token with `repo` scope and set:
  - `$env:GH_TOKEN = 'your_token_here'`
- Then run:
  - `gh auth status`
