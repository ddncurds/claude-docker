#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="claude-code-dev"

# Отдельный каталог состояния Claude для контейнера (НЕ Mac'овский ~/.claude).
# Благодаря CLAUDE_CONFIG_DIR сюда лягут и .credentials.json, и .claude.json.
CLAUDE_STATE="$HOME/.claude-docker/state"
mkdir -p "$CLAUDE_STATE"

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running. Start Docker Desktop and try again."
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "🔨 Building Claude Code image..."
    docker build -t "$IMAGE" "$HOME/.claude-docker"
fi

# Уникальное имя -> можно держать несколько проектов параллельно
SAFE_NAME="$(basename "$PROJECT_DIR" | tr -c 'a-zA-Z0-9_.-' '_')"

# Логика сессии (подготовка venv + активация + exec claude) запечена в образ
# как entrypoint.sh (Dockerfile CMD) — единая копия, общая с devcontainer'ом.
docker run --rm -it \
    --name "claude-${SAFE_NAME}-$$" \
    -v "$PROJECT_DIR:/workspace" \
    -v "$CLAUDE_STATE:/root/.claude" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -v claude-pyenv-versions:/root/.pyenv/versions \
    -v claude-poetry-cache:/root/.cache/pypoetry \
    -w /workspace \
    "$IMAGE"
