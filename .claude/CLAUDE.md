# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo **is** the `claude-docker` tooling itself — the definition of a disposable Docker
environment for running Claude Code on macOS. It is not an application that runs inside the
container; it is what builds and launches that container. There is no build/lint/test suite —
"building" means building the Docker image.

The authoritative, exhaustive documentation is `README.MD` (written in Russian). The README embeds
full copies of `Dockerfile` and the scripts as install heredocs, so the scripts and the README must
be kept mutually consistent — this is enforced by the sync rule in `rules/` (see below).

## Commands

```bash
# Build the image (image name is claude-code-dev)
docker build -t claude-code-dev ~/.claude-docker

# Full rebuild — pull fresh pyenv, Poetry and Claude Code
docker build --no-cache -t claude-code-dev ~/.claude-docker

# Launch: builds image if missing, mounts $(pwd) into /workspace, runs Claude Code
./start.sh              # installed globally as `claude-docker` via ~/bin symlink

# Validate the launcher after editing
bash -n start.sh
```

## Project memory

Long-lived project facts live in `memory/` — one durable fact per file, worth remembering across
sessions and shared with the team. `memory/MEMORY.md` is the index; it's imported below so it stays
in context, and you open a fact file only when its topic comes up.

Each fact file uses this format:

```markdown
---
name: <short-kebab-case-slug>          # must match the filename
description: <one-line summary — used to judge relevance during recall>
metadata:
  type: project | reference
---

<The fact. For `project`, follow with **Why:** and **How to apply:** lines.>
<Link related memories with [[their-name]].>
```

- `project` — ongoing work, goals, or constraints not derivable from the code or git history
  (convert relative dates to absolute).
- `reference` — pointers to external resources (tickets, dashboards, docs URLs).

Don't record what the repo or this `CLAUDE.md` already states (structure, past fixes, git history).
Keep personal `user`/`feedback` memories out of the repo — those stay in your own
`~/.claude/projects/.../memory/`. After adding a file, add a one-line pointer to `memory/MEMORY.md`.

@memory/MEMORY.md

## Rules

Every `*.md` file in `.claude/rules/` is auto-loaded into context — a focused instruction or
checklist there applies to all sessions. Current rules cover README/script sync, the untouchable
`state/` dir, dependency layering (Dockerfile + Poetry), shell syntax checks, and never running the
launcher and devcontainer against one project at once.

## Architecture

Responsibilities are deliberately split across layers (see README "Как это устроено"):

- **`Dockerfile`** — *what the environment can do*: Ubuntu 24.04 + system tools (PDF/OCR via
  poppler/tesseract with eng+rus, packet analysis via tshark/tcpdump, git/jq/ripgrep), the CPython
  build deps, `pyenv`, `poetry`, and the Claude Code native installer. Both the Poetry and Claude
  binaries land in `/root/.local/bin` (not `/root/.claude`, which is the mounted state dir).
- **`start.sh`** — *how a session is launched*: bind-mounts the current project into `/workspace`,
  mounts persistent state and caches, sets env vars, then `exec claude`. Uses `--rm` so the
  container is discarded on exit; state/caches survive via mounts.
- **`state/`** — persistent Claude state (login, history, settings). **Gitignored** (`.gitignore`
  = `state/`) and contains real credentials (`.credentials.json`, `.claude.json`) — never commit
  it, and treat its contents as untouchable.
- **Docker named volumes** — `claude-pyenv-versions` (CPython versions compiled by pyenv) and
  `claude-poetry-cache` (Poetry's cache, including the project venvs under
  `/root/.cache/pypoetry/virtualenvs`), so Python compilation and venv recreation are paid once.

### Load-bearing design decisions (don't undo without understanding)

- **`CLAUDE_CONFIG_DIR=/root/.claude`** points Claude Code's entire state — both
  `.credentials.json` and `.claude.json` — at the mounted `state/` dir. Both files are required:
  without `.claude.json`, Claude Code treats each start as a fresh install and re-prompts login.
  This is why the container uses its own state dir rather than the Mac's `~/.claude` (macOS stores
  the token in Keychain, unreachable from Linux).
- **The Python version is pinned by the project**, not the image: `setup-python-env.sh` reads
  `.python-version` (or `.python_version`), runs `pyenv install -s <ver>`, and points Poetry at
  that interpreter via `poetry env use`. With no pin, it falls back to the system `python3` (3.12).
  If the pinned version fails to compile, it stops rather than silently running the wrong Python.
- **venv lives in Poetry's cache (outside the bind-mount)** at
  `/root/.cache/pypoetry/virtualenvs/<...>`, built on the pyenv interpreter by `poetry env use` +
  `poetry install --no-root`. Keeping it out of `/workspace` avoids writing a Linux venv onto the
  Mac and slow bind-mount I/O. `POETRY_VIRTUALENVS_IN_PROJECT=false` (set in the Dockerfile) keeps
  Poetry from touching the Mac's `/workspace/.venv`. `create=false` is deliberately NOT used: it
  would target the system `python3.12`, locked by PEP 668 (`externally-managed-environment`).
- **venv is activated before `exec claude`** — after `poetry install`, `entrypoint.sh` reads the
  venv path from `poetry env info --path`, exports `VIRTUAL_ENV`, and prepends `<venv>/bin` to
  `PATH`, so `python`/`pytest`/`ruff` resolve directly (not just via `poetry run`). `state/CLAUDE.md`
  (the in-container global memory) promises this to the agent, so the export lines and that promise
  must stay in sync.
- **`~/.ssh` and `~/.gitconfig` are intentionally NOT mounted** — keys stay on the Mac.

### Two ways to run, one shared login

`start.sh` (the launcher, disposable `--rm` containers) and the optional devcontainer (persistent,
documented in the README) share the same `state/` mount, so login is common. They race on
`.claude.json` — never run both against the same project simultaneously.

## Conventions

The enforceable conventions (dependencies only through their own layer, README/script sync, verbatim
install snippets, shell syntax checks, no concurrent launcher+devcontainer) are the auto-loaded
rules in `rules/` — see the Rules section above. Consult them there rather than duplicating here.
