FROM jrei/systemd-debian:latest

ENV container=docker
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

STOPSIGNAL SIGRTMIN+3

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
    iproute2 \
    procps \
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

RUN mkdir -p /var/run/sshd /app /etc/sing-box "${TS_STATE_DIR}" /etc/systemd/system \
  && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

RUN cat > /app/server.js <<'EOF'
const http = require('http');

const port = Number.parseInt(process.env.PORT || '8000', 10);

const server = http.createServer((req, res) => {
  const path = (req.url || '/').split('?')[0];

  if (path === '/generate_204') {
    res.statusCode = 204;
    res.end();
    return;
  }

  res.statusCode = 200;
  res.end('Server OK!');
});

server.listen(port, '0.0.0.0');
EOF

RUN cat > /start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export SSH_PORT="${SSH_PORT:-22}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
export TTYD_PORT="${TTYD_PORT:-8022}"

mkdir -p /etc/sing-box "${TS_STATE_DIR}"

if [ -z "${TS_AUTHKEY:-}" ] && [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
  echo "ERROR: You must set TS_AUTHKEY or CF_TUNNEL_TOKEN"
  exit 1
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

cat > /etc/sing-box/config.json <<EOT
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      },
      {
        "type": "https",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 443,
        "path": "/dns-query"
      }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": ${MIXED_PORT}
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}"
        }
      ]
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "0.0.0.0",
      "listen_port": ${TROJAN_PORT},
      "users": [
        {
          "password": "${TROJAN_PASSWORD}"
        }
      ]
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "0.0.0.0",
      "listen_port": ${SHADOWSOCKS_PORT},
      "method": "${SHADOWSOCKS_METHOD}",
      "password": "${SHADOWSOCKS_PASSWORD}"
    }
  ],
  "endpoints": [
    {
      "type": "tailscale",
      "tag": "tailscale-ep",
      "state_directory": "${TS_STATE_DIR}",
      "auth_key": "${TS_AUTHKEY}",
      "hostname": "${TS_HOSTNAME}",
      "system_interface": false
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "mixed-in",
          "vless-in",
          "trojan-in",
          "shadowsocks-in"
        ],
        "action": "sniff"
      },
      {
        "inbound": [
          "mixed-in",
          "vless-in",
          "trojan-in",
          "shadowsocks-in"
        ],
        "action": "resolve",
        "server": "dns-local"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "dns-local"
    }
  }
}
EOT

SB_PID=""
CF_PID=""
TTYD_PID=""

if [ -z "${ALLOW_ROOT_LOGIN:-yes}" ] || [ "${ALLOW_ROOT_LOGIN}" = "yes" ]; then
  echo "root:${ROOT_PASSWORD}" | chpasswd
fi

/usr/sbin/sshd -D &
SSHD_PID=$!

node /app/server.js &
NODE_PID=$!

ttyd -p "${TTYD_PORT}" -c "root:${ROOT_PASSWORD}" bash &
TTYD_PID=$!

if [ -n "${TS_AUTHKEY:-}" ]; then
  sing-box run -c /etc/sing-box/config.json &
  SB_PID=$!
fi

if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
  CF_PID=$!
fi

cleanup() {
  kill "${NODE_PID}" "${SSHD_PID}" "${TTYD_PID}" 2>/dev/null || true

  [ -n "${SB_PID}" ] && kill "${SB_PID}" 2>/dev/null || true
  [ -n "${CF_PID}" ] && kill "${CF_PID}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

wait
EOF

RUN chmod +x /start.sh

RUN cat > /etc/systemd/system/my-node.service <<'EOF'
[Unit]
Description=My Node Stack
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PORT=8000
Environment=SSH_PORT=22
Environment=ROOT_PASSWORD=root
Environment=ALLOW_ROOT_LOGIN=yes
Environment=TS_AUTHKEY=
Environment=TS_HOSTNAME=my-node
Environment=TS_STATE_DIR=/var/lib/tailscale
Environment=CF_TUNNEL_TOKEN=
Environment=MIXED_PORT=3128
Environment=VLESS_PORT=10001
Environment=VLESS_UUID=d342d11e-d424-4583-b36e-524ab1f0afa4
Environment=TROJAN_PORT=10002
Environment=TROJAN_PASSWORD=trojan
Environment=SHADOWSOCKS_PORT=10003
Environment=SHADOWSOCKS_PASSWORD=ss
Environment=SHADOWSOCKS_METHOD=chacha20-ietf-poly1305
Environment=TTYD_PORT=8022
ExecStart=/start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
  && ln -sf /etc/systemd/system/my-node.service /etc/systemd/system/multi-user.target.wants/my-node.service

EXPOSE 8000 22 3128 10001 10002 10003 8022

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/generate_204" || exit 1

CMD ["/sbin/init"]