#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="claude-code-dev"

# Каталог окружения = каталог самого скрипта, а НЕ захардкоженный ~/.claude-docker:
# репозиторий можно клонировать куда угодно (на Linux это обычно не ~/.claude-docker),
# и всё равно найдутся Dockerfile, state/ и mcp.json. Симлинки (~/bin/claude-docker)
# разматываем вручную: у macOS BSD-шный readlink, там нет `readlink -f`.
SELF="$0"
while [ -L "$SELF" ]; do
    LINK="$(readlink "$SELF")"
    case "$LINK" in
        /*) SELF="$LINK" ;;
        *)  SELF="$(dirname "$SELF")/$LINK" ;;
    esac
done
ENV_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"

# Отдельный каталог состояния Claude для контейнера (НЕ хостовский ~/.claude).
# Благодаря CLAUDE_CONFIG_DIR сюда лягут и .credentials.json, и .claude.json.
CLAUDE_STATE="$ENV_DIR/state"
mkdir -p "$CLAUDE_STATE"

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not available."
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "   Start Docker Desktop and try again."
    else
        echo "   Start the daemon (sudo systemctl start docker) and make sure you are"
        echo "   in the 'docker' group (sudo usermod -aG docker \"\$USER\", then re-login)."
    fi
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "🔨 Building Claude Code image from $ENV_DIR..."
    docker build -t "$IMAGE" "$ENV_DIR"
fi

# Уникальное имя -> можно держать несколько проектов параллельно
SAFE_NAME="$(basename "$PROJECT_DIR" | tr -c 'a-zA-Z0-9_.-' '_')"

# MCP-серверы (опционально): если рядом лежит mcp.json, монтируем его read-only
# в /root/mcp.json — entrypoint скормит его claude через --mcp-config. Файл с
# токенами, поэтому НЕ в git (см. .gitignore) и вне примонтированного state.
MCP_CONFIG="$ENV_DIR/mcp.json"
MCP_MOUNT=()
[ -f "$MCP_CONFIG" ] && MCP_MOUNT=(-v "$MCP_CONFIG:/root/mcp.json:ro")

# Сервисы проекта (БД, Redis) обычно крутятся в docker на хосте. Внутри контейнера
# localhost — это сам контейнер, поэтому ходить к ним надо по host.docker.internal.
# На Docker Desktop это имя есть само; на Docker Engine его нужно завести вручную
# (host-gateway = адрес хоста со стороны docker-сети).
HOST_ALIAS=()
[ "$(uname -s)" = "Linux" ] && HOST_ALIAS=(--add-host "host.docker.internal:host-gateway")

# Переопределения окружения для контейнера (опционально): файл в формате KEY=value,
# обычно одна строка вида DATABASE_HOST=host.docker.internal. Читает его docker CLI на
# хосте, поэтому переменные попадают в окружение контейнера ДО старта питона и перебивают
# .env проекта (переменные окружения приоритетнее dotenv-файла). Файл с кредами дев-стека,
# в git не нужен; путь можно переопределить через CLAUDE_DOCKER_ENV_FILE.
ENV_FILE="${CLAUDE_DOCKER_ENV_FILE:-$PROJECT_DIR/.env.claude-docker}"
ENV_ARG=()
if [ -f "$ENV_FILE" ]; then
    ENV_ARG=(--env-file "$ENV_FILE")
    echo "🧩 Env: подключаю переопределения из $ENV_FILE"
fi

# Логика сессии (подготовка venv + активация + exec claude) запечена в образ
# как entrypoint.sh (Dockerfile CMD) — единая копия, общая с devcontainer'ом.
docker run --rm -it \
    --name "claude-${SAFE_NAME}-$$" \
    -v "$PROJECT_DIR:/workspace" \
    -v "$CLAUDE_STATE:/root/.claude" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -v claude-pyenv-versions:/root/.pyenv/versions \
    -v claude-poetry-cache:/root/.cache/pypoetry \
    -v claude-npm-cache:/root/.npm \
    ${HOST_ALIAS[@]+"${HOST_ALIAS[@]}"} \
    ${ENV_ARG[@]+"${ENV_ARG[@]}"} \
    ${MCP_MOUNT[@]+"${MCP_MOUNT[@]}"} \
    -w /workspace \
    "$IMAGE"
