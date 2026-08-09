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
    -v claude-pyenv-versions:/root/.pyenv/versions \
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

            # версия из .python-version (или .python_version); tr -cd оставляет только
            # цифры и точки — переживает BOM/CRLF/UTF-16. Пусто -> системный Python.
            PYVER=""
            for f in .python-version .python_version; do
                [ -f "$f" ] || continue
                PYVER="$(tr -cd "0-9." < "$f")"
                [ -n "$PYVER" ] && break
            done

            if [ -n "$PYVER" ]; then
                echo "🐍 pyenv: ставлю Python $PYVER (первый раз компилируется, потом из кэша)..."
                pyenv install -s "$PYVER"
                pyenv global "$PYVER"
            else
                echo "🐍 .python-version не найден — беру системный Python"
                pyenv global system
            fi

            echo; echo "🐍 Python:"; python --version
            echo "📦 poetry install --no-root (без venv, прямо в этот Python)..."
            # --no-root: ставим только зависимости, не сам проект как пакет
            # (в app-репозиториях пакета с именем проекта нет — poetry иначе падает)
            poetry install --no-root
            pyenv rehash   # шимы для консольных скриптов (pytest, ruff, ...)
            echo
        else
            echo "ℹ️  No pyproject.toml found"; echo
        fi

        exec claude
    '
