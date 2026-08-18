# ==========================================
# Stage 1: Build microsocks
# ==========================================
FROM alpine:3.21 AS builder
RUN apk add --no-cache make gcc linux-headers git musl-dev && \
    git clone --depth 1 https://github.com/rofl0r/microsocks /opt/microsocks && \
    cd /opt/microsocks && \
    make LDFLAGS="-static" CFLAGS="-Os -pipe" && \
    strip --strip-all microsocks

# ==========================================
# Stage 2: Runtime
# ==========================================
FROM alpine:3.21
RUN apk add --no-cache \
        iproute2 \
        bash \
        wireguard-tools \
        iptables \
        curl \
        wget \
        ca-certificates \
        openresolv \
    && update-ca-certificates \
    && rm -rf /var/cache/apk/*

COPY --from=builder /opt/microsocks/microsocks /usr/bin/microsocks
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080/tcp
VOLUME ["/etc/wireguard"]

ENTRYPOINT ["/entrypoint.sh"]
