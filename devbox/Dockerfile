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

WORKDIR /workspace
USER dev

ENV HOME=/home/dev
