# upgiter

Bulk-manage every repo under a GitHub org or user account from one command.
Four modes:

- **Clone** missing repos into your local mirror.
- **Fetch** and report which local repos are stale.
- **Update** (hard-reset) every local repo to its remote default branch.
- **Sync** — the nuclear button: clone missing + hard-reset modified, in one shot.

Underneath it's just `gh` + `git` in a loop, but with a consistent folder
layout and a one-screen summary at the end.

## Setup

Add this line to `~/.bashrc` (adjust the path if your clone lives elsewhere):

```bash
alias upgiter='/home/gianluca/GITHUB/gianboc/upgiter/gh-clone-missing.sh'
```

Then `source ~/.bashrc` (or open a new shell). After that, `upgiter` runs from
any directory.

Prerequisites: the `gh` CLI must be installed and authenticated. See
[gh-cli-setup.sh](gh-cli-setup.sh).

## Folder layout (required)

```
<base>/
└── <org>/
    ├── upgiter/          ← this repo lives here
    ├── <repo-1>/
    ├── <repo-2>/
    └── ...
```

The script derives `<base>` by walking up from its own location: it expects to
sit two levels under the base. With the default install (`~/GITHUB/gianboc/upgiter`),
`<base>` is `~/GITHUB`. All clones land in `<base>/<org>/<repo>`.

`<org>` on the command line does **not** have to match the folder name — you
can run `upgiter -o some-other-org` and it will create `~/GITHUB/some-other-org/`
as a sibling.

## Modes

### Clone (default — no mode flag)

```bash
upgiter -o gianboc
```

Lists every repo for `gianboc` via the GH API and clones the ones missing
locally. Existing repos are skipped untouched. Paths that exist but aren't git
repos are flagged as warnings (not overwritten).

### Fetch + report (`-f`)

```bash
upgiter -f -o gianboc
```

Read-only. For each local repo: fetches from `origin`, then reports whether
it's stale and why (off the default branch, behind remote, dirty working tree,
or has stashes). No commits, no branch changes, no file edits.

### Update — hard reset (`-u`)

```bash
upgiter -u -o gianboc
```

> **Destructive.** This discards uncommitted changes, untracked files, and all
> stashes in every repo it touches. Use `-d` first to preview.

For each local repo: fetches, switches to the remote default branch,
`git reset --hard`, `git clean -fd`, `git stash clear`. The upgiter repo itself
is always skipped so the script doesn't reset its own working tree.

### Sync — the nuclear button (`-s`)

```bash
upgiter -s -o gianboc
```

> **Destructive on modified repos.** Clean repos are left untouched.

The "I want this org on my local machine NOW" command. For every repo on
GitHub:

- **Missing locally** → cloned.
- **Present and clean** (on default branch, in sync with remote, no dirty
  files, no stashes) → skipped, untouched.
- **Present and modified** → hard-reset to remote default branch (same
  destruction rules as `-u`).

> **Archived repos are skipped.** Sync runs `gh repo list --no-archived`, so
> repos you've archived on GitHub are never cloned or reset. This is the clean
> way to "mothball" a repo: archive it on GitHub and `-s` will leave it alone.
> (Note: this only affects `-s`. Default Clone mode still clones archived repos,
> and `-u`/`-f` work off your local folder regardless of archive status.)

Mode flags `-f`, `-u`, and `-s` are mutually exclusive — passing two at once
exits with an error.

#### Update vs Sync at a glance

They share the **same reset behavior**; the only difference is whether repos
you don't have locally get cloned.

|                                              | `-u` Update | `-s` Sync |
| -------------------------------------------- | :---------: | :-------: |
| Reset existing modified repos to remote      |     yes     |    yes    |
| Leave clean / in-sync repos untouched        |     yes     |    yes    |
| Clone repos not yet present locally          |     no      |    yes    |

Why: **Update** iterates your *local* `<org>` folder, so a repo you've never
cloned is invisible to it. **Sync** iterates the *remote* repo list
(`gh repo list`), so it sees everything on GitHub and pulls the missing ones
down. In short, **Sync = Update + clone-the-missing**.

#### When a repo can't be reset

If a repo is wedged (e.g. an interrupted merge with conflicts), upgiter aborts
the stuck operation and force-resets it. If it still can't, that one repo is
reported under **Failed** in the summary and the sweep continues — a single bad
repo no longer aborts the whole run.

### Dry-run modifier (`-d`)

Combine with any mode to print the planned actions without executing them:

```bash
upgiter -d -o gianboc        # which repos would be cloned
upgiter -d -u -o gianboc     # which repos would be hard-reset
upgiter -d -s -o gianboc     # which repos would be cloned and which fetched/reset
```

`-f` is already read-only, so `-d -f` adds nothing. In `-d -s`, missing repos
are reported precisely as "would clone"; existing repos are reported as "would
fetch + reset if stale" (sync doesn't actually fetch in dry-run, so it can't
distinguish stale from clean ahead of time).

## Examples

```bash
# First-time mirror of an org
upgiter -o gianboc

# Morning check: anything drifted?
upgiter -f -o gianboc

# Wipe local divergence and sync everything to remote
upgiter -d -u -o gianboc     # preview
upgiter -u -o gianboc        # do it

# "I want mulmopro on this machine NOW" — clone missing AND reset modified
upgiter -d -s -o mulmopro    # preview
upgiter -s -o mulmopro       # do it

# Mirror a different org alongside
upgiter -o some-collab-org
```

## Windows / PowerShell

A PowerShell sibling lives at [gh-clone-missing.ps1](gh-clone-missing.ps1).
Same flags, same folder-layout rules. Setup notes for the Windows side are in
[gh-cli-setup-windows-powershell.md](gh-cli-setup-windows-powershell.md).
