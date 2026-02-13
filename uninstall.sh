#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-socks5-3proxy}"
CONFIG_DIR="${CONFIG_DIR:-/etc/3proxy}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/3proxy}"
INSTALL_DIR="${INSTALL_DIR:-/opt/3proxy}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)."
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
  systemctl disable --now "${SERVICE_NAME}.service" || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true
fi

rm -rf "$CONFIG_DIR" || true
rm -f "$BIN_PATH" || true
rm -rf "$INSTALL_DIR" || true

echo "Uninstalled."
