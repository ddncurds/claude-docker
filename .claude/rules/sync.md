# Rule: keep the README and the scripts in sync

When you change the environment's behavior, update **every** artifact that carries it together:
`README.MD`, `Dockerfile`, `start.sh`, `entrypoint.sh`, `setup-python-env.sh`, `state/CLAUDE.md`.

- `README.MD` does **not** embed copies of `Dockerfile` or the scripts — it describes behavior in
  prose, tables, and operational commands. When you change a script, update the matching
  description/table/command in the README so the docs still match reality (don't paste the code
  back in).
- The README still carries some standalone config that has no source-of-truth file in the repo
  (e.g. the `.devcontainer/devcontainer.json` block). Keep those blocks in sync with the mounts /
  env vars in `start.sh` and the `Dockerfile`.
- `state/CLAUDE.md` (the in-container global memory) promises the agent that the venv is activated
  before `exec claude`. If you change the activation logic in `entrypoint.sh` /
  `setup-python-env.sh`, update that promise too.
