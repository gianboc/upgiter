# upgiter

Bulk-manage every repo under a GitHub org or user account from one command.
Three modes:

- **Clone** missing repos into your local mirror.
- **Fetch** and report which local repos are stale.
- **Update** — the nuclear button: clone missing + hard-reset modified, in one
  shot, so your local mirror matches the account exactly.

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

Add **`-p`/`--parallel`** to fetch all repos concurrently instead of one at a
time. The per-repo fetch is network-bound (~0.8 s of round-trip each, mostly the
TLS + auth handshake, not data), and the calls are independent — so on a
many-repo org this is dramatically faster: on a ~40-repo org, **~42 s → ~3 s**
(a 14× speedup). The flag takes no argument; it uses `(CPU cores − 2)` jobs,
floored at 1, so it leaves the machine responsive. Core detection is a single
sub-millisecond kernel query (`nproc`), negligible next to even one fetch.

### Update — the nuclear button (`-u`)

```bash
upgiter -u -o gianboc
```

> **Destructive on modified repos.** Clean repos are left untouched.

The "I want this org on my local machine NOW" command. Driven by **the GitHub
repo list**, it makes your local mirror match the account in one shot. For every
repo the account owns:

- **Missing locally** → cloned.
- **Present and clean** (on default branch, in sync with remote, no dirty
  files, no stashes) → skipped, untouched.
- **Present and modified** → hard-reset to the remote default branch:
  `git reset --hard`, `git clean -fd`, `git stash clear`, discarding uncommitted
  changes, untracked files, and stashes.

The upgiter repo itself is always counted as up-to-date and never reset, so the
script doesn't clobber its own working tree. A path that exists but isn't a git
repo is flagged as a warning, never overwritten.

> **Archived repos are skipped.** Update runs `gh repo list --no-archived`, so
> repos you've archived on GitHub are never cloned or reset. This is the clean
> way to "mothball" a repo: archive it on GitHub and `-u` will leave it alone.
> (Default Clone mode still clones archived repos; `-f` works off your local
> folder regardless of archive status.)

> **What survives a reset:** `git clean -fd` (no `-x`) does **not** remove
> gitignored files. Anything matching a `.gitignore` rule — `.venv/`,
> `__pycache__/`, `node_modules/`, build outputs, local data — is left in place.
> Only tracked changes and *non-ignored* untracked files are wiped. If you want
> a truly pristine tree, clean ignored files yourself; upgiter intentionally
> doesn't.

> **When a repo can't be reset:** if a repo is wedged (e.g. an interrupted merge
> with conflicts), upgiter aborts the stuck operation and force-resets it. If it
> still can't, that one repo is reported under **Failed** in the summary and the
> sweep continues — a single bad repo no longer aborts the whole run.

Mode flags `-f` and `-u` are mutually exclusive — passing both exits with an
error.

### Dry-run modifier (`-d`)

Combine with any mode to print the planned actions without executing them:

```bash
upgiter -d -o gianboc        # which repos would be cloned
upgiter -d -u -o gianboc     # which would be cloned and which fetched/reset
```

`-f` is already read-only, so `-d -f` adds nothing. In `-d -u`, missing repos
are reported precisely as "would clone"; existing repos are reported as "would
fetch + reset if stale" (update doesn't actually fetch in dry-run, so it can't
distinguish stale from clean ahead of time).

## Examples

```bash
# First-time mirror of an org
upgiter -o gianboc

# Morning check: anything drifted?
upgiter -f -o gianboc

# "I want mulmopro on this machine NOW" — clone missing AND reset modified,
# wiping any local divergence so the mirror matches the account exactly
upgiter -d -u -o mulmopro     # preview
upgiter -u -o mulmopro        # do it

# Mirror a different org alongside
upgiter -o some-collab-org
```

## Windows / PowerShell

A PowerShell sibling lives at [gh-clone-missing.ps1](gh-clone-missing.ps1) — a
faithful port of the bash script with the same modes (clone / `-f` / `-u`),
flags, and folder-layout rules. Setup notes for the Windows side are in
[gh-cli-setup-windows-powershell.md](gh-cli-setup-windows-powershell.md).
