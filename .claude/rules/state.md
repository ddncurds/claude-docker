# Rule: state/ is untouchable

`state/` is Claude's persistent state (login, history, settings). It holds real credentials:
`.credentials.json` and `.claude.json`.

- **Never** commit `state/` (it is in `.gitignore`).
- **Never** edit or delete its contents. Treat it as someone else's.
- To change state-related behavior, change the mounts/env vars in `start.sh` and `entrypoint.sh` —
  not the files inside `state/`.
