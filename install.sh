#!/usr/bin/env bash
set -Eeuo pipefail

REPO="SkyPip228/tblockernew"
REF="${TBLOCKER_REF:-main}"
INSTALL_DIR="/opt/tblocker"
CONFIG_PATH="$INSTALL_DIR/config.yaml"
SERVICE_PATH="/etc/systemd/system/tblocker.service"
AUTO_MODE=true
FORCED_FIREWALL=""
declare -a FORCED_LOGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'echo -e "\033[0;31m[ERROR]\033[0m Installation failed at line $LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  bash install.sh
  bash install.sh --interactive
  bash install.sh --logs /path/a.log,/path/b.log
  bash install.sh --firewall nft
  bash install.sh --firewall iptables

Environment:
  TBLOCKER_REF=main   Git branch/tag used for source fallback.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      AUTO_MODE=false
      shift
      ;;
    --logs)
      [[ $# -ge 2 ]] || die "--logs requires a comma-separated value"
      IFS=',' read -r -a FORCED_LOGS <<< "$2"
      shift 2
      ;;
    --firewall)
      [[ $# -ge 2 ]] || die "--firewall requires nft or iptables"
      FORCED_FIREWALL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root."

case "$(uname -m)" in
  x86_64) ARCH="amd64"; GO_ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64"; GO_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
else
  die "Supported package manager not found (apt/dnf/yum)."
fi

install_packages() {
  info "Installing required system packages..."
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates tar python3 conntrack >/dev/null
      ;;
    dnf)
      dnf install -y curl ca-certificates tar python3 conntrack-tools >/dev/null
      ;;
    yum)
      yum install -y curl ca-certificates tar python3 conntrack-tools >/dev/null
      ;;
  esac
  ok "System dependencies installed"
}

choose_firewall() {
  if [[ -n "$FORCED_FIREWALL" ]]; then
    case "$FORCED_FIREWALL" in
      nft|iptables) FIREWALL="$FORCED_FIREWALL" ;;
      *) die "--firewall must be nft or iptables" ;;
    esac
  elif command -v nft >/dev/null 2>&1; then
    FIREWALL="nft"
  elif command -v iptables >/dev/null 2>&1; then
    FIREWALL="iptables"
  else
    if [[ "$PKG" == "apt" ]]; then
      apt-get install -y -qq nftables >/dev/null
    elif [[ "$PKG" == "dnf" ]]; then
      dnf install -y nftables >/dev/null
    else
      yum install -y nftables >/dev/null
    fi
    FIREWALL="nft"
  fi

  if [[ "$FIREWALL" == "nft" ]] && ! command -v nft >/dev/null 2>&1; then
    case "$PKG" in
      apt) apt-get install -y -qq nftables >/dev/null ;;
      dnf) dnf install -y nftables >/dev/null ;;
      yum) yum install -y nftables >/dev/null ;;
    esac
  fi

  if [[ "$FIREWALL" == "iptables" ]] && ! command -v iptables >/dev/null 2>&1; then
    case "$PKG" in
      apt) apt-get install -y -qq iptables >/dev/null ;;
      dnf) dnf install -y iptables >/dev/null ;;
      yum) yum install -y iptables-services >/dev/null ;;
    esac
  fi

  ok "Firewall selected: $FIREWALL"
}

add_log_candidate() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0
  candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
  [[ -f "$candidate" ]] || return 0

  local existing
  for existing in "${LOG_FILES[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  LOG_FILES+=("$candidate")
}

ensure_log_candidate() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0

  mkdir -p "$(dirname "$candidate")"
  touch "$candidate"
  chmod 0644 "$candidate" || true
  add_log_candidate "$candidate"
}

discover_logs() {
  LOG_FILES=()

  if [[ ${#FORCED_LOGS[@]} -gt 0 ]]; then
    local p
    for p in "${FORCED_LOGS[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -n "$p" ]] || continue
      ensure_log_candidate "$p"
    done
    return
  fi

  local known
  for known in \
    /var/log/remnanode/access.log \
    /var/log/remnanode-*/access.log \
    /var/log/remnanode*/access.log \
    /var/lib/marzban-node/access.log \
    /var/lib/marzban-node-*/access.log; do
    for f in $known; do
      [[ -e "$f" ]] && add_log_candidate "$f"
    done
  done

  while IFS= read -r f; do
    add_log_candidate "$f"
  done < <(
    find /var/log /var/lib /opt \
      -maxdepth 5 -type f -name 'access.log' \
      \( -path '*remnanode*' -o -path '*marzban*' -o -path '*xray*' \) \
      2>/dev/null || true
  )

  if command -v docker >/dev/null 2>&1; then
    while IFS='|' read -r source destination; do
      source="$(echo "${source:-}" | xargs)"
      destination="$(echo "${destination:-}" | xargs)"
      [[ -n "$source" && -n "$destination" ]] || continue

      case "$destination" in
        */remnanode|*/remnanode/|/var/log/remnanode|/var/lib/marzban-node)
          ensure_log_candidate "$source/access.log"
          ;;
      esac
    done < <(
      docker ps -aq 2>/dev/null | while read -r cid; do
        docker inspect -f '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' "$cid" 2>/dev/null || true
      done
    )
  fi

  if [[ ${#LOG_FILES[@]} -eq 0 && "$AUTO_MODE" == "false" ]]; then
    read -r -p "Log file path(s), comma-separated: " raw
    IFS=',' read -r -a manual_logs <<< "$raw"
    local p
    for p in "${manual_logs[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -n "$p" ]] || continue
      ensure_log_candidate "$p"
    done
  fi

  if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
    local pending_log="/var/log/tblocker/pending-access.log"
    warn "No Xray/Remnawave nodes or access logs found. Server can still be prepared now."
    ensure_log_candidate "$pending_log"
    warn "Using placeholder log: $pending_log"
    warn "After adding a node, rerun the same installer once; it will detect the real node log(s), preserve backups, and update LogFiles automatically."
  fi

  ok "Configured ${#LOG_FILES[@]} log file(s):"
  local f
  for f in "${LOG_FILES[@]}"; do
    echo "  - $f"
  done
}

version_ge_124() {
  local version
  version="$(go env GOVERSION 2>/dev/null | sed 's/^go//' || true)"
  [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  (( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 24) ))
}

ensure_go() {
  if command -v go >/dev/null 2>&1 && version_ge_124; then
    return
  fi

  local goversion="1.24.0"
  info "Installing Go $goversion for source build..."
  local tmp="/tmp/go-${goversion}.tar.gz"
  curl -fL --retry 3 \
    "https://go.dev/dl/go${goversion}.linux-${GO_ARCH}.tar.gz" \
    -o "$tmp"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"
  export PATH="/usr/local/go/bin:$PATH"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ok "Go $(go version | awk '{print $3}') installed"
}

install_from_release() {
  local latest json asset_url
  json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
  latest="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name",""))' 2>/dev/null || true)"
  [[ -n "$latest" ]] || return 1

  asset_url="https://github.com/$REPO/releases/download/$latest/tblockernew-${latest}-linux-${ARCH}.tar.gz"
  info "Trying release $latest..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  if ! curl -fL --retry 3 "$asset_url" -o "$tmpdir/tblocker.tar.gz"; then
    rm -rf "$tmpdir"
    return 1
  fi

  tar -xzf "$tmpdir/tblocker.tar.gz" -C "$tmpdir"
  local bin
  bin="$(find "$tmpdir" -maxdepth 2 -type f -name tblocker -print -quit)"
  [[ -n "$bin" ]] || { rm -rf "$tmpdir"; return 1; }

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$bin" "$INSTALL_DIR/tblocker"

  local default_cfg
  default_cfg="$(find "$tmpdir" -maxdepth 2 -type f -name config.yaml.default -print -quit)"
  [[ -n "$default_cfg" ]] && install -m 0644 "$default_cfg" "$INSTALL_DIR/config.yaml.default"

  rm -rf "$tmpdir"
  ok "Installed tblocker release $latest"
}

install_from_source() {
  ensure_go
  info "Building tblocker from $REPO ref $REF..."

  local tmpdir archive srcdir
  tmpdir="$(mktemp -d)"
  archive="$tmpdir/source.tar.gz"

  if ! curl -fL --retry 3 "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" -o "$archive"; then
    curl -fL --retry 3 "https://github.com/$REPO/archive/refs/tags/$REF.tar.gz" -o "$archive"
  fi

  tar -xzf "$archive" -C "$tmpdir"
  srcdir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'tblockernew-*' -print -quit)"
  [[ -n "$srcdir" ]] || die "Unable to locate extracted source directory"

  (
    cd "$srcdir"
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.Version=source-$REF" -o "$tmpdir/tblocker" .
  )

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmpdir/tblocker" "$INSTALL_DIR/tblocker"
  install -m 0644 "$srcdir/config.yaml.default" "$INSTALL_DIR/config.yaml.default"
  rm -rf "$tmpdir"

  ok "Built and installed tblocker from source"
}

backup_existing() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$INSTALL_DIR"

  if [[ -f "$CONFIG_PATH" ]]; then
    cp -a "$CONFIG_PATH" "$CONFIG_PATH.backup-$stamp"
    info "Config backup: $CONFIG_PATH.backup-$stamp"
  fi
  if [[ -f "$INSTALL_DIR/tblocker" ]]; then
    cp -a "$INSTALL_DIR/tblocker" "$INSTALL_DIR/tblocker.backup-$stamp"
    info "Binary backup: $INSTALL_DIR/tblocker.backup-$stamp"
  fi
}

write_config() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    if [[ -f "$INSTALL_DIR/config.yaml.default" ]]; then
      cp "$INSTALL_DIR/config.yaml.default" "$CONFIG_PATH"
    else
      touch "$CONFIG_PATH"
    fi
  fi

  python3 - "$CONFIG_PATH" "$FIREWALL" "${LOG_FILES[@]}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
firewall = sys.argv[2]
logs = sys.argv[3:]

text = path.read_text() if path.exists() else ""
lines = text.splitlines()
out = []
skip_logs = False

for line in lines:
    if line.startswith("LogFiles:"):
        skip_logs = True
        continue
    if skip_logs:
        if line.startswith("  - "):
            continue
        skip_logs = False
    if line.startswith("LogFile:") or line.startswith("BlockMode:"):
        continue
    out.append(line)

header = ["LogFiles:"] + [f'  - "{p}"' for p in logs]
header += ["", f'BlockMode: "{firewall}"', ""]

path.write_text("\n".join(header + out).rstrip() + "\n")
PY

  ok "Configuration written: $CONFIG_PATH"
}

write_service() {
  cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=XRay Torrent Blocker Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/opt/tblocker/tblocker -c /opt/tblocker/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tblocker >/dev/null
  ok "systemd service installed"
}

self_check() {
  info "Running post-install checks..."

  systemctl restart tblocker
  sleep 2

  if ! systemctl is-active --quiet tblocker; then
    systemctl status tblocker --no-pager || true
    journalctl -u tblocker -n 80 --no-pager || true
    die "tblocker did not start"
  fi

  local missing=0 f
  for f in "${LOG_FILES[@]}"; do
    if [[ ! -r "$f" ]]; then
      warn "Log is not readable: $f"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || die "One or more configured logs are not readable"

  command -v conntrack >/dev/null 2>&1 || die "conntrack is missing"
  if [[ "$FIREWALL" == "nft" ]]; then
    command -v nft >/dev/null 2>&1 || die "nft is missing"
  else
    command -v iptables >/dev/null 2>&1 || die "iptables is missing"
  fi

  ok "Service is active"
  ok "Binary: $("$INSTALL_DIR/tblocker" -v 2>/dev/null || true)"
  ok "Firewall: $FIREWALL"
  ok "conntrack: available"

  echo
  echo "===== CONFIG ====="
  cat "$CONFIG_PATH"
  echo
  echo "===== SERVICE ====="
  systemctl --no-pager --full status tblocker | sed -n '1,14p'
  echo
  echo "===== LAST LOGS ====="
  journalctl -u tblocker -n 20 --no-pager
}

main() {
  echo "==============================================================="
  echo " tblockernew automatic installer"
  echo "==============================================================="

  install_packages
  choose_firewall
  discover_logs
  backup_existing

  if ! install_from_release; then
    warn "No compatible GitHub release found; using source build from ref: $REF"
    install_from_source
  fi

  write_config
  write_service
  self_check

  echo
  ok "Installation completed successfully"
  echo "Logs monitored:"
  local f
  for f in "${LOG_FILES[@]}"; do
    echo "  - $f"
  done
  echo
  echo "Useful commands:"
  echo "  systemctl status tblocker --no-pager"
  echo "  journalctl -u tblocker -f"
  echo "  cat /opt/tblocker/config.yaml"
}

main "$@"
