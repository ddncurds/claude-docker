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

docker run --rm -it \
    --name "claude-${SAFE_NAME}-$$" \
    -v "$PROJECT_DIR:/workspace" \
    -v "$CLAUDE_STATE:/root/.claude" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -e UV_PROJECT_ENVIRONMENT=/root/venv \
    -v claude-uv-cache:/root/.cache/uv \
    -v claude-python:/root/.local/share/uv \
    -w /workspace \
    "$IMAGE" \
    bash -lc '
        echo
        echo "🐧 Ubuntu:"; grep PRETTY_NAME /etc/os-release; echo

        if [ ! -f /root/.claude/.credentials.json ]; then
            echo "🔑 В этом окружении Claude ещё не залогинен."
            echo "   Запусти /login, открой ссылку в браузере Mac, подтверди вход"
            echo "   и вставь код обратно. Дальше логин сохранится."
            echo
        fi

        if [ -f pyproject.toml ]; then
            echo "🐍 Python project detected"
            echo "📦 uv sync..."
            uv sync
            echo; echo "🐍 Python:"; uv run python --version; echo
        else
            echo "ℹ️  No pyproject.toml found"; echo
        fi

        exec claude
    '
