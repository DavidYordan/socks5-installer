#!/usr/bin/env bash
set -euo pipefail

# ============================
# SOCKS5 Installer (3proxy)
# ============================
# 修复点总结（你刚才遇到的两个坑）：
# 1) 编译阶段：
#    - 直接在 make 命令行传 CFLAGS（哪怕 CFLAGS+=）会在子 make 中覆盖/干扰上游宏，
#      导致 nfds_t 等类型缺失、或意外启用 ODBC 触发 sqltypes.h 缺失。
#    - 解决：不在 make 命令行传 CFLAGS；改为“补丁式”追加到 src/Makefile.inc。
#
# 2) 运行阶段：
#    - 你的 config 里原来用 socks -i0.0.0.0，部分环境下这会导致 3proxy 不正常监听/直接退出。
#      （0.0.0.0 最稳的写法是：不写 -i，让它默认 bind all）
#    - 同时 config 使用 daemon 时，3proxy 会 fork 到后台并让前台进程退出（exit 0），
#      systemd 若用 Type=simple 会显示服务 dead（但后台可能还在跑，或被 systemd/cgroup 清理）。
#    - 解决：systemd 一律用 Type=forking + PIDFile，并在 config 写 pidfile；
#      bind 0.0.0.0 时不加 -i。

# ----------------------------
# Config (env overrides allowed)
# ----------------------------
SOCKS_USER="${SOCKS_USER:-socks}"
SOCKS_PASS="${SOCKS_PASS:-}"                # empty => random
SOCKS_PORT="${SOCKS_PORT:-1080}"            # "random" => random port
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"         # default safe: localhost only; for all interfaces set 0.0.0.0
ALLOW_CIDR="${ALLOW_CIDR:-}"                # recommended when BIND_ADDR != 127.0.0.1

INSTALL_DIR="${INSTALL_DIR:-/opt/3proxy}"
SRC_DIR="${SRC_DIR:-${INSTALL_DIR}/3proxy}"
CONFIG_DIR="${CONFIG_DIR:-/etc/3proxy}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/3proxy}"
SERVICE_NAME="${SERVICE_NAME:-socks5-3proxy}"

# install behavior
INSTALL_MODE="${INSTALL_MODE:-upgrade}"     # upgrade|reinstall|skip
KEEP_CONFIG="${KEEP_CONFIG:-0}"             # 1=keep existing config; 0=overwrite config
PIN_REF="${PIN_REF:-master}"                # master|tag|commit hash

# build behavior
# 不在 make 命令行传 CFLAGS，改为 patch Makefile.inc 追加
EXTRA_CFLAGS="${EXTRA_CFLAGS:- -Wno-error=format -Wno-format }"
ENABLE_ODBC="${ENABLE_ODBC:-0}"             # 1=enable ODBC build (requires dev headers), 0=disable ODBC for compatibility

# runtime behavior
PIDFILE="${PIDFILE:-/run/3proxy.pid}"

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
  python3 - <<'PY'
import random
print(random.randint(20000, 60000))
PY
}

rand_pass() {
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

  # 如果用户显式开启 ODBC，就尝试装 ODBC 头文件（可选）
  if [[ "${ENABLE_ODBC}" == "1" ]]; then
    if [[ "$pm" == "apt" ]]; then
      apt-get install -y unixodbc-dev || true
    elif [[ "$pm" == "dnf" || "$pm" == "yum" ]]; then
      (dnf -y install unixODBC-devel || yum -y install unixODBC-devel) || true
    fi
  fi
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

service_exists() {
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || \
  (have_systemd && systemctl list-unit-files | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service")
}

stop_service() {
  if have_systemd && service_exists; then
    systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  fi
}

remove_service_file() {
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  fi
  if have_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

uninstall_everything() {
  stop_service
  remove_service_file

  rm -f "$BIN_PATH" 2>/dev/null || true

  # config removal only if KEEP_CONFIG=0 and mode is reinstall
  if [[ "$KEEP_CONFIG" != "1" ]]; then
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
  fi

  # remove source/build dir only in reinstall
  rm -rf "$SRC_DIR" 2>/dev/null || true
}

open_firewall_port() {
  # Only attempt if user provided ALLOW_CIDR and BIND_ADDR is not localhost
  if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
    return 0
  fi

  if [[ -z "$ALLOW_CIDR" ]]; then
    echo "WARN: BIND_ADDR != 127.0.0.1 but ALLOW_CIDR is empty."
    echo "      Strongly recommended: restrict access via firewall/security-group (ALLOW_CIDR=x.x.x.x/32)."
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

# ----------------------------
# Config/service generation
# ----------------------------
write_config() {
  mkdir -p "$CONFIG_DIR"

  # If KEEP_CONFIG=1 and config exists, do nothing
  if [[ "$KEEP_CONFIG" == "1" && -f "${CONFIG_DIR}/3proxy.cfg" ]]; then
    return 0
  fi

  # bind 逻辑：
  # - 0.0.0.0：不要写 -i（你刚刚验证过 socks -pPORT 最稳定）
  # - 127.0.0.1 或具体 IP：写 -i<IP> 用于限制监听网卡
  local socks_line=""
  if [[ "$BIND_ADDR" == "0.0.0.0" || -z "$BIND_ADDR" ]]; then
    socks_line="socks -p${SOCKS_PORT}"
  else
    socks_line="socks -p${SOCKS_PORT} -i${BIND_ADDR}"
  fi

  cat >"${CONFIG_DIR}/3proxy.cfg" <<EOF
daemon
pidfile ${PIDFILE}
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

# auth with user/pass
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}

# SOCKS5 listener
${socks_line}
EOF
}

write_systemd() {
  mkdir -p /etc/systemd/system

  # 使用 Type=forking + PIDFile，避免 daemon 模式下 systemd 显示 dead 或清理子进程的问题
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=SOCKS5 proxy (3proxy)
After=network.target

[Service]
Type=forking
PIDFile=${PIDFILE}
ExecStartPre=/bin/rm -f ${PIDFILE}
ExecStart=${BIN_PATH} ${CONFIG_DIR}/3proxy.cfg
Restart=on-failure
RestartSec=2
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || true
}

# ----------------------------
# Build 3proxy
# ----------------------------
git_prepare_source() {
  mkdir -p "$INSTALL_DIR"

  if [[ ! -d "${SRC_DIR}/.git" ]]; then
    rm -rf "$SRC_DIR" 2>/dev/null || true
    git clone https://github.com/z3APA3A/3proxy "$SRC_DIR"
  else
    git -C "$SRC_DIR" fetch --all --prune
  fi

  pushd "$SRC_DIR" >/dev/null
  git checkout -f "$PIN_REF" >/dev/null 2>&1 || git checkout -f "origin/$PIN_REF" >/dev/null 2>&1 || true
  if [[ "$PIN_REF" == "master" || "$PIN_REF" == "main" ]]; then
    git reset --hard "origin/$PIN_REF" >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

patch_makefile_inc() {
  local mf="${SRC_DIR}/src/Makefile.inc"
  if [[ ! -f "$mf" ]]; then
    mf="$(find "$SRC_DIR" -maxdepth 3 -type f -name 'Makefile.inc' | head -n 1 || true)"
  fi
  if [[ -z "$mf" || ! -f "$mf" ]]; then
    echo "ERROR: cannot find Makefile.inc to patch."
    exit 1
  fi

  # Idempotent patch
  if grep -q "socks5-installer: extra flags" "$mf"; then
    return 0
  fi

  local odbc_flag=""
  if [[ "$ENABLE_ODBC" != "1" ]]; then
    odbc_flag="-DNOODBC"
  fi

  cat >>"$mf" <<EOF

# socks5-installer: extra flags (appended; safe & idempotent)
# - keep upstream feature macros intact
# - disable ODBC by default to avoid sqltypes.h missing
# - ensure nfds_t/poll related types are visible even on strict libc feature sets
CFLAGS += ${EXTRA_CFLAGS} ${odbc_flag} -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112L -D_REENTRANT -D_THREAD_SAFE

EOF
}

build_3proxy() {
  git_prepare_source
  pushd "$SRC_DIR" >/dev/null

  ln -sf Makefile.Linux Makefile
  patch_makefile_inc

  make clean >/dev/null 2>&1 || true
  make -j"$(nproc || echo 2)"

  if [[ -x ./bin/3proxy ]]; then
    install -m 0755 ./bin/3proxy "$BIN_PATH"
  elif [[ -x ./src/3proxy ]]; then
    install -m 0755 ./src/3proxy "$BIN_PATH"
  else
    echo "ERROR: 3proxy binary not found after build."
    echo "Debug listing (top 4 levels):"
    find . -maxdepth 4 -type f -name 3proxy -print
    exit 1
  fi

  popd >/dev/null
}

# ----------------------------
# Output
# ----------------------------
print_result() {
  echo "================================================="
  echo "SOCKS5 installed ✅"
  echo "Mode:      ${INSTALL_MODE} (KEEP_CONFIG=${KEEP_CONFIG})"
  echo "User:      ${SOCKS_USER}"
  echo "Password:  ${SOCKS_PASS}"
  echo "Bind:      ${BIND_ADDR}"
  echo "Port:      ${SOCKS_PORT}"
  if [[ -n "$ALLOW_CIDR" ]]; then
    echo "Allow CIDR:${ALLOW_CIDR}"
  else
    echo "Allow CIDR:(not set)"
  fi
  echo "ODBC:      $( [[ "$ENABLE_ODBC" == "1" ]] && echo enabled || echo disabled )"
  echo ""
  echo "Binary:    ${BIN_PATH}"
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

  case "$INSTALL_MODE" in
    upgrade|reinstall|skip) ;;
    *)
      echo "ERROR: INSTALL_MODE must be one of: upgrade|reinstall|skip"
      exit 1
      ;;
  esac

  if [[ "$INSTALL_MODE" == "skip" && -x "$BIN_PATH" ]]; then
    echo "Already installed at ${BIN_PATH}; INSTALL_MODE=skip -> exit."
    exit 0
  fi

  install_deps

  if [[ "$SOCKS_PORT" == "random" ]]; then
    SOCKS_PORT="$(rand_port)"
  fi
  if [[ -z "$SOCKS_PASS" ]]; then
    SOCKS_PASS="$(rand_pass)"
  fi

  if [[ "$INSTALL_MODE" == "reinstall" ]]; then
    uninstall_everything
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
