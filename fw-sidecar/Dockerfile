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

COPY reconcile.py /reconcile.py
COPY unbound-base.conf /etc/unbound/unbound.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /reconcile.py

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
