FROM alpine:3.21

RUN apk add --no-cache \
        bash \
        bind-tools \
        conntrack-tools \
        iproute2 \
        iptables \
        ip6tables \
        ipset \
        openssl \
        python3 \
        py3-pytest \
        py3-yaml \
        tini \
        unbound \
    && unbound-control-setup

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
