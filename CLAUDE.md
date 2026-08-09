# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo **is** the `claude-docker` tooling itself — the definition of a disposable Docker
environment for running Claude Code on macOS. It is not an application that runs inside the
container; it is what builds and launches that container. There is no build/lint/test suite —
"building" means building the Docker image.

The authoritative, exhaustive documentation is `README.MD` (written in Russian). When changing
behavior, keep `README.MD`, `Dockerfile`, `start.sh`, and `state/CLAUDE.md` mutually consistent —
the README embeds full copies of `Dockerfile` and `start.sh` as install heredocs, so a change to
either script must be mirrored in the README's code block (and vice versa).

## Commands

```bash
# Build the image (image name is claude-code-dev)
docker build -t claude-code-dev ~/.claude-docker

# Full rebuild — pull fresh uv and Claude Code
docker build --no-cache -t claude-code-dev ~/.claude-docker

# Launch: builds image if missing, mounts $(pwd) into /workspace, runs Claude Code
./start.sh              # installed globally as `claude-docker` via ~/bin symlink

# Validate the launcher after editing
bash -n start.sh
```

## Architecture

Responsibilities are deliberately split across layers (see README "Как это устроено"):

- **`Dockerfile`** — *what the environment can do*: Ubuntu 24.04 + system tools (PDF/OCR via
  poppler/tesseract with eng+rus, packet analysis via tshark/tcpdump, git/jq/ripgrep), `uv`, and
  the Claude Code native installer. The Claude binary lands in `/root/.local/bin` (not
  `/root/.claude`, which is the mounted state dir).
- **`start.sh`** — *how a session is launched*: bind-mounts the current project into `/workspace`,
  mounts persistent state and caches, sets env vars, then `exec claude`. Uses `--rm` so the
  container is discarded on exit; state/caches survive via mounts.
- **`state/`** — persistent Claude state (login, history, settings). **Gitignored** (`.gitignore`
  = `state/`) and contains real credentials (`.credentials.json`, `.claude.json`) — never commit
  it, and treat its contents as untouchable.
- **Docker named volumes** — `claude-uv-cache` (uv package cache) and `claude-python`
  (downloaded Python interpreters), so venv recreation on each run is fast.

### Load-bearing design decisions (don't undo without understanding)

- **`CLAUDE_CONFIG_DIR=/root/.claude`** points Claude Code's entire state — both
  `.credentials.json` and `.claude.json` — at the mounted `state/` dir. Both files are required:
  without `.claude.json`, Claude Code treats each start as a fresh install and re-prompts login.
  This is why the container uses its own state dir rather than the Mac's `~/.claude` (macOS stores
  the token in Keychain, unreachable from Linux).
- **venv lives at `/root/venv` (outside the bind-mount)** via `UV_PROJECT_ENVIRONMENT=/root/venv`.
  Keeping it out of `/workspace` avoids writing a Linux venv onto the Mac and slow bind-mount I/O.
  It is ephemeral (recreated each run by `uv sync`).
- **venv is activated before `exec claude`** — `start.sh` exports `VIRTUAL_ENV=/root/venv` and
  prepends `/root/venv/bin` to `PATH` after `uv sync`, so `python`/`pytest`/`ruff` resolve
  directly (not just via `uv run`). `state/CLAUDE.md` (the in-container global memory) promises
  this to the agent, so the export lines in `start.sh` and that promise must stay in sync.
- **`~/.ssh` and `~/.gitconfig` are intentionally NOT mounted** — keys stay on the Mac.

### Two ways to run, one shared login

`start.sh` (the launcher, disposable `--rm` containers) and the optional devcontainer (persistent,
documented in the README) share the same `state/` mount, so login is common. They race on
`.claude.json` — never run both against the same project simultaneously.

## Conventions

- New system tools go in the `Dockerfile` + rebuild; a manual `apt install` in a running container
  is lost on exit. Project Python dependencies go through `uv` / `pyproject.toml`, never `pip`.
- Heredocs in the README use quoted `'EOF'` so contents are written verbatim — preserve that when
  editing install snippets.
