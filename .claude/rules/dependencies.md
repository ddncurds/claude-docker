# Rule: dependencies are added only through their own layer

- **System tools** go in the `Dockerfile` + image rebuild. A manual `apt install` in a running
  container is lost on exit (`--rm`).
- **Project Python dependencies** go through `poetry` / `pyproject.toml` only. Never `pip`: the
  system `python3.12` is locked by PEP 668 (`externally-managed-environment`), and dependencies
  must live in the Poetry venv.
