# Rule: keep the README and the scripts in sync

When you change the environment's behavior, update **every** artifact that carries it together:
`README.MD`, `Dockerfile`, `start.sh`, `entrypoint.sh`, `setup-python-env.sh`, `state/CLAUDE.md`.

- `README.MD` embeds **full copies** of `Dockerfile` and the scripts as install heredocs. Change a
  script → mirror the change in the matching README code block (and vice versa).
- The README heredocs use quoted `'EOF'`, so their contents are written verbatim. Preserve the
  quoting — otherwise `$…` and other expansions will break the install snippet.
- `state/CLAUDE.md` (the in-container global memory) promises the agent that the venv is activated
  before `exec claude`. If you change the activation logic in `entrypoint.sh` /
  `setup-python-env.sh`, update that promise too.
