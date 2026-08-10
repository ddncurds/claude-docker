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
