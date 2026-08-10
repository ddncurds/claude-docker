#!/usr/bin/env bash
# Готовит venv Poetry для проекта в текущем каталоге. Единая копия логики,
# которую зовут и лаунчер (entrypoint.sh), и devcontainer (postCreateCommand).
#
# Делает: читает .python-version / .python_version → pyenv install -s <ver>
# (или системный python3, если версия не запинена) → poetry env use → poetry
# install --no-root.
#
# Код возврата — контракт для вызывающего «активировать ли venv»:
#   0  — venv готов, можно активировать
#   1  — нет pyproject.toml (активировать нечего)
#   3  — запиненная версия Python не собралась (venv не готов)
set -uo pipefail

[ -f pyproject.toml ] || { echo "ℹ️  No pyproject.toml found"; echo; exit 1; }

echo "🐍 Python project detected"

# версия из .python-version (или .python_version); tr -cd оставляет только
# цифры и точки — переживает BOM/CRLF/UTF-16. Пусто -> системный python3.
PYVER=""
for f in .python-version .python_version; do
    [ -f "$f" ] || continue
    PYVER="$(tr -cd "0-9." < "$f")"
    [ -n "$PYVER" ] && break
done

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
        echo "     -v claude-pyenv-versions:/root/.pyenv/versions claude-code-dev bash -lc \"pyenv install $PYVER\""
        echo "   Если сборка падала раньше — сперва: docker volume rm claude-pyenv-versions"
        echo
        exit 3
    fi
else
    echo "🐍 .python-version не найден — беру системный python3"
fi

# venv на базе выбранного интерпретатора, ВНЕ /workspace (в кэше Poetry,
# persistent-volume). Это единственный надёжный способ поставить пакеты
# именно в этот Python: poetry с create=false целится в системный 3.12.
echo "📦 poetry: окружение на $("$PYBIN" --version 2>&1)"
poetry env use "$PYBIN" >/dev/null
echo "📦 poetry install --no-root..."
poetry install --no-root

# venv готов (даже если install споткнулся — окружение уже создано); пусть
# вызывающий его активирует.
exit 0
