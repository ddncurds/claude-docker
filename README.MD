# claude-docker

Изолированное окружение для **Claude Code** на macOS: одна команда `claude-docker`
поднимает одноразовый контейнер (Ubuntu 24.04) с `pyenv`, `poetry`, git и набором CLI-инструментов,
монтирует текущую папку проекта в `/workspace` и запускает Claude Code. После выхода контейнер
удаляется, но логин, история, настройки Claude, скомпилированные Python и venv Poetry с
зависимостями сохраняются.

---

## Содержание

- [claude-docker](#claude-docker)
  - [Содержание](#содержание)
  - [Как это устроено](#как-это-устроено)
  - [Предусловия](#предусловия)
  - [Установка](#установка)
    - [1. Файлы окружения](#1-файлы-окружения)
    - [2. Память Claude (CLAUDE.md)](#2-память-claude-claudemd)
    - [3. Глобальная команда](#3-глобальная-команда)
  - [Первый запуск и логин](#первый-запуск-и-логин)
  - [Ежедневное использование](#ежедневное-использование)
  - [Python и виртуальное окружение](#python-и-виртуальное-окружение)
  - [Переменные окружения](#переменные-окружения)
  - [Обслуживание](#обслуживание)
  - [Devcontainer](#devcontainer)
  - [Что уже в образе](#что-уже-в-образе)
  - [Траблшутинг](#траблшутинг)
  - [Ежедневная команда (итог)](#ежедневная-команда-итог)

---

## Как это устроено

Разделение ответственности:

| Слой | За что отвечает | Где живёт |
| --- | --- | --- |
| `Dockerfile` | Что умеет окружение (Ubuntu + инструменты + pyenv + poetry + Claude Code) | `~/.claude-docker/Dockerfile` |
| `start.sh` + `entrypoint.sh` + `setup-python-env.sh` | Как запускается сессия: `start.sh` поднимает контейнер, запечённый в образ `entrypoint.sh` готовит venv и стартует Claude (общий с devcontainer `setup-python-env.sh`) | `~/.claude-docker/*.sh` → образ `/usr/local/bin` |
| `.python-version` + `pyproject.toml` | Что нужно проекту (версия Python + зависимости) | в проекте, на Mac |
| Состояние Claude | Авторизация, история, настройки, permissions, skills, hooks | `~/.claude-docker/state` |
| Docker volumes | Скомпилированные pyenv-Python, venv/кэш Poetry и кэш npm (для MCP через npx) | `claude-pyenv-versions`, `claude-poetry-cache`, `claude-npm-cache` |
| `/workspace` | Текущий проект с Mac (bind-mount) | папка проекта |
| `mcp.json` *(опц.)* | Конфиг MCP-серверов с токенами; монтируется в `/root/mcp.json`, не в git | `~/.claude-docker/mcp.json` |

Осознанно **не** монтируются `~/.ssh` и `~/.gitconfig` — ключи остаются на Mac.

Ключевые решения:

- **Логин через аккаунт (OAuth), один раз.** Сохраняется, потому что `CLAUDE_CONFIG_DIR`
  складывает и `.credentials.json`, и `.claude.json` в один примонтированный каталог. Без
  `.claude.json` Claude Code считает запуск свежей установкой и снова просит вход.
- **Состояние контейнера отдельно от Mac'овского `~/.claude`.** На macOS Claude Code хранит токен
  в Keychain (недоступен из Linux) и удаляет файловый `.credentials.json`; общий каталог давал бы
  постоянные перелогины.
- **venv Poetry на базе pyenv-Python, вне bind-mount** — лежит в `/root/.cache/pypoetry/virtualenvs`
  (volume), `entrypoint.sh` активирует его перед стартом, поэтому `python`/`pytest` доступны напрямую. На
  Mac не попадает нерабочий linux-venv. `create=false` тут не годится: тогда Poetry ставит в
  системный `python3.12`, залоченный PEP 668, мимо нужной версии.
- **pyenv компилирует CPython из исходников** — первая установка версии занимает минуты, но и сам
  Python (volume `claude-pyenv-versions`), и venv с зависимостями (volume `claude-poetry-cache`)
  кэшируются, поэтому повторные запуски мгновенны.

---

## Предусловия

Только **Docker Desktop** (установлен и запущен). pyenv, Poetry и Python на Mac не нужны.

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Запусти Docker Desktop"
```

---

## Установка

### 1. Файлы окружения

Одной вставкой. Heredoc'и с `'EOF'` пишут содержимое дословно (переменные внутри не раскрываются).

```bash
mkdir -p ~/.claude-docker

cat > ~/.claude-docker/Dockerfile << 'EOF'
FROM ubuntu:24.04

# только на время сборки (ARG, не ENV — не протекает в runtime)
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates curl git build-essential \
    jq ripgrep tree vim less unzip zip procps \
    \
    poppler-utils qpdf ocrmypdf \
    tesseract-ocr tesseract-ocr-rus \
    \
    tshark tcpdump iproute2 \
    \
    # зависимости для сборки CPython через pyenv (компиляция из исходников;
    # make/gcc уже есть в build-essential выше)
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev libncurses-dev libffi-dev liblzma-dev \
    xz-utils tk-dev \
    \
    # интерпретатор для самого Poetry + fallback, когда версия не запинена
    # python-is-python3: чтобы команда `python` существовала (в Ubuntu только python3)
    python3 python3-venv python3-dev python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# Node.js: нужен, чтобы поднимать MCP-серверы с type=stdio, которые запускаются
# через npx (mcp-remote, @sentry/mcp-server и т.п.). Конфиг серверов прокидывается
# из ~/.claude-docker/mcp.json (см. start.sh). Ставим Node 22 из NodeSource, а НЕ
# apt-пакет ubuntu: там Node 18, а mcp-remote (undici) требует глобальный `File`
# (Node 20+), иначе сервер падает с `ReferenceError: File is not defined`.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# pyenv — управление версиями Python. Компиляция кэшируется в volume /root/.pyenv/versions.
ENV PYENV_ROOT=/root/.pyenv
RUN curl -fsSL https://pyenv.run | bash
ENV PATH="/root/.pyenv/bin:/root/.pyenv/shims:$PATH"

# Poetry (официальный установщик: бинарь в /root/.local/bin) + Claude Code (туда же)
RUN curl -sSL https://install.python-poetry.org | python3 - \
    && curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"

# Poetry создаёт venv на базе выбранного pyenv-Python (setup-python-env.sh: `poetry env use`),
# в кэше /root/.cache/pypoetry (persistent-volume), а НЕ в /workspace.
# IN_PROJECT=false — чтобы Poetry не подхватывал и не трогал локальный
# /workspace/.venv (это мак-овский venv с хоста, ему в контейнере делать нечего).
# (create=false тут нельзя: тогда Poetry ставит в системный python3.12, залоченный PEP 668.)
ENV POETRY_VIRTUALENVS_IN_PROJECT=false

# Скрипты сессии запечены в образ (а не переданы inline в start.sh), поэтому
# одна копия логики используется и лаунчером, и devcontainer'ом:
#   setup-python-env.sh — общая подготовка venv (pyenv + poetry)
#   entrypoint.sh       — обёртка лаунчера: setup + активация venv + exec claude
COPY entrypoint.sh setup-python-env.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/setup-python-env.sh

WORKDIR /workspace
CMD ["entrypoint.sh"]
EOF

cat > ~/.claude-docker/.dockerignore << 'EOF'
state/
mcp.json
EOF

cat > ~/.claude-docker/start.sh << 'EOF'
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

# MCP-серверы (опционально): если рядом лежит mcp.json, монтируем его read-only
# в /root/mcp.json — entrypoint скормит его claude через --mcp-config. Файл с
# токенами, поэтому НЕ в git (см. .gitignore) и вне примонтированного state.
MCP_CONFIG="$HOME/.claude-docker/mcp.json"
MCP_MOUNT=()
[ -f "$MCP_CONFIG" ] && MCP_MOUNT=(-v "$MCP_CONFIG:/root/mcp.json:ro")

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
    ${MCP_MOUNT[@]+"${MCP_MOUNT[@]}"} \
    -w /workspace \
    "$IMAGE"
EOF

cat > ~/.claude-docker/setup-python-env.sh << 'EOF'
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
EOF

cat > ~/.claude-docker/entrypoint.sh << 'EOF'
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
EOF

chmod +x ~/.claude-docker/start.sh ~/.claude-docker/setup-python-env.sh ~/.claude-docker/entrypoint.sh
```

### 2. Память Claude (CLAUDE.md)

Глобальный файл памяти — Claude Code читает его автоматически во всех проектах внутри контейнера.
Кладём в каталог состояния (в контейнере это `/root/.claude/CLAUDE.md`):

```bash
cat > ~/.claude-docker/state/CLAUDE.md << 'EOF'
# Среда выполнения

Ты работаешь ВНУТРИ одноразового Docker-контейнера (Ubuntu 24.04), а не на хост-Mac.
- Проект примонтирован в `/workspace` (= папка на Mac). Правки файлов тут сохраняются на хосте.
- Версиями Python управляет `pyenv`, зависимостями — `poetry`. Системный pip не использовать.

## Python / виртуальное окружение
- venv создаёт Poetry на базе выбранного pyenv-Python, ВНЕ `/workspace` — в
  `/root/.cache/pypoetry/virtualenvs/<...>` (persistent-volume). Так надо: при `create=false`
  Poetry на Ubuntu ставит в системный python3.12, залоченный PEP 668.
- Оно УЖЕ активировано при старте: выставлены `VIRTUAL_ENV` и `<venv>/bin` в начале `PATH`.
- Поэтому вызывай `python`, `pytest`, `ruff` и т.д. напрямую — они из venv.
  Проверка: `echo $VIRTUAL_ENV` (непусто), `python --version` → версия проекта.
- НЕ создавай/не трогай `.venv` в `/workspace` (это мак-овский venv с хоста, `POETRY_VIRTUALENVS_IN_PROJECT=false`
  велит Poetry его игнорировать), не активируй venv заново, не зови `poetry shell`.
- `pyproject.toml` и `poetry.lock` лежат в `/workspace` (на Mac) — их изменения сохраняются.

## Версия Python
- Версию задаёт проект: файл `.python-version` (или `.python_version`) с полной версией, напр. `3.11.6`.
- При старте `setup-python-env.sh` (его зовёт `entrypoint.sh`) читает его, делает `pyenv install -s <ver>`
  (компиляция кэшируется в volume `claude-pyenv-versions`) и `poetry env use` на этот интерпретатор.
- Без `.python-version` venv строится на системном `python3` (3.12).
- Хочешь другую версию — правь `.python-version` (на Mac) и перезапусти контейнер.

## Зависимости
- Добавить пакет: `poetry add <pkg>` (правит pyproject.toml + poetry.lock, ставит в venv).
- Установить по локу: `poetry install --no-root` (в контейнере ставим только зависимости, не сам
  проект как пакет — так делает `setup-python-env.sh`).
- venv кэшируется в volume и переживает перезапуск. Установка мимо poetry (`pip install`) не
  сохранится после `--rm` — всегда `poetry add` / `poetry install`.

## Границы
- `~/.ssh` и `~/.gitconfig` в контейнер намеренно НЕ примонтированы — их здесь нет.
- Состояние Claude — в `/root/.claude` (`CLAUDE_CONFIG_DIR`); не трогай.

## Что уже стоит в образе
- PDF: pdftotext, pdfinfo, qpdf, ocrmypdf, tesseract (eng + rus).
- Сеть: tshark / tcpdump — анализ `.pcap` / `.pcapng` (только чтение файлов).
- Прочее: git, jq, ripgrep, tree.
EOF
```

### 3. MCP-серверы (опционально)

Если на Mac'е в `~/.claude.json` (ключ верхнего уровня `mcpServers`) уже настроены MCP-серверы,
контейнер их **не видит**: у него отдельный каталог состояния (`state/`), и там своего `mcpServers`
нет. Чтобы прокинуть их, положи конфиг рядом с окружением — `start.sh` сам подхватит файл и
подключит серверы через `claude --mcp-config` (см. `entrypoint.sh`).

```bash
# перенести serверы из Mac'овского ~/.claude.json в отдельный mcp.json
jq '{mcpServers}' ~/.claude.json > ~/.claude-docker/mcp.json
```

Формат файла — `{ "mcpServers": { "<имя>": { … } } }`. В нём лежат токены, поэтому он в
`.gitignore` / `.dockerignore` и монтируется read-only, вне примонтированного `state/`.

- Серверы с `type: stdio`, которые запускаются через `npx` (`mcp-remote`, `@sentry/mcp-server`,
  …), работают благодаря `nodejs`/`npm` в образе; скачанные пакеты кэшируются в volume
  `claude-npm-cache`, поэтому повторные старты быстрые.
- Нет файла — `start.sh` просто стартует без MCP (маунт добавляется, только если `mcp.json` есть).
- **devcontainer** свой `entrypoint.sh` не запускает (у него `postCreateCommand=setup-python-env.sh`),
  поэтому `--mcp-config` там не прокидывается — для него внеси `mcpServers` прямо в
  `state/.claude.json` либо запусти `claude mcp add …` внутри контейнера.

### 4. Глобальная команда

```bash
mkdir -p ~/bin
ln -sf ~/.claude-docker/start.sh ~/bin/claude-docker
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

which claude-docker      # -> /Users/<ты>/bin/claude-docker
```

Если пусто — открой новый терминал или ещё раз `source ~/.zshrc`.

---

## Первый запуск и логин

```bash
cd ~/Projects/my-project
claude-docker
```

Первый раз собирается образ — несколько минут (apt-пакеты + бинарь Claude ~180 МБ, прогресса почти
не видно, это норма). Когда откроется Claude Code и он ещё не залогинен:

1. Введи `/login`.
2. Открой показанную ссылку в браузере на Mac.
3. Авторизуйся под своим аккаунтом.
4. Вставь код обратно в терминал.

Логин ляжет в `~/.claude-docker/state` и переживёт перезапуски и пересборки образа.

---

## Ежедневное использование

```bash
cd ~/Projects/<любой-проект>
claude-docker
```

Выход — `exit` или Ctrl-D: контейнер удаляется (`--rm`), состояние и кэши остаются.

---

## Python и виртуальное окружение

Версия Python задаётся файлом `.python-version` (или `.python_version`) в корне проекта — полная
версия, кодировка/переводы строк не важны (из файла берутся только цифры и точки):

```
3.11.6
```

Зависимости — как обычно в Poetry, через `[tool.poetry]` в `pyproject.toml`. Без `.python-version`
venv строится на системном `python3` образа (3.12).

**Как это работает:** `setup-python-env.sh` (в образе, зовётся из `entrypoint.sh`) ставит нужный Python
через pyenv, затем `poetry env use` создаёт venv **на базе именно этой версии** в кэше Poetry (вне
`/workspace`); `entrypoint.sh` его активирует —
`python`/`pytest`/`ruff` доступны напрямую. Прямой установки «в сам Python» (`create=false`) тут
нельзя: на Ubuntu Poetry тогда целится в системный `python3.12`, залоченный PEP 668 — отсюда были
ошибки `externally-managed-environment`.

Где что физически лежит:

```
/workspace                                   ← проект с Mac (pyproject.toml, poetry.lock — на хосте)
/root/.pyenv/versions/<ver>                  ← скомпилированный Python (volume claude-pyenv-versions)
/root/.cache/pypoetry/virtualenvs/<...>      ← venv на базе этой версии (volume claude-poetry-cache)
```

Команды вызываются напрямую (venv активен):

```bash
python --version
pytest
poetry add requests        # ставит в venv и правит pyproject.toml / poetry.lock (на Mac)
poetry install --no-root   # установить по локу (только зависимости)
```

> `setup-python-env.sh` зовёт `poetry install` с `--no-root`: в контейнере нужны только зависимости, а не
> установка самого проекта как пакета (иначе app-репозитории без пакета-одноимёнки падают с
> `No file/folder found for package …`). Запускаешь код прямо из `/workspace`.

Первый запуск с новой версией Python компилирует её через pyenv (несколько минут); дальше и Python,
и venv с зависимостями берутся из volume'ов, поэтому старт быстрый.

---

## Переменные окружения

Всё задаётся при запуске (флаг `-e` в `start.sh` или экспорт в `entrypoint.sh`), Claude Code их только наследует:

| Переменная | Значение | Зачем | Где задаётся |
| --- | --- | --- | --- |
| `CLAUDE_CONFIG_DIR` | `/root/.claude` | Состояние/логин Claude + `CLAUDE.md` в примонтированном каталоге | `start.sh` |
| `PYENV_ROOT` | `/root/.pyenv` | Корень pyenv; версии — в `versions/` (volume) | `Dockerfile` |
| `POETRY_VIRTUALENVS_IN_PROJECT` | `false` | Не подхватывать/не трогать локальный `/workspace/.venv` с Mac | `Dockerfile` |
| `VIRTUAL_ENV` | путь venv Poetry | Сигнал «venv активен» | `entrypoint.sh` (после `poetry install`) |
| `PATH` | `<venv>/bin:$PATH` | Чтобы `python`/`pytest`/инструменты брались из venv | `entrypoint.sh` |

Всё задаётся в образе/лаунчере до `exec claude`; его bash-подпроцессы наследуют окружение.
`setup-python-env.sh` ставит нужный Python через pyenv и создаёт на нём venv (`poetry env use`),
`entrypoint.sh` его активирует. `CLAUDE.md` дополнительно явно сообщает Claude, где venv.

---

## Обслуживание

```bash
# пересобрать образ после правки Dockerfile
docker build -t claude-code-dev ~/.claude-docker

# полная пересборка (подтянуть свежие pyenv, Poetry и Claude Code)
docker build --no-cache -t claude-code-dev ~/.claude-docker
```

Новые системные инструменты — только в Dockerfile + пересборка (ручной `apt` в одноразовом
контейнере исчезнет). Проектные зависимости — только через `poetry` и `pyproject.toml`.

Сбросить скомпилированные Python и/или venv с зависимостями (если что-то поломалось):

```bash
docker volume rm claude-pyenv-versions claude-poetry-cache claude-npm-cache
```

---

## Devcontainer

Образ можно использовать как базу devcontainer'а; логин общий с `claude-docker`.
`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "claude-code-dev",
  "image": "claude-code-dev",

  "workspaceFolder": "/workspace",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",

  "mounts": [
    "source=${localEnv:HOME}/.claude-docker/state,target=/root/.claude,type=bind",
    "source=claude-pyenv-versions,target=/root/.pyenv/versions,type=volume",
    "source=claude-poetry-cache,target=/root/.cache/pypoetry,type=volume",
    "source=claude-npm-cache,target=/root/.npm,type=volume"
  ],

  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/root/.claude"
  },

  "remoteUser": "root",
  "postCreateCommand": "setup-python-env.sh"
}
```

Подключение: расширение **Dev Containers** → **Reopen in Container**, дальше `claude` в терминале
(первый раз — `/login`). Отличия от лаунчера: контейнер персистентный (без `--rm`), «с нуля» —
через **Rebuild Container**; логин переживает rebuild. Здесь `start.sh`/`entrypoint.sh` не выполняются,
поэтому подготовку venv делает тот же запечённый `setup-python-env.sh`, вызванный из `postCreateCommand`.
venv в кэше Poetry не активируется автоматически — вызывай инструменты через `poetry run <cmd>` либо активируй вручную:
`source "$(poetry env info --path)/bin/activate"`. Тем же путём укажи интерпретатор в VS Code
(**Python: Select Interpreter**). Не запускай `claude-docker` и devcontainer на одном проекте
одновременно — будет гонка за `.claude.json`.

---

## Что уже в образе

- **PDF**: `pdftotext file.pdf -`, `pdfinfo file.pdf`, для сканов `ocrmypdf in.pdf out.pdf`
  (OCR через `tesseract`, eng + rus).
- **Wireshark-дампы**: `tshark -r ture.pcapng` (например `-Y "http"`); только чтение `.pcap`/`.pcapng`, без GUI.
- **Dev**: git, jq, ripgrep, tree, vim, build-essential.

---

## Траблшутинг

| Симптом | Решение |
| --- | --- |
| `which claude-docker` пусто | Новый терминал или `source ~/.zshrc` |
| Долгая первая сборка без прогресса | Идёт скачивание бинаря Claude (~180 МБ), подожди |
| Просит логин каждый раз | Проверь `-e CLAUDE_CONFIG_DIR=/root/.claude` и монтирование `state` в `/root/.claude` |
| Зовётся не тот python | В логах старта строка `🐍 Python: … [путь]` покажет активный бинарь — должен быть внутри `/root/.cache/pypoetry/virtualenvs/…`; проверь `echo $VIRTUAL_ENV` (непусто) |
| `externally-managed-environment` (PEP 668) | Признак, что Poetry ставит в системный python3.12. Проверь, что в `Dockerfile` НЕТ `POETRY_VIRTUALENVS_CREATE=false` (venv должен создаваться) |
| `pyenv install` падает / версия не встала | Смотри вывод `pyenv install` в логах старта (там `BUILD FAILED` и какой библиотеки не хватило); недостающий `*-dev` пакет добавь в `Dockerfile` и пересобери. После неудачной сборки почисти том: `docker volume rm claude-pyenv-versions` |
| pyenv не подхватывает версию | Нужен файл `.python-version` или `.python_version` с полной версией (`3.11.6`); без него venv строится на системном Python |
| Долгий первый старт Python-проекта | pyenv компилирует CPython из исходников — разово, потом из volume `claude-pyenv-versions` |
| Ссылка логина не отдаёт код автоматически | Callback идёт на localhost внутри контейнера — используй ручной ввод кода из браузера |
| Apple Silicon | Ничего дополнительно указывать не нужно — образ, Python и Claude Code тянутся под arm64 сами |

---

## Ежедневная команда (итог)

```bash
cd ~/Projects/<project>
claude-docker
```