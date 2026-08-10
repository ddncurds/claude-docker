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
    -v claude-poetry-cache:/root/.cache/pypoetry \
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
            # цифры и точки — переживает BOM/CRLF/UTF-16. Пусто -> системный python3.
            PYVER=""
            for f in .python-version .python_version; do
                [ -f "$f" ] || continue
                PYVER="$(tr -cd "0-9." < "$f")"
                [ -n "$PYVER" ] && break
            done

            SKIP_POETRY=0
            PYBIN="python3"   # fallback, если версия не запинена
            if [ -n "$PYVER" ]; then
                echo "🐍 pyenv: ставлю Python $PYVER (первый раз компилируется, потом из кэша)..."
                pyenv install -s "$PYVER" 2>&1 || echo "⚠️  pyenv install $PYVER вернул ошибку (см. вывод выше)"
                if [ -x "$PYENV_ROOT/versions/$PYVER/bin/python" ]; then
                    PYBIN="$PYENV_ROOT/versions/$PYVER/bin/python"
                else
                    # НЕ откатываемся молча на системный python3 (он externally-managed,
                    # PEP 668) — честно стоп, чтобы не запускаться не на той версии.
                    echo
                    echo "❌ Python $PYVER не установился (сборка pyenv упала — см. вывод выше)."
                    echo "   Диагностика (на Mac): docker run --rm -it \\"
                    echo "     -v claude-pyenv-versions:/root/.pyenv/versions $IMAGE bash -lc \"pyenv install $PYVER\""
                    echo "   Если сборка падала раньше — сперва: docker volume rm claude-pyenv-versions"
                    echo
                    SKIP_POETRY=1
                fi
            else
                echo "🐍 .python-version не найден — беру системный python3"
            fi

            if [ "$SKIP_POETRY" = 0 ]; then
                # venv на базе выбранного интерпретатора, ВНЕ /workspace (в кэше Poetry,
                # persistent-volume). Это единственный надёжный способ поставить пакеты
                # именно в этот Python: poetry с create=false целится в системный 3.12.
                echo "📦 poetry: окружение на $("$PYBIN" --version 2>&1)"
                poetry env use "$PYBIN" >/dev/null
                echo "📦 poetry install --no-root..."
                poetry install --no-root

                # активируем venv: python/pytest/ruff видят его напрямую
                VENV="$(poetry env info --path)"
                export VIRTUAL_ENV="$VENV"
                export PATH="$VENV/bin:$PATH"
                echo; echo "🐍 Python: $(python --version 2>&1) [$(command -v python)]"; echo
            fi
        else
            echo "ℹ️  No pyproject.toml found"; echo
        fi

        exec claude
    '
