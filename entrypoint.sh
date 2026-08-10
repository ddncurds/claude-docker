#!/usr/bin/env bash
# Команда контейнера (Dockerfile CMD) для одноразового лаунчера start.sh:
# баннер → проверка логина → подготовка venv (setup-python-env.sh) →
# активация venv → exec claude. Devcontainer это НЕ выполняет — он зовёт
# setup-python-env.sh напрямую из postCreateCommand.
set -uo pipefail

echo
echo "🐧 Ubuntu:"; grep PRETTY_NAME /etc/os-release; echo

if [ ! -f /root/.claude/.credentials.json ]; then
    echo "🔑 В этом окружении Claude ещё не залогинен."
    echo "   Запусти /login, открой ссылку в браузере Mac, подтверди вход"
    echo "   и вставь код обратно. Дальше логин сохранится."
    echo
fi

# setup-python-env.sh возвращает 0, только если venv готов к активации
# (есть pyproject.toml и Python встал). Иначе просто стартуем Claude.
if setup-python-env.sh; then
    # активируем venv: python/pytest/ruff видят его напрямую
    VENV="$(poetry env info --path)"
    export VIRTUAL_ENV="$VENV"
    export PATH="$VENV/bin:$PATH"
    echo; echo "🐍 Python: $(python --version 2>&1) [$(command -v python)]"; echo
fi

# MCP-серверы: если start.sh примонтировал /root/mcp.json — подключаем его.
# Без --strict-mcp-config, чтобы серверы из файла дополняли (а не заменяли)
# всё, что уже настроено в state/.claude.json.
if [ -f /root/mcp.json ]; then
    echo "🔌 MCP: подключаю серверы из /root/mcp.json"; echo
    exec claude --mcp-config /root/mcp.json
fi

exec claude
