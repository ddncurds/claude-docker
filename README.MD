# claude-docker

Изолированное окружение для **Claude Code** на macOS: одна команда `claude-docker`
поднимает одноразовый контейнер (Ubuntu 24.04) с `uv`, Python, git и набором CLI-инструментов,
монтирует текущую папку проекта в `/workspace` и запускает Claude Code. После выхода контейнер
удаляется, но логин, история, настройки Claude и кэш uv/Python сохраняются.

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
| `Dockerfile` | Что умеет окружение (Ubuntu + инструменты + uv + Claude Code) | `~/.claude-docker/Dockerfile` |
| `pyproject.toml` | Что нужно проекту (версия Python + зависимости) | в проекте, на Mac |
| Состояние Claude | Авторизация, история, настройки, permissions, skills, hooks | `~/.claude-docker/state` |
| Docker volumes | Кэш uv и скачанные Python | `claude-uv-cache`, `claude-python` |
| `/workspace` | Текущий проект с Mac (bind-mount) | папка проекта |

Осознанно **не** монтируются `~/.ssh` и `~/.gitconfig` — ключи остаются на Mac.

Ключевые решения:

- **Логин через аккаунт (OAuth), один раз.** Сохраняется, потому что `CLAUDE_CONFIG_DIR`
  складывает и `.credentials.json`, и `.claude.json` в один примонтированный каталог. Без
  `.claude.json` Claude Code считает запуск свежей установкой и снова просит вход.
- **Состояние контейнера отдельно от Mac'овского `~/.claude`.** На macOS Claude Code хранит токен
  в Keychain (недоступен из Linux) и удаляет файловый `.credentials.json`; общий каталог давал бы
  постоянные перелогины.
- **venv вне bind-mount** (`/root/venv`) — на Mac не попадает нерабочий linux-venv, нет медленной
  записи в шару. venv активируется при старте, поэтому `python`/`pytest` доступны напрямую.

---

## Предусловия

Только **Docker Desktop** (установлен и запущен). uv и Python на Mac не нужны.

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
    && rm -rf /var/lib/apt/lists/*

# uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Claude Code (нативный установщик: бинарь в /root/.local/bin, не в /root/.claude)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"

# venv собирается копированием (кэш uv на отдельном volume, hardlink невозможен)
ENV UV_LINK_MODE=copy

WORKDIR /workspace
CMD ["bash"]
EOF

cat > ~/.claude-docker/.dockerignore << 'EOF'
state/
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
            # активируем venv: теперь python/pytest/claude видят его по умолчанию
            export VIRTUAL_ENV=/root/venv
            export PATH="/root/venv/bin:$PATH"
            echo; echo "🐍 Python:"; python --version; echo
        else
            echo "ℹ️  No pyproject.toml found"; echo
        fi

        exec claude
    '
EOF

chmod +x ~/.claude-docker/start.sh
```

### 2. Память Claude (CLAUDE.md)

Глобальный файл памяти — Claude Code читает его автоматически во всех проектах внутри контейнера.
Кладём в каталог состояния (в контейнере это `/root/.claude/CLAUDE.md`):

```bash
cat > ~/.claude-docker/state/CLAUDE.md << 'EOF'
# Среда выполнения

Ты работаешь ВНУТРИ одноразового Docker-контейнера (Ubuntu 24.04), а не на хост-Mac.
- Проект примонтирован в `/workspace` (= папка на Mac). Правки файлов тут сохраняются на хосте.
- Python управляется `uv`. Системный python и pip не использовать.

## Python / виртуальное окружение
- venv находится в `/root/venv` (переменная `UV_PROJECT_ENVIRONMENT=/root/venv`).
- Оно УЖЕ активировано при старте: выставлены `VIRTUAL_ENV=/root/venv` и `/root/venv/bin` в начале `PATH`.
- Поэтому вызывай `python`, `pytest`, `ruff` и т.д. напрямую — они берутся из venv.
  Проверка: `which python` → `/root/venv/bin/python`, `echo $VIRTUAL_ENV` → `/root/venv`.
- НЕ создавай `.venv` в `/workspace`, не переопределяй интерпретатор, не активируй venv заново.
- `pyproject.toml` и `uv.lock` лежат в `/workspace` (на Mac) — их изменения сохраняются.

## Зависимости
- Добавить пакет: `uv add <pkg>` (правит pyproject.toml + uv.lock, ставит в venv).
- Синхронизировать по локу: `uv sync`.
- venv эфемерный (контейнер с `--rm`): установка мимо uv (`pip install`) не переживёт перезапуск —
  всегда используй `uv add` / `uv sync`.

## Границы
- `~/.ssh` и `~/.gitconfig` в контейнер намеренно НЕ примонтированы — их здесь нет.
- Состояние Claude — в `/root/.claude` (`CLAUDE_CONFIG_DIR`); не трогай.

## Что уже стоит в образе
- PDF: pdftotext, pdfinfo, qpdf, ocrmypdf, tesseract (eng + rus).
- Сеть: tshark / tcpdump — анализ `.pcap` / `.pcapng` (только чтение файлов).
- Прочее: git, jq, ripgrep, tree.
EOF
```

### 3. Глобальная команда

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

Версия Python задаётся проектом:

```toml
[project]
requires-python = ">=3.11,<3.12"
```

Где что физически лежит:

```
/workspace                     ← проект с Mac (pyproject.toml, uv.lock — на хосте)
/root/venv                     ← сам venv (эфемерный, пересоздаётся при каждом запуске)
/root/.local/share/uv/python   ← скачанные Python  (volume claude-python)
/root/.cache/uv                ← кэш пакетов/колёс  (volume claude-uv-cache)
```

venv активируется при старте, поэтому команды вызываются напрямую:

```bash
python --version
pytest
uv add requests     # ставит в venv и правит pyproject.toml / uv.lock (на Mac)
uv sync             # синхронизировать по локу
```

venv пересоздаётся на каждый `claude-docker`, но это быстро — Python и колёса берутся из
persistent-volume'ов, а не качаются заново.

---

## Переменные окружения

Всё задаётся при запуске (в `start.sh`), Claude Code их только наследует:

| Переменная | Значение | Зачем |
| --- | --- | --- |
| `CLAUDE_CONFIG_DIR` | `/root/.claude` | Состояние/логин Claude + `CLAUDE.md` в примонтированном каталоге |
| `UV_PROJECT_ENVIRONMENT` | `/root/venv` | Куда `uv` кладёт venv (вне bind-mount) |
| `VIRTUAL_ENV` | `/root/venv` | Сигнал «venv активен» |
| `PATH` | `/root/venv/bin:$PATH` | Чтобы `python`/`pytest`/инструменты брались из venv |

Внутри Claude Code менять ничего не нужно — активация происходит до `exec claude`, и его
bash-подпроцессы наследуют окружение. `CLAUDE.md` дополнительно явно сообщает Claude, где venv.

---

## Обслуживание

```bash
# пересобрать образ после правки Dockerfile
docker build -t claude-code-dev ~/.claude-docker

# полная пересборка (подтянуть свежие uv и Claude Code)
docker build --no-cache -t claude-code-dev ~/.claude-docker
```

Новые системные инструменты — только в Dockerfile + пересборка (ручной `apt` в одноразовом
контейнере исчезнет). Проектные зависимости — только через `uv` и `pyproject.toml`.

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
    "source=claude-uv-cache,target=/root/.cache/uv,type=volume",
    "source=claude-python,target=/root/.local/share/uv,type=volume"
  ],

  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/root/.claude",
    "UV_PROJECT_ENVIRONMENT": "/root/venv",
    "VIRTUAL_ENV": "/root/venv",
    "PATH": "/root/venv/bin:${containerEnv:PATH}"
  },

  "customizations": {
    "vscode": {
      "settings": { "python.defaultInterpreterPath": "/root/venv/bin/python" }
    }
  },

  "remoteUser": "root",
  "postCreateCommand": "if [ -f pyproject.toml ]; then uv sync; fi"
}
```

Подключение: расширение **Dev Containers** → **Reopen in Container**, дальше `claude` в терминале
(первый раз — `/login`). Отличия от лаунчера: контейнер персистентный (без `--rm`), «с нуля» —
через **Rebuild Container**; логин переживает rebuild. Здесь `start.sh` не выполняется, поэтому
активация venv прописана в `containerEnv`. Не запускай `claude-docker` и devcontainer на одном
проекте одновременно — будет гонка за `.claude.json`.

---

## Что уже в образе

- **PDF**: `pdftotext file.pdf -`, `pdfinfo file.pdf`, для сканов `ocrmypdf in.pdf out.pdf`
  (OCR через `tesseract`, eng + rus).
- **Wireshark-дампы**: `tshark -r capture.pcapng` (например `-Y "http"`); только чтение `.pcap`/`.pcapng`, без GUI.
- **Dev**: git, jq, ripgrep, tree, vim, build-essential.

---

## Траблшутинг

| Симптом | Решение |
| --- | --- |
| `which claude-docker` пусто | Новый терминал или `source ~/.zshrc` |
| Долгая первая сборка без прогресса | Идёт скачивание бинаря Claude (~180 МБ), подожди |
| Просит логин каждый раз | Проверь `-e CLAUDE_CONFIG_DIR=/root/.claude` и монтирование `state` в `/root/.claude` |
| Claude не видит venv / зовёт системный python | Проверь `echo $VIRTUAL_ENV; which python` → оба на `/root/venv`; должны быть строки `export` после `uv sync` |
| Ссылка логина не отдаёт код автоматически | Callback идёт на localhost внутри контейнера — используй ручной ввод кода из браузера |
| Apple Silicon | Ничего дополнительно указывать не нужно — образ, uv и Claude Code тянутся под arm64 сами |

---

## Ежедневная команда (итог)

```bash
cd ~/Projects/<project>
claude-docker
```