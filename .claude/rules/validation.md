# Rule: validate scripts after editing

There is no test suite in this repo, so a syntax check is mandatory.

- After editing any `*.sh` (`start.sh`, `entrypoint.sh`, `setup-python-env.sh`), run
  `bash -n <file>` before considering the task done.
- "Building" the project means building the Docker image:
  `docker build -t claude-code-dev ~/.claude-docker`.
