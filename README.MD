# claude-docker

Изолированное окружение для **Claude Code** на macOS и Linux: одна команда `claude-docker`
поднимает одноразовый контейнер (Ubuntu 24.04) с `pyenv`, `poetry`, git и набором CLI-инструментов,
монтирует текущую папку проекта в `/workspace` и запускает Claude Code. После выхода контейнер
удаляется, но логин, история, настройки Claude, скомпилированные Python и venv Poetry с
зависимостями сохраняются.

Различия между хостами вынесены в отдельный раздел — [Особенности Linux](#особенности-linux).

---

## Содержание

- [claude-docker](#claude-docker)
  - [Содержание](#содержание)
  - [Как это устроено](#как-это-устроено)
  - [Предусловия](#предусловия)
  - [Установка](#установка)
    - [1. Файлы окружения](#1-файлы-окружения)
    - [2. Память Claude (CLAUDE.md)](#2-память-claude-claudemd)
    - [3. MCP-серверы (опционально)](#3-mcp-серверы-опционально)
    - [4. Глобальная команда](#4-глобальная-команда)
  - [Первый запуск и логин](#первый-запуск-и-логин)
  - [Ежедневное использование](#ежедневное-использование)
  - [Python и виртуальное окружение](#python-и-виртуальное-окружение)
  - [Переменные окружения](#переменные-окружения)
  - [Обслуживание](#обслуживание)
  - [Особенности Linux](#особенности-linux)
  - [Devcontainer](#devcontainer)
  - [Что уже в образе](#что-уже-в-образе)
  - [Траблшутинг](#траблшутинг)
  - [Ежедневная команда (итог)](#ежедневная-команда-итог)

---

## Как это устроено

Разделение ответственности:

| Слой | За что отвечает | Где живёт |
| --- | --- | --- |
| `Dockerfile` | Что умеет окружение (Ubuntu + инструменты + pyenv + poetry + Claude Code) | `<env>/Dockerfile` |
| `start.sh` + `entrypoint.sh` + `setup-python-env.sh` | Как запускается сессия: `start.sh` поднимает контейнер, запечённый в образ `entrypoint.sh` готовит venv и стартует Claude (общий с devcontainer `setup-python-env.sh`) | `<env>/*.sh` → образ `/usr/local/bin` |
| `.python-version` + `pyproject.toml` | Что нужно проекту (версия Python + зависимости) | в проекте, на хосте |
| Состояние Claude | Авторизация, история, настройки, permissions, skills, hooks | `<env>/state` |
| Docker volumes | Скомпилированные pyenv-Python, venv/кэш Poetry и кэш npm (для MCP через npx) | `claude-pyenv-versions`, `claude-poetry-cache`, `claude-npm-cache` |
| `/workspace` | Текущий проект с хоста (bind-mount) | папка проекта |
| `mcp.json` *(опц.)* | Конфиг MCP-серверов с токенами; монтируется в `/root/mcp.json`, не в git | `<env>/mcp.json` |

`<env>` — каталог, куда склонирован этот репозиторий. Он **не** захардкожен: `start.sh` вычисляет
его из пути к самому себе (разматывая симлинк `~/bin/claude-docker`), поэтому окружение может лежать
где угодно — `~/.claude-docker`, `~/projects/claude-docker`, что угодно. Дальше в README он для
краткости пишется как `~/.claude-docker`.

Осознанно **не** монтируются `~/.ssh` и `~/.gitconfig` — ключи остаются на хосте.

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

Только Docker (установлен и запущен) — **Docker Desktop** на macOS, **Docker Desktop или Docker
Engine** на Linux. pyenv, Poetry и Python на хосте не нужны.

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker недоступен"
```

На Linux с Docker Engine `docker info` может падать с `permission denied ... docker.sock` — значит
пользователя нет в группе `docker`:

```bash
sudo usermod -aG docker "$USER"   # затем перелогиниться (или `newgrp docker`)
```

---

## Установка

### 1. Файлы окружения

Все файлы окружения — это и есть содержимое **этого репозитория**. Установка = склонировать его;
путь произвольный, `start.sh` находит своё окружение сам (см. `<env>` выше). Дальше в README
используется `~/.claude-docker`:

```bash
git clone https://github.com/ddncurds/claude-docker.git ~/.claude-docker
```

Что внутри (подробности — в [Как это устроено](#как-это-устроено)):

| Файл | Роль |
| --- | --- |
| `Dockerfile` | Образ: Ubuntu 24.04 + CLI-инструменты + pyenv + poetry + Claude Code |
| `start.sh` | Лаунчер: собирает образ при отсутствии, поднимает одноразовый контейнер, монтирует проект/состояние/кэши |
| `entrypoint.sh` | Команда контейнера: баннер → проверка логина → подготовка venv → активация → `exec claude` |
| `setup-python-env.sh` | Подготовка venv (pyenv + poetry). Общая копия для лаунчера и devcontainer |
| `.dockerignore` | Исключает `state/` и `mcp.json` из контекста сборки |

Правки этих файлов применяются пересборкой образа (см. [Обслуживание](#обслуживание)).

### 2. Память Claude (CLAUDE.md)

Файл `state/CLAUDE.md` — глобальная память Claude Code: внутри контейнера это `/root/.claude/CLAUDE.md`,
который читается автоматически во всех проектах. Он лежит в примонтированном `state/` (не в git),
и рассказывает агенту про среду:

- он работает **внутри** одноразового контейнера, проект — в `/workspace` (= папка на Mac);
- venv Poetry (на pyenv-Python, вне `/workspace`) **уже активирован** — `python`/`pytest`/`ruff`
  вызываются напрямую, `poetry shell` и повторная активация не нужны;
- версию Python задаёт `.python-version`, зависимости — только через `poetry` (не системный `pip`);
- `~/.ssh` и `~/.gitconfig` не примонтированы, `state/` трогать нельзя;
- что уже стоит в образе (PDF/OCR, tshark/tcpdump, git/jq/ripgrep/tree).

Файл авторский и создаётся один раз; без него Claude просто стартует без глобальной памяти.
Если меняешь логику активации venv в `entrypoint.sh`/`setup-python-env.sh` — обнови и обещание в
`state/CLAUDE.md`.

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

### 4. Глобальная команда (запуск из любой папки проекта)

Чтобы `claude-docker` вызывался из каталога любого проекта (а не только по полному пути
`~/.claude-docker/start.sh`), нужно положить исполняемую ссылку в каталог из `PATH`. Три шага:

```bash
# 1. Каталог для пользовательских команд (если ещё нет)
mkdir -p ~/bin

# 2. Симлинк на лаунчер под именем `claude-docker`
ln -sf ~/.claude-docker/start.sh ~/bin/claude-docker

# 3. Добавить ~/bin в PATH через конфиг своего shell
#    macOS (zsh по умолчанию):
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
#    Linux (bash по умолчанию):
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

Что происходит:

- **Шаг 2** делает `claude-docker` синонимом `start.sh` — правки скрипта в репозитории видны сразу,
  ничего пересоздавать не нужно (это симлинк, не копия). `start.sh` разматывает симлинк, чтобы
  найти свой каталог окружения (`Dockerfile`, `state/`, `mcp.json`), поэтому репозиторий может
  лежать где угодно.
- **Шаг 3** кладёт `~/bin` в `PATH`, поэтому shell находит команду из **любого** каталога. Сам
  `start.sh` монтирует в `/workspace` текущую папку (`PROJECT_DIR="$(pwd)"`) — значит из какого
  проекта запустил, тот и попадёт в контейнер.

Проверка:

```bash
which claude-docker      # -> /Users/<ты>/bin/claude-docker (macOS) | /home/<ты>/bin/claude-docker (Linux)
```

Если пусто — строка `export PATH=...` не применилась: открой новый терминал или ещё раз
`source` свой rc-файл. Если строка добавилась несколько раз — лишние дубли можно удалить,
достаточно одной.

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

## Особенности Linux

Окружение одинаковое (внутри контейнера всегда Ubuntu 24.04), различается только стык с хостом:

| Что | macOS (Docker Desktop) | Linux (Docker Engine) |
| --- | --- | --- |
| Доступ к демону | Docker Desktop запущен | Пользователь в группе `docker` (см. [Предусловия](#предусловия)) |
| Владелец файлов в `/workspace` | VirtioFS подменяет UID: файлы остаются твоими | Контейнер работает от `root` → **созданные им файлы принадлежат root** |
| git внутри контейнера | Владелец совпадает, вопросов нет | UID хоста ≠ root → git ругался бы `detected dubious ownership`; в образе для этого прописан `safe.directory` |
| Архитектура | arm64 (Apple Silicon) — тянется сама | обычно amd64 — тянется сама |

Про владельца файлов: если Claude в контейнере создал новый файл, на Linux-хосте он будет
`root:root`. Вернуть себе:

```bash
sudo chown -R "$USER:$USER" .
```

Ту же поправку можно сделать разово для всего проекта, если файлов накопилось много.

---

## Devcontainer

Образ можно использовать как базу devcontainer'а; логин общий с `claude-docker`. Готовый конфиг
лежит в этом репозитории — [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json).
Скопируй его в свой проект (образ `claude-code-dev` должен быть уже собран — см.
[Обслуживание](#обслуживание)):

```bash
mkdir -p .devcontainer
cp ~/.claude-docker/.devcontainer/devcontainer.json .devcontainer/
```

> В отличие от `start.sh`, devcontainer'у неоткуда узнать путь к окружению — в `mounts` он зашит как
> `${localEnv:HOME}/.claude-docker/state`. Если репозиторий склонирован в другой каталог, поправь
> этот `source=` в скопированном `devcontainer.json` на свой путь до `state/`.

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
| `which claude-docker` пусто | Новый терминал или `source ~/.zshrc` (macOS) / `source ~/.bashrc` (Linux) |
| `unable to prepare context: path "…/.claude-docker" not found` | Старый `start.sh` с захардкоженным `~/.claude-docker`. Обнови репозиторий: путь теперь вычисляется от самого скрипта |
| `permission denied … /var/run/docker.sock` (Linux) | Пользователь не в группе `docker` — см. [Предусловия](#предусловия) |
| Файлы проекта стали `root:root` (Linux) | Ожидаемо, см. [Особенности Linux](#особенности-linux): `sudo chown -R "$USER:$USER" .` |
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