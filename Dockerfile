FROM node:20-bookworm-slim

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

RUN apt-get update && apt-get install -y --no-install-recommends \
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

RUN mkdir -p /var/run/sshd /app /etc/sing-box "${TS_STATE_DIR}" \
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

mkdir -p /etc/sing-box "${TS_STATE_DIR}"

if [ -z "${TS_AUTHKEY}" ] && [ -z "${CF_TUNNEL_TOKEN}" ]; then
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

/usr/sbin/sshd -D &
SSHD_PID=$!

node /app/server.js &
NODE_PID=$!

if [ -n "${TS_AUTHKEY}" ]; then
  sing-box run -c /etc/sing-box/config.json &
  SB_PID=$!
fi

if [ -n "${CF_TUNNEL_TOKEN}" ]; then
  cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
  CF_PID=$!
fi

cleanup() {
  kill "${NODE_PID}" "${SSHD_PID}" 2>/dev/null || true

  [ -n "${SB_PID}" ] && kill "${SB_PID}" 2>/dev/null || true
  [ -n "${CF_PID}" ] && kill "${CF_PID}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

wait
EOF

RUN chmod +x /start.sh

EXPOSE 8000 22 3128 10001 10002 10003

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/generate_204" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/start.sh"]