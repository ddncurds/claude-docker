# Rule: don't run the launcher and the devcontainer at once

`start.sh` (disposable `--rm` containers) and the devcontainer (persistent) share the same `state/`
mount, so login is common — but so is `.claude.json`.

Never run both against the same project simultaneously: they race on `.claude.json` and can clobber
each other's state.
