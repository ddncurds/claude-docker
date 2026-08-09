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
