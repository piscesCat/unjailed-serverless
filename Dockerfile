# syntax=docker/dockerfile:1.4
FROM litespeedtech/openlitespeed:latest

ENV PORT=8000
ENV HTTPS_PORT=8443
ENV SSH_PORT=22
ENV ROOT_PASSWORD=root
ENV ALLOW_ROOT_LOGIN=yes
ENV TS_AUTHKEY=""
ENV TS_HOSTNAME=my-node
ENV TS_STATE_DIR=/var/lib/tailscale
ENV CF_TUNNEL_TOKEN=""
ENV MIXED_PORT=3128
ENV VLESS_PORT=10001
ENV VLESS_UUID=d342d11e-d424-4583-b36e-524ab1f0afa4
ENV TROJAN_PORT=10002
ENV TROJAN_PASSWORD=trojan
ENV SHADOWSOCKS_PORT=10003
ENV SHADOWSOCKS_PASSWORD=ss
ENV SHADOWSOCKS_METHOD=chacha20-ietf-poly1305
ENV TTYD_PORT=8022
ENV CUSTOM_START_CMD=""
ENV CUSTOM_RUN_CMD=""
ENV OLS_PASSWORD=123456
ENV REDIS_PASSWORD=redis123456
ENV REDIS_PORT=6379
ENV REDIS_USER=default

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    nano \
    sudo \
    git \
    apt-utils \
    openssh-server \
    bash \
    curl \
    gnupg \
    ca-certificates \
    lsb-release \
    apt-transport-https \
    tini \
    iproute2 \
    procps \
    socat \
    redis-server \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p --mode=0755 /usr/share/keyrings \
    && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
    | tee /etc/apt/sources.list.d/cloudflared.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflared \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(dpkg --print-architecture) \
    && VERSION=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep '"tag_name":' | cut -d '"' -f4 | sed 's/^v//') \
    && curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz \
    && tar -xzf /tmp/sb.tar.gz -C /tmp \
    && mv /tmp/sing-box-*/sing-box /usr/local/bin/sing-box \
    && chmod +x /usr/local/bin/sing-box \
    && rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

RUN ARCH_TRIPLE="$(uname -m)" && \
    case "$ARCH_TRIPLE" in \
      x86_64)  TTYD_ARCH="x86_64" ;; \
      aarch64) TTYD_ARCH="aarch64" ;; \
      armv7l)  TTYD_ARCH="armv7l" ;; \
      i686)    TTYD_ARCH="i686" ;; \
      *)       echo "Unsupported arch: $ARCH_TRIPLE"; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /tmp/ttyd && \
    chmod +x /tmp/ttyd && \
    mv /tmp/ttyd /usr/local/bin/ttyd

RUN mkdir -p /var/run/sshd /app /etc/sing-box "${TS_STATE_DIR}" /var/www/vhosts/localhost/html \
    && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8000 22 3128 10001 10002 10003 8022 7080 8088 8443 6379

HEALTHCHECK -interval=30s --timeout=5s --start-period=10s --retries=3 \
CMD curl -fsS "http://127.0.0.1:${PORT}/generate_204" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/start.sh"]
