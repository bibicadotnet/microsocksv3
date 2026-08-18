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
# Stage 2: Download usque (MASQUE client)
# ==========================================
FROM alpine:3.21 AS usque-downloader
RUN apk add --no-cache curl ca-certificates unzip \
    && update-ca-certificates
ARG USQUE_VERSION=4.2.1
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64|x86_64|"") arch=amd64 ;; \
        arm64|aarch64) arch=arm64 ;; \
        arm|arm/v7) arch=armv7 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}/usque_${USQUE_VERSION}_linux_${arch}.zip"; \
    echo "Downloading ${url}"; \
    curl -fsSL -o /tmp/usque.zip "${url}"; \
    unzip -q /tmp/usque.zip -d /tmp/usque-extract; \
    bin="$(find /tmp/usque-extract -type f -name 'usque' | head -n 1)"; \
    test -n "${bin}" && test -s "${bin}"; \
    install -m 755 "${bin}" /usr/local/bin/usque

# ==========================================
# Stage 3: Runtime
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
COPY --from=usque-downloader /usr/local/bin/usque /usr/bin/usque
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080/tcp
VOLUME ["/etc/wireguard"]

ENTRYPOINT ["/entrypoint.sh"]
