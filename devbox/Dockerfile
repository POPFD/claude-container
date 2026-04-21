FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base OS packages. Toolchains are added in a later layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        gosu \
        libcap2-bin \
        openssh-client \
        pkg-config \
        sudo \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Non-root dev user (uid/gid 1000). Ubuntu 24.04 ships a default
# `ubuntu` user at uid 1000 — delete it so our `dev` can take the
# slot.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd --create-home --shell /bin/bash --uid 1000 dev \
    && mkdir -p /workspace \
    && chown dev:dev /workspace

# --------------------------------------------------------------------
# Python baseline (python3 + pip + venv) — installed as root.
# Keep this above the USER switch so apt has permissions.
# --------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------
# Node.js LTS via NodeSource (glibc-compatible, ships current LTS).
# --------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------
# Switch to dev for user-owned toolchains (rustup, uv).
# --------------------------------------------------------------------
WORKDIR /workspace
USER dev
ENV HOME=/home/dev \
    PATH=/home/dev/.cargo/bin:/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    RUSTUP_HOME=/home/dev/.rustup \
    CARGO_HOME=/home/dev/.cargo \
    UV_NO_UPDATE_CHECK=1

# Rust stable + clippy + rustfmt via rustup.
RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --no-modify-path \
        --default-toolchain stable \
        --profile minimal \
        --component clippy --component rustfmt \
    && rm /tmp/rustup.sh \
    && cargo --version && rustc --version

# uv (Python package manager) — installs into ~/.local/bin.
RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && uv --version

# Persist PATH/env for interactive shells (docker exec -it ... bash -l).
RUN printf '\n# devbox toolchain env\nexport PATH="/home/dev/.cargo/bin:/home/dev/.local/bin:$PATH"\nexport UV_NO_UPDATE_CHECK=1\n' >> /home/dev/.bashrc \
    && printf '\n# devbox toolchain env\nexport PATH="/home/dev/.cargo/bin:/home/dev/.local/bin:$PATH"\nexport UV_NO_UPDATE_CHECK=1\n' >> /home/dev/.profile
