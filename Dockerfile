FROM litespeedtech/openlitespeed:latest

ENV PORT=8000
ENV SSH_PORT=22
ENV ROOT_PASSWORD=root
ENV ALLOW_ROOT_LOGIN=yes
ENV TS_AUTHKEY=""
ENV TS_HOSTNAME=my-node
ENV TS_STATE_DIR=/var/lib/tailscale
ENV CF_TUNNEL_TOKEN=""
ENV MIXED_PORT=3128
ENV VLESS_PORT=10001
ENV VLESS_UUID="d342d11e-d424-4583-b36e-524ab1f0afa4"
ENV TROJAN_PORT=10002
ENV TROJAN_PASSWORD="trojan"
ENV SHADOWSOCKS_PORT=10003
ENV SHADOWSOCKS_PASSWORD="ss"
ENV SHADOWSOCKS_METHOD="chacha20-ietf-poly1305"
ENV TTYD_PORT=8022
ENV CUSTOM_START_CMD=""
ENV CUSTOM_RUN_CMD=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    nano \
    sudo \
    git \
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
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p --mode=0755 /usr/share/keyrings \
  && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
  && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
    | tee /etc/apt/sources.list.d/cloudflared.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends cloudflared \
  && rm -rf /var/lib/apt/lists/*

RUN ARCH="$(dpkg --print-architecture)" \
  && VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')" \
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

RUN mkdir -p /var/run/sshd /app /var/www/vhosts/localhost/html /usr/local/lsws/Example/html "${TS_STATE_DIR}" \
  && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

RUN cat > /start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export SSH_PORT="${SSH_PORT:-22}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
export TTYD_PORT="${TTYD_PORT:-8022}"
export PORT="${PORT:-8000}"
export CUSTOM_START_CMD="${CUSTOM_START_CMD:-}"
export CUSTOM_RUN_CMD="${CUSTOM_RUN_CMD:-}"

mkdir -p /var/www/vhosts/localhost/html /usr/local/lsws/Example/html "${TS_STATE_DIR}"

for root in /var/www/vhosts/localhost/html /usr/local/lsws/Example/html; do
  mkdir -p "${root}"
  printf 'Server OK!\n' > "${root}/index.html"
  : > "${root}/generate_204"
done

if [ -n "${CUSTOM_START_CMD}" ]; then
  echo "Running CUSTOM_START_CMD..."
  bash -lc "${CUSTOM_START_CMD}"
fi

ssh-keygen -A
echo "root:${ROOT_PASSWORD}" | chpasswd

cat > /etc/ssh/sshd_config <<EOT
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
PrintMotd no
ClientAliveInterval 60
ClientAliveCountMax 3
EOT

SB_PID=""
CF_PID=""
TTYD_PID=""
CUSTOM_RUN_PID=""
SOCK_PID=""

/usr/local/lsws/bin/lswsctrl start

socat TCP-LISTEN:"${PORT}",fork,reuseaddr TCP:127.0.0.1:80 &
SOCK_PID=$!

/usr/sbin/sshd -D &
SSHD_PID=$!

ttyd -p "${TTYD_PORT}" -c "root:${ROOT_PASSWORD}" bash &
TTYD_PID=$!

if [ -n "${CUSTOM_RUN_CMD}" ]; then
  echo "Starting CUSTOM_RUN_CMD..."
  bash -lc "${CUSTOM_RUN_CMD}" &
  CUSTOM_RUN_PID=$!
fi

if [ -n "${TS_AUTHKEY}" ]; then
  sing-box run -c /etc/sing-box/config.json &
  SB_PID=$!
fi

if [ -n "${CF_TUNNEL_TOKEN}" ]; then
  cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
  CF_PID=$!
fi

cleanup() {
  [ -n "${SOCK_PID}" ] && kill "${SOCK_PID}" 2>/dev/null || true
  [ -n "${TTYD_PID}" ] && kill "${TTYD_PID}" 2>/dev/null || true
  [ -n "${SSHD_PID}" ] && kill "${SSHD_PID}" 2>/dev/null || true
  [ -n "${SB_PID}" ] && kill "${SB_PID}" 2>/dev/null || true
  [ -n "${CF_PID}" ] && kill "${CF_PID}" 2>/dev/null || true
  [ -n "${CUSTOM_RUN_PID}" ] && kill "${CUSTOM_RUN_PID}" 2>/dev/null || true
  /usr/local/lsws/bin/lswsctrl stop >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

wait
EOF

RUN chmod +x /start.sh

EXPOSE 8000 80 443 7080 22 3128 10001 10002 10003 8022

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/generate_204" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/start.sh"]