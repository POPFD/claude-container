FROM alpine:3.21

RUN apk add --no-cache \
        bash \
        bind-tools \
        conntrack-tools \
        iproute2 \
        iptables \
        ip6tables \
        ipset \
        libcap \
        openssl \
        python3 \
        py3-pytest \
        py3-yaml \
        tini \
        unbound \
    && unbound-control-setup

COPY fw-sidecar/reconcile.py /reconcile.py
COPY fw-sidecar/unbound-base.conf /etc/unbound/unbound.conf
COPY fw-sidecar/entrypoint.sh /entrypoint.sh
# Allowlist is baked in from the repo's top-level config/ dir. The
# build context is the repo root (see compose.yaml) so the path
# here is `config/allowlist.yaml`, not a sibling of the Dockerfile.
# Baking it in (rather than bind-mounting) keeps the deploy
# self-contained on hosts where the compose working dir does not
# contain the full repo (e.g. Portainer stacks).
COPY config/allowlist.yaml /etc/fw-sidecar/allowlist.yaml
RUN chmod +x /entrypoint.sh /reconcile.py

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
