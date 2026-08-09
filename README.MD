# claude-docker

Изолированное окружение для **Claude Code** на macOS: одна команда `claude-docker`
поднимает одноразовый контейнер (Ubuntu 24.04) с `pyenv`, `poetry`, git и набором CLI-инструментов,
монтирует текущую папку проекта в `/workspace` и запускает Claude Code. После выхода контейнер
удаляется, но логин, история, настройки Claude и скомпилированные Python (с установленными в них
зависимостями) сохраняются.

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
| `.python-version` + `pyproject.toml` | Что нужно проекту (версия Python + зависимости) | в проекте, на Mac |
| Состояние Claude | Авторизация, история, настройки, permissions, skills, hooks | `~/.claude-docker/state` |
| Docker volume | Скомпилированные pyenv-Python (+ установленные в них зависимости) | `claude-pyenv-versions` |
| `/workspace` | Текущий проект с Mac (bind-mount) | папка проекта |

Осознанно **не** монтируются `~/.ssh` и `~/.gitconfig` — ключи остаются на Mac.

Ключевые решения:

- **Логин через аккаунт (OAuth), один раз.** Сохраняется, потому что `CLAUDE_CONFIG_DIR`
  складывает и `.credentials.json`, и `.claude.json` в один примонтированный каталог. Без
  `.claude.json` Claude Code считает запуск свежей установкой и снова просит вход.
- **Состояние контейнера отдельно от Mac'овского `~/.claude`.** На macOS Claude Code хранит токен
  в Keychain (недоступен из Linux) и удаляет файловый `.credentials.json`; общий каталог давал бы
  постоянные перелогины.
- **Без отдельного venv** (`POETRY_VIRTUALENVS_CREATE=false`) — Poetry ставит зависимости прямо в
  активный pyenv-Python, `python`/`pytest` доступны через шимы pyenv напрямую. На Mac не попадает
  нерабочий linux-venv, нет медленной записи в bind-mount.
- **pyenv компилирует CPython из исходников** — первая установка версии занимает минуты, но и сам
  Python, и установленные в него зависимости кэшируются в volume `claude-pyenv-versions`, поэтому
  повторные запуски мгновенны.

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
    # зависимости для сборки CPython через pyenv (компиляция из исходников)
    make libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev libncurses-dev libffi-dev liblzma-dev \
    xz-utils tk-dev \
    \
    # интерпретатор для самого Poetry + fallback, когда версия не запинена
    # python-is-python3: чтобы команда `python` существовала (в Ubuntu только python3)
    python3 python3-venv python3-dev python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# pyenv — управление версиями Python. Компиляция кэшируется в volume /root/.pyenv/versions.
ENV PYENV_ROOT=/root/.pyenv
RUN curl -fsSL https://pyenv.run | bash
ENV PATH="/root/.pyenv/bin:/root/.pyenv/shims:$PATH"

# Poetry (официальный установщик: бинарь в /root/.local/bin) + Claude Code (туда же)
RUN curl -sSL https://install.python-poetry.org | python3 - \
    && curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"

# без venv: Poetry ставит зависимости прямо в активный pyenv-Python.
# IN_PROJECT=false — чтобы Poetry НЕ подхватывал и не трогал локальный
# /workspace/.venv (это мак-овский venv с хоста, ему в контейнере делать нечего).
ENV POETRY_VIRTUALENVS_CREATE=false \
    POETRY_VIRTUALENVS_IN_PROJECT=false

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
- Версиями Python управляет `pyenv`, зависимостями — `poetry`. Системный pip не использовать.

## Python — без отдельного venv
- Виртуального окружения НЕТ (`POETRY_VIRTUALENVS_CREATE=false`). Poetry ставит зависимости
  прямо в активный pyenv-Python. `python`/`pytest`/`ruff` берутся через шимы pyenv.
- Проверка: `which python` → `/root/.pyenv/shims/python`, `python --version` → версия проекта.
- НЕ создавай/не трогай `.venv` в `/workspace` (это мак-овский venv с хоста, `POETRY_VIRTUALENVS_IN_PROJECT=false`
  велит Poetry его игнорировать), не зови `poetry shell`, не переключай интерпретатор вручную.
- `pyproject.toml` и `poetry.lock` лежат в `/workspace` (на Mac) — их изменения сохраняются.

## Версия Python
- Версию задаёт проект: файл `.python-version` (или `.python_version`) с полной версией, напр. `3.11.6`.
- При старте `start.sh` читает его, делает `pyenv install -s <ver>` (компиляция кэшируется в volume
  `claude-pyenv-versions`) и `pyenv global <ver>`.
- Без `.python-version` берётся системный `python3` (3.12) через `pyenv global system`.
- Хочешь другую версию — правь `.python-version` (на Mac) и перезапусти контейнер.

## Зависимости
- Добавить пакет: `poetry add <pkg>` (правит pyproject.toml + poetry.lock, ставит в текущий Python).
  После установки консольных скриптов может понадобиться `pyenv rehash`.
- Установить по локу: `poetry install --no-root` (в контейнере ставим только зависимости, не сам
  проект как пакет — так стартует `start.sh`).
- Для запиненной версии зависимости лежат в site-packages внутри volume и переживают перезапуск;
  для системного Python (без пина) — нет. Установка мимо poetry (`pip install`) не переживёт `--rm`.

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

Версия Python задаётся файлом `.python-version` (или `.python_version`) в корне проекта — полная
версия, кодировка/переводы строк не важны (из файла берутся только цифры и точки):

```
3.11.6
```

Зависимости — как обычно в Poetry, через `[tool.poetry]` в `pyproject.toml`. Без `.python-version`
берётся системный `python3` образа (3.12).

**Отдельного venv нет** (`POETRY_VIRTUALENVS_CREATE=false`): `poetry install` ставит зависимости
прямо в активный pyenv-Python, а `python`/`pytest`/`ruff` доступны через шимы pyenv.

Где что физически лежит:

```
/workspace                                   ← проект с Mac (pyproject.toml, poetry.lock — на хосте)
/root/.pyenv/versions/<ver>                  ← скомпилированный Python (volume claude-pyenv-versions)
/root/.pyenv/versions/<ver>/lib/.../site-packages ← сюда Poetry ставит зависимости (тот же volume)
```

Команды вызываются напрямую:

```bash
python --version
pytest
poetry add requests        # ставит в текущий Python и правит pyproject.toml / poetry.lock (на Mac)
poetry install --no-root   # установить по локу (только зависимости)
```

> `start.sh` зовёт `poetry install` с `--no-root`: в контейнере нужны только зависимости, а не
> установка самого проекта как пакета (иначе app-репозитории без пакета-одноимёнки падают с
> `No file/folder found for package …`). Запускаешь код прямо из `/workspace`.

Первый запуск с новой версией Python компилирует её через pyenv (несколько минут); дальше и Python,
и установленные в него зависимости берутся из volume, поэтому старт быстрый.

> Один volume на все проекты: пакеты живут в site-packages конкретной версии Python. Два проекта на
> одной версии делят site-packages — для одноразового контейнера, где работаешь по одному проекту,
> это осознанный размен на простоту (нет venv, нет лишних кэшей).

---

## Переменные окружения

Всё задаётся при запуске (в `start.sh`), Claude Code их только наследует:

| Переменная | Значение | Зачем | Где задаётся |
| --- | --- | --- | --- |
| `CLAUDE_CONFIG_DIR` | `/root/.claude` | Состояние/логин Claude + `CLAUDE.md` в примонтированном каталоге | `start.sh` |
| `PYENV_ROOT` | `/root/.pyenv` | Корень pyenv; версии — в `versions/` (volume) | `Dockerfile` |
| `PATH` | `…/.pyenv/bin:…/.pyenv/shims:…/.local/bin:$PATH` | Шимы pyenv + бинари Poetry/Claude | `Dockerfile` |
| `POETRY_VIRTUALENVS_CREATE` | `false` | Ставить зависимости в сам Python, без venv | `Dockerfile` |
| `POETRY_VIRTUALENVS_IN_PROJECT` | `false` | Не подхватывать/не трогать локальный `/workspace/.venv` с Mac | `Dockerfile` |

Всё задаётся в образе/лаунчере до `exec claude`; его bash-подпроцессы наследуют окружение. Нужную
версию Python выбирает `start.sh` через `pyenv global`. `CLAUDE.md` дополнительно явно сообщает
Claude, что venv нет и `python` — это шим pyenv.

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

Сбросить скомпилированные Python и установленные в них зависимости (если что-то поломалось):

```bash
docker volume rm claude-pyenv-versions
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
    "source=claude-pyenv-versions,target=/root/.pyenv/versions,type=volume"
  ],

  "containerEnv": {
    "CLAUDE_CONFIG_DIR": "/root/.claude"
  },

  "remoteUser": "root",
  "postCreateCommand": "if [ -f pyproject.toml ]; then V=\"\"; for f in .python-version .python_version; do [ -f \"$f\" ] && V=\"$(tr -cd '0-9.' < \"$f\")\" && [ -n \"$V\" ] && break; done; if [ -n \"$V\" ]; then pyenv install -s \"$V\"; pyenv global \"$V\"; else pyenv global system; fi; poetry install --no-root; pyenv rehash; fi"
}
```

Подключение: расширение **Dev Containers** → **Reopen in Container**, дальше `claude` в терминале
(первый раз — `/login`). Отличия от лаунчера: контейнер персистентный (без `--rm`), «с нуля» —
через **Rebuild Container**; логин переживает rebuild. Здесь `start.sh` не выполняется, поэтому выбор
версии Python и `poetry install` вынесены в `postCreateCommand` (venv нет — ставится прямо в
pyenv-Python). Для VS Code интерпретатор — `/root/.pyenv/shims/python` в **Python: Select
Interpreter**. Не запускай `claude-docker` и devcontainer на одном проекте одновременно — будет
гонка за `.claude.json`.

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
| Зовётся не тот python | `which python` → `/root/.pyenv/shims/python`, `python --version` → версия проекта; версию ставит `pyenv global` в `start.sh` |
| pyenv не подхватывает версию | Нужен файл `.python-version` или `.python_version` с полной версией (`3.11.6`); без него берётся системный Python |
| `pytest`/`ruff` не находятся после `poetry add` | Выполни `pyenv rehash` (создаёт шимы для новых консольных скриптов) |
| Долгий первый старт Python-проекта | pyenv компилирует CPython из исходников — разово, потом из volume `claude-pyenv-versions` |
| Ссылка логина не отдаёт код автоматически | Callback идёт на localhost внутри контейнера — используй ручной ввод кода из браузера |
| Apple Silicon | Ничего дополнительно указывать не нужно — образ, Python и Claude Code тянутся под arm64 сами |

---

## Ежедневная команда (итог)

```bash
cd ~/Projects/<project>
claude-docker
```