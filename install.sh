#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config (env overrides allowed)
# ----------------------------
SOCKS_USER="${SOCKS_USER:-socks}"
SOCKS_PASS="${SOCKS_PASS:-}"                # empty => random
SOCKS_PORT="${SOCKS_PORT:-1080}"            # "random" => random port
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"         # default safe: localhost only
ALLOW_CIDR="${ALLOW_CIDR:-}"                # recommended when BIND_ADDR != 127.0.0.1
INSTALL_DIR="${INSTALL_DIR:-/opt/3proxy}"
CONFIG_DIR="${CONFIG_DIR:-/etc/3proxy}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/3proxy}"
SERVICE_NAME="${SERVICE_NAME:-socks5-3proxy}"

# ----------------------------
# Helpers
# ----------------------------
need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: please run as root (use sudo)."
    exit 1
  fi
}

rand_port() {
  # 20000-60000
  python3 - <<'PY'
import random
print(random.randint(20000, 60000))
PY
}

rand_pass() {
  # 18 bytes base64-ish (avoid / +)
  python3 - <<'PY'
import os, base64
s = base64.b64encode(os.urandom(18)).decode()
print(s.replace('/','').replace('+','').strip())
PY
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo "unknown"
  fi
}

install_deps() {
  local pm; pm="$(detect_pm)"
  if [[ "$pm" == "apt" ]]; then
    apt-get update -y
    apt-get install -y git build-essential make gcc libc6-dev libssl-dev ca-certificates python3
  elif [[ "$pm" == "dnf" ]]; then
    dnf -y install git make gcc openssl-devel ca-certificates python3
  elif [[ "$pm" == "yum" ]]; then
    yum -y install git make gcc openssl-devel ca-certificates python3
  else
    echo "ERROR: unsupported package manager. Please install: git gcc make openssl-dev python3"
    exit 1
  fi
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

open_firewall_port() {
  # Only attempt if user provided ALLOW_CIDR and BIND_ADDR is not localhost
  if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
    return 0
  fi

  if [[ -z "$ALLOW_CIDR" ]]; then
    echo "WARN: BIND_ADDR != 127.0.0.1 but ALLOW_CIDR is empty."
    echo "      Strongly recommended: restrict access via firewall (ALLOW_CIDR=x.x.x.x/32)."
    return 0
  fi

  # UFW (Ubuntu common)
  if command -v ufw >/dev/null 2>&1; then
    ufw allow from "$ALLOW_CIDR" to any port "$SOCKS_PORT" proto tcp >/dev/null || true
    return 0
  fi

  # firewalld (CentOS/RHEL common)
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOW_CIDR} port port=${SOCKS_PORT} protocol=tcp accept" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    return 0
  fi

  # iptables fallback (best-effort)
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -s "$ALLOW_CIDR" -j ACCEPT || true
    iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j DROP || true
    echo "WARN: iptables rules added but may not persist after reboot. Consider ufw or firewalld."
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat >"${CONFIG_DIR}/3proxy.cfg" <<EOF
daemon
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

# auth with user/pass
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}

# SOCKS5 listener
# -i internal(bind) address, -p port
socks -p${SOCKS_PORT} -i${BIND_ADDR}
EOF
}

write_systemd() {
  mkdir -p /etc/systemd/system
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=SOCKS5 proxy (3proxy)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONFIG_DIR}/3proxy.cfg
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
}

build_3proxy() {
  mkdir -p "$INSTALL_DIR"
  if [[ ! -d "${INSTALL_DIR}/3proxy" ]]; then
    git clone https://github.com/z3APA3A/3proxy "${INSTALL_DIR}/3proxy"
  fi
  pushd "${INSTALL_DIR}/3proxy" >/dev/null
  ln -sf Makefile.Linux Makefile
  make -j"$(nproc || echo 2)"
  # place binary in a stable path
  install -m 0755 ./src/3proxy "$BIN_PATH"
  popd >/dev/null
}

print_result() {
  echo "================================================="
  echo "SOCKS5 installed ✅"
  echo "User:      ${SOCKS_USER}"
  echo "Password:  ${SOCKS_PASS}"
  echo "Bind:      ${BIND_ADDR}"
  echo "Port:      ${SOCKS_PORT}"
  if [[ -n "$ALLOW_CIDR" ]]; then
    echo "Allow CIDR:${ALLOW_CIDR}"
  else
    echo "Allow CIDR:(not set)"
  fi
  echo ""
  echo "Config:    ${CONFIG_DIR}/3proxy.cfg"
  if have_systemd; then
    echo "Service:   systemctl status ${SERVICE_NAME} --no-pager"
    echo "Logs:      journalctl -u ${SERVICE_NAME} -e --no-pager"
  else
    echo "Run:       ${BIN_PATH} ${CONFIG_DIR}/3proxy.cfg"
  fi
  echo ""
  echo "Test (client side):"
  echo "  curl --socks5-hostname ${SOCKS_USER}:${SOCKS_PASS}@<SERVER_IP>:${SOCKS_PORT} https://ifconfig.me"
  echo "================================================="
}

main() {
  need_root
  install_deps

  if [[ "$SOCKS_PORT" == "random" ]]; then
    SOCKS_PORT="$(rand_port)"
  fi
  if [[ -z "$SOCKS_PASS" ]]; then
    SOCKS_PASS="$(rand_pass)"
  fi

  build_3proxy
  write_config

  if have_systemd; then
    write_systemd
  else
    echo "WARN: systemd not found; service not installed. You can run it manually:"
    echo "  ${BIN_PATH} ${CONFIG_DIR}/3proxy.cfg"
  fi

  open_firewall_port
  print_result
}

main "$@"
