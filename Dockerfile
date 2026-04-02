# syntax=docker/dockerfile:1.7

ARG DEBIAN_VERSION=bookworm

FROM --platform=linux/amd64 debian:${DEBIAN_VERSION}-slim AS build

ARG VCS_REF=unknown

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    libssl-dev \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

RUN make clean \
 && make \
    COMMIT="${VCS_REF}" \
    CFLAGS='-O3 -std=gnu11 -Wall -Wno-array-bounds -mpclmul -march=core2 -mfpmath=sse -mssse3 -fno-strict-aliasing -fno-strict-overflow -fwrapv -DAES=1 -D_GNU_SOURCE=1 -D_FILE_OFFSET_BITS=64' \
    LDFLAGS='-ggdb -rdynamic -lm -lrt -lcrypto -lz -lpthread'

FROM --platform=linux/amd64 debian:${DEBIAN_VERSION}-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home-dir /var/lib/mtproxy --create-home --shell /usr/sbin/nologin mtproxy

COPY --from=build /src/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/mtproto-proxy /docker-entrypoint.sh

ENV DATA_DIR=/data \
    PORT=443 \
    STATS_PORT=8888 \
    WORKERS=1 \
    MT_USER=mtproxy \
    REFRESH_PROXY_CONFIG=1 \
    REFRESH_PROXY_SECRET=0

VOLUME ["/data"]

EXPOSE 443/tcp 8888/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${STATS_PORT}/stats" >/dev/null || exit 1

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
