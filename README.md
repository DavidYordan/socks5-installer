# SOCKS5 Installer (3proxy)

This repo installs a SOCKS5 proxy using **3proxy** (built from source) with an **idempotent** installer script that works well on:
- **Ubuntu / Debian** (apt)
- **CentOS / RHEL / Rocky / Alma / TencentOS / Alibaba Cloud Linux** (yum/dnf)
- Many **lightweight cloud images** (as long as build tools can be installed)

It supports:
- **Default / Random / Custom** username, password, port
- **Safe-by-default** bind (`127.0.0.1`) to avoid accidentally creating a public open proxy
- Optional firewall allow-list via `ALLOW_CIDR`
- **systemd service** auto setup when systemd is present
- **Repeatable installs** with `INSTALL_MODE` and `KEEP_CONFIG`
- **Cross-distro build robustness**: avoids overriding upstream Makefile flags; disables ODBC by default to prevent `sqltypes.h` build failures

> ⚠️ If you expose SOCKS5 to the Internet, always apply an allow-list (`ALLOW_CIDR`) and also restrict in your cloud security group.

---

## Quick Install (One-liner)

### 1) Safe default (localhost only) ✅ Recommended
Installs and binds to `127.0.0.1:1080` by default.

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo bash
```

Use it via SSH tunnel from your client:

```bash
ssh -N -L 1080:127.0.0.1:1080 root@<SERVER_IP>
```

Then on your client:

```bash
curl --socks5-hostname socks:<PASSWORD_FROM_INSTALL_OUTPUT>@127.0.0.1:1080 https://ifconfig.me
```

---

### 2) Expose to network (bind 0.0.0.0) + allow-list (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  BIND_ADDR=0.0.0.0 SOCKS_PORT=1080 \
  ALLOW_CIDR=203.0.113.10/32 \
  bash
```

Test from an allowed client:

```bash
curl --socks5-hostname socks:<PASSWORD>@<SERVER_IP>:1080 https://ifconfig.me
```

> `ALLOW_CIDR=203.0.113.10/32` means only that single IP can connect.

---

### 3) Random password / random port
Random password is default when `SOCKS_PASS` is empty. Random port via `SOCKS_PORT=random`:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  SOCKS_PASS= SOCKS_PORT=random \
  bash
```

---

## Configuration / Parameters

All parameters are set via **environment variables**.

| Variable | Default | Description |
|---|---:|---|
| `SOCKS_USER` | `socks` | Username for SOCKS5 auth |
| `SOCKS_PASS` | *(random if empty)* | Password. If empty, a random password is generated |
| `SOCKS_PORT` | `1080` | Port. Use `random` for a random port (20000–60000) |
| `BIND_ADDR` | `127.0.0.1` | Listen address. Use `0.0.0.0` to accept remote connections |
| `ALLOW_CIDR` | *(empty)* | Allow-list CIDR for firewall (recommended when `BIND_ADDR != 127.0.0.1`) |
| `INSTALL_MODE` | `upgrade` | `upgrade` / `reinstall` / `skip` |
| `KEEP_CONFIG` | `0` | `1` keep existing config, `0` overwrite config |
| `PIN_REF` | `master` | Git ref for 3proxy: branch/tag/commit |
| `INSTALL_DIR` | `/opt/3proxy` | Base directory |
| `CONFIG_DIR` | `/etc/3proxy` | Config directory |
| `BIN_PATH` | `/usr/local/bin/3proxy` | Installed binary path |
| `SERVICE_NAME` | `socks5-3proxy` | systemd service name |
| `BUILD_CFLAGS` | *(safe defaults)* | **Additional** build flags appended to upstream Makefile (not overriding) |
| `ENABLE_ODBC` | `0` | `1` to enable ODBC build (requires ODBC dev headers), `0` disables ODBC to improve compatibility |

### What is `ALLOW_CIDR`?
`ALLOW_CIDR` is a **CIDR allow-list** describing which source IPs/networks can connect to your SOCKS port.

Examples:
- `203.0.113.10/32` → allow **one** public IP
- `203.0.113.0/24` → allow a **network range**
- `0.0.0.0/0` → allow **everyone** (strongly discouraged)

Typically **the same `ALLOW_CIDR` works across all servers** if your clients come from a single office IP or a bastion host.

---

## Install Modes (Idempotent Behavior)

### `INSTALL_MODE=upgrade` (default)
- Updates/installs 3proxy binary (overwrite)
- Writes systemd service (overwrite)
- Writes config (overwrite unless `KEEP_CONFIG=1`)
- Restarts service

```bash
sudo INSTALL_MODE=upgrade ./install.sh
```

### `INSTALL_MODE=reinstall`
- Stops & disables service
- Removes binary + (optionally) config + source dir
- Installs fresh

```bash
sudo INSTALL_MODE=reinstall ./install.sh
```

If you want a full reinstall **but keep your existing config**:

```bash
sudo INSTALL_MODE=reinstall KEEP_CONFIG=1 ./install.sh
```

### `INSTALL_MODE=skip`
If `BIN_PATH` already exists, exits without changes:

```bash
sudo INSTALL_MODE=skip ./install.sh
```

---

## Version Pinning (Make all servers identical)

To pin to a specific tag:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  PIN_REF=0.9.4 bash
```

To pin to a commit:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  PIN_REF=<commit_hash> bash
```

---

## Service Management (systemd)

When systemd is present, the installer creates a service:
- Service: `socks5-3proxy`
- Config: `/etc/3proxy/3proxy.cfg`
- Binary: `/usr/local/bin/3proxy`

Commands:

```bash
sudo systemctl status socks5-3proxy --no-pager
sudo systemctl restart socks5-3proxy
sudo journalctl -u socks5-3proxy -e --no-pager
```

If systemd is NOT present, run manually:

```bash
sudo /usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
```

---

## Uninstall

If you have `uninstall.sh` in the repo:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/uninstall.sh | sudo bash
```

If using `install.sh` only, you can also reinstall-cleanly:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  INSTALL_MODE=reinstall bash
```

---

## Examples (Common Scenarios)

### A) Localhost-only + SSH tunnel (recommended)
Server:

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo bash
```

Client:

```bash
ssh -N -L 1080:127.0.0.1:1080 root@<SERVER_IP>
curl --socks5-hostname socks:<PASSWORD>@127.0.0.1:1080 https://ifconfig.me
```

### B) Expose service to a bastion host only

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  BIND_ADDR=0.0.0.0 ALLOW_CIDR=<BASTION_PUBLIC_IP>/32 \
  SOCKS_PORT=1080 \
  bash
```

### C) Set custom user/pass/port

```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  SOCKS_USER=myuser SOCKS_PASS='MyStrongPass!' SOCKS_PORT=1080 \
  BIND_ADDR=0.0.0.0 ALLOW_CIDR=203.0.113.10/32 \
  bash
```

---

## Troubleshooting

### 1) Build fails with `sqltypes.h: No such file or directory`
This happens when building with ODBC enabled but the ODBC dev headers are missing.

By default, this installer disables ODBC for better compatibility (`ENABLE_ODBC=0`).
If you want ODBC, install headers and enable it:

Ubuntu/Debian:
```bash
sudo apt-get update -y
sudo apt-get install -y unixodbc-dev
```

CentOS/RHEL:
```bash
sudo yum install -y unixODBC-devel
# or: sudo dnf install -y unixODBC-devel
```

Then:
```bash
curl -fsSL https://raw.githubusercontent.com/DavidYordan/socks5-installer/main/install.sh | sudo \
  ENABLE_ODBC=1 bash
```

### 2) Build fails with `unknown type name 'nfds_t'`
This typically indicates the upstream Makefile feature macros were not applied.
This installer avoids overriding upstream CFLAGS and instead appends `BUILD_CFLAGS` (so the required macros remain intact).

### 3) Service is running but cannot connect
Check:
- Cloud security group inbound rules
- Firewall rules (`ufw` or `firewalld`)
- `BIND_ADDR` is correct (`127.0.0.1` only accepts local)
- Access is allowed by your `ALLOW_CIDR`

### 4) See config and listen port

```bash
cat /etc/3proxy/3proxy.cfg
ss -lntp | grep 3proxy || true
```

### 5) See logs

```bash
sudo journalctl -u socks5-3proxy -e --no-pager
```

---

## Security Notes (Read This)

- Avoid `BIND_ADDR=0.0.0.0` unless you **must** expose it.
- If exposed, always use:
  - **Strong password** (random per server is best)
  - **ALLOW_CIDR allow-list**
  - **Cloud security group allow-list**
- Consider running behind a bastion host, or only via SSH tunnel.

---

## License
Your repo license here. 3proxy has its own license in the upstream repository.
