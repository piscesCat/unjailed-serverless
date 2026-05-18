#!/usr/bin/env bash
set -euo pipefail

export SSH_PORT="${SSH_PORT:-22}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
export TTYD_PORT="${TTYD_PORT:-8022}"
export PORT="${PORT:-8000}"
export HTTPS_PORT="${HTTPS_PORT:-8443}"
export CUSTOM_START_CMD="${CUSTOM_START_CMD:-}"
export CUSTOM_RUN_CMD="${CUSTOM_RUN_CMD:-}"
export OLS_PASSWORD="${OLS_PASSWORD:-123456}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-redis123456}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_USER="${REDIS_USER:-default}"

mkdir -p /etc/sing-box "${TS_STATE_DIR}" /var/www/vhosts/localhost/html /var/lib/redis

printf 'Server OK!\n' > /var/www/vhosts/localhost/html/index.html
: > /var/www/vhosts/localhost/html/generate_204

if [ -n "${CUSTOM_START_CMD}" ]; then
    echo "Running CUSTOM_START_CMD..."
    bash -lc "${CUSTOM_START_CMD}"
fi

ssh-keygen -A
echo "root:${ROOT_PASSWORD}" | chpasswd

cat > /etc/ssh/sshd_config <<SSHD_EOF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
PrintMotd no
ClientAliveInterval 60
ClientAliveCountMax 3
SSHD_EOF

cat > /etc/sing-box/config.json <<SB_EOF
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
SB_EOF

if [ -f /etc/redis/redis.conf ]; then
    sed -i 's/^bind .*/bind 0.0.0.0/' /etc/redis/redis.conf
    sed -i "s/^port .*/port ${REDIS_PORT}/" /etc/redis/redis.conf
    sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf
    sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf
    
    if [ "${REDIS_USER}" = "default" ]; then
        sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" /etc/redis/redis.conf
    else
        sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" /etc/redis/redis.conf
        echo "user ${REDIS_USER} on >${REDIS_PASSWORD} ~* &* +@all" >> /etc/redis/redis.conf
    fi
fi

if [ -n "${CUSTOM_RUN_CMD}" ]; then
    echo "Starting CUSTOM_RUN_CMD..."
    bash -lc "${CUSTOM_RUN_CMD}" &
    CUSTOM_RUN_PID=$!
fi

cleanup_ols_config() {
    local cfg="/usr/local/lsws/conf/httpd_config.conf"

    [ -f "$cfg" ] || return 0

    sed -i -E "s#(\*:[[:space:]]*)80([^0-9]|$)#\1${PORT}\2#g" "$cfg"
    sed -i -E "s#(\*:[[:space:]]*)443([^0-9]|$)#\1${HTTPS_PORT}\2#g" "$cfg"
}

SB_PID=""
CF_PID=""
TTYD_PID=""
CUSTOM_RUN_PID=""
SSHD_PID=""
REDIS_PID=""

cleanup_ols_config

/usr/local/lsws/admin/misc/admpass.sh <<PASS_EOF
admin
${OLS_PASSWORD}
${OLS_PASSWORD}
PASS_EOF

/usr/local/lsws/bin/lswsctrl start

redis-server /etc/redis/redis.conf &
REDIS_PID=$!

/usr/sbin/sshd -D &
SSHD_PID=$!

ttyd -p "${TTYD_PORT}" -c "root:${ROOT_PASSWORD}" bash &
TTYD_PID=$!

if [ -n "${TS_AUTHKEY}" ]; then
    sing-box run -c /etc/sing-box/config.json &
    SB_PID=$!
fi

if [ -n "${CF_TUNNEL_TOKEN}" ]; then
    cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
    CF_PID=$!
fi

cleanup() {
    [ -n "${SSHD_PID}" ] && kill "${SSHD_PID}" 2>/dev/null || true
    [ -n "${TTYD_PID}" ] && kill "${TTYD_PID}" 2>/dev/null || true
    [ -n "${SB_PID}" ] && kill "${SB_PID}" 2>/dev/null || true
    [ -n "${CF_PID}" ] && kill "${CF_PID}" 2>/dev/null || true
    [ -n "${REDIS_PID}" ] && kill "${REDIS_PID}" 2>/dev/null || true
    [ -n "${CUSTOM_RUN_PID}" ] && kill "${CUSTOM_RUN_PID}" 2>/dev/null || true

    /usr/local/lsws/bin/lswsctrl stop >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

wait
