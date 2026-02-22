#!/usr/bin/env bash
#
# AnyTLS-Go 服务端安装脚本（第一性原理重写）
# 项目: https://github.com/anytls/anytls-go
#
# 设计原则:
# - 单一职责: 仅完成「安装二进制 + 配置 + systemd 并启动」
# - 配置唯一来源: /etc/anytls/anytls.env（PORT、PASSWORD）
# - 安全: 不输出密码；使用 GitHub Release 的 digest 校验下载
# - 可移植: 仅用 POSIX + Bash，解析用 sed/awk，可选 jq 解析 API
#

set -e
set -o pipefail

readonly REPO_API='https://api.github.com/repos/anytls/anytls-go/releases/latest'
readonly BINARY_NAME='anytls-server'
readonly INSTALL_PREFIX='/usr/local/bin'
readonly CONFIG_DIR='/etc/anytls'
readonly CONFIG_FILE="${CONFIG_DIR}/anytls.env"
readonly SERVICE_NAME='anytls'
readonly SERVICE_USER='anytls'

# -----------------------------------------------------------------------------
# 日志与退出
# -----------------------------------------------------------------------------
log_info()  { printf '\033[32m[INFO]\033[0m %s\n' "$1"; }
log_warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$1"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

cleanup() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
    log_info "清理临时目录: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# 环境检测：root、架构、包管理器
# -----------------------------------------------------------------------------
require_root() {
  [ "$(id -u)" -eq 0 ] || log_error "请使用 root 运行此脚本（如 sudo $0）"
}

detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo 'linux_amd64'; ;;
    aarch64|arm64) echo 'linux_arm64'; ;;
    *) log_error "不支持的架构: $arch（仅支持 linux_amd64 / linux_arm64）"; ;;
  esac
}

# 安装运行脚本所需依赖（curl、unzip、可选 jq）
install_deps() {
  log_info "安装依赖: curl, unzip..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl unzip
    command -v jq &>/dev/null || apt-get install -y -qq jq
  elif command -v dnf &>/dev/null; then
    dnf install -y curl unzip jq 2>/dev/null || dnf install -y curl unzip
  elif command -v yum &>/dev/null; then
    yum install -y curl unzip 2>/dev/null || true
  elif command -v apk &>/dev/null; then
    apk add --no-cache curl unzip
    command -v jq &>/dev/null || apk add --no-cache jq
  else
    log_error "未检测到支持的包管理器 (apt/dnf/yum/apk)。请先安装 curl 与 unzip。"
  fi
}

# -----------------------------------------------------------------------------
# 从 GitHub API 获取最新 release 的下载 URL 与 digest（用于校验）
# -----------------------------------------------------------------------------
fetch_release_info() {
  local arch_tag=$1
  local api_json
  api_json=$(curl -sL --connect-timeout 10 --max-time 30 "$REPO_API") || log_error "无法获取 GitHub API: $REPO_API"

  if command -v jq &>/dev/null; then
    local url digest name
    url=$(echo "$api_json" | jq -r --arg a "$arch_tag" '.assets[] | select(.name | test($a)) | .browser_download_url' | head -n1)
    digest=$(echo "$api_json" | jq -r --arg a "$arch_tag" '.assets[] | select(.name | test($a)) | .digest' | head -n1)
    name=$(echo "$api_json" | jq -r --arg a "$arch_tag" '.assets[] | select(.name | test($a)) | .name' | head -n1)
  else
    local block
    block=$(echo "$api_json" | grep -A 14 "\"name\": \"anytls_.*_${arch_tag}.zip\"" | head -n 15)
    url=$(echo "$block" | grep "browser_download_url" | sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' | head -n1)
    digest=$(echo "$block" | grep '"digest"' | sed -n 's/.*"digest": "\([^"]*\)".*/\1/p' | head -n1)
    name="${arch_tag}.zip"
  fi

  [ -z "$url" ] && log_error "未找到适配 $arch_tag 的 release 资源"
  echo "$url"
  echo "$digest"
  echo "$name"
}

# 校验文件 digest（GitHub 格式为 sha256:hex）
verify_digest() {
  local file=$1
  local expected=$2
  [ -z "$expected" ] && return 0
  [ ! -f "$file" ] && return 1
  local algo hash
  algo="${expected%%:*}"
  hash="${expected#*:}"
  local actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    log_warn "未找到 sha256sum/shasum，跳过完整性校验"
    return 0
  fi
  [ "$algo" = "sha256" ] && [ "$actual" = "$hash" ] || log_error "校验失败: 期望 $hash，得到 $actual"
}

# -----------------------------------------------------------------------------
# 端口与密码：参数 > 环境变量 > 交互 > 随机
# -----------------------------------------------------------------------------
parse_args() {
  PORT=""
  PASSWORD=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)     PORT="$2"; shift 2 ;;
      --password) PASSWORD="$2"; shift 2 ;;
      -h|--help)
        echo "用法: $0 [--port PORT] [--password PASSWORD]"
        echo "  不传则交互输入或随机生成。"
        exit 0
        ;;
      *) log_error "未知参数: $1（可用 --port, --password, --help）" ;;
    esac
  done
}

prompt_port() {
  local p
  if [ -n "$PORT" ]; then
    p="$PORT"
  else
    read -r -p "监听端口 (回车随机): " p
    if [ -z "$p" ]; then
      p=$(od -An -N2 -i /dev/urandom 2>/dev/null | awk '{print int($1%40000)+20000}' || echo "28443")
    fi
  fi
  echo "$p"
}

prompt_password() {
  local pw
  if [ -n "$PASSWORD" ]; then
    pw="$PASSWORD"
  else
    read -r -sp "连接密码 (回车随机): " pw
    echo >&2
    if [ -z "$pw" ]; then
      pw=$(openssl rand -base64 16 2>/dev/null | tr -d '=+/' | cut -c1-16) || pw="anytls-$(date +%s)"
    fi
  fi
  echo "$pw"
}

# -----------------------------------------------------------------------------
# 安装：下载 → 校验 → 安装二进制、配置、systemd
# -----------------------------------------------------------------------------
install_binary_and_service() {
  local arch_tag=$1
  local port=$2
  local password=$3
  local version=$4

  TEMP_DIR=$(mktemp -d)
  chmod 700 "$TEMP_DIR"
  cd "$TEMP_DIR"

  log_info "解析 release 信息..."
  {
    read -r download_url
    read -r expected_digest
    read -r asset_name
  } < <(fetch_release_info "$arch_tag")

  log_info "下载: $download_url"
  curl -sSL --connect-timeout 15 --max-time 120 -o anytls.zip "$download_url" || log_error "下载失败"
  verify_digest anytls.zip "$expected_digest"
  unzip -o -q anytls.zip || log_error "解压失败"
  [ ! -f "$BINARY_NAME" ] && log_error "解压后未找到 $BINARY_NAME"

  log_info "安装二进制: $INSTALL_PREFIX/$BINARY_NAME"
  install -m 755 "$BINARY_NAME" "$INSTALL_PREFIX/$BINARY_NAME"

  id "$SERVICE_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin -d /dev/null "$SERVICE_USER"
  mkdir -p "$CONFIG_DIR"
  port=$(printf '%s' "$port" | tr -d '\n\r')
  password=$(printf '%s' "$password" | tr -d '\n\r')
  printf 'PORT=%s\nPASSWORD=%s\n' "$port" "$password" > "$CONFIG_FILE"
  chown root:"$SERVICE_USER" "$CONFIG_DIR" "$CONFIG_FILE"
  chmod 0750 "$CONFIG_DIR"
  chmod 0640 "$CONFIG_FILE"

  local wrapper="${CONFIG_DIR}/run-server.sh"
  cat > "$wrapper" <<'WRAP'
#!/bin/sh
exec 2>&1

ENV_FILE=/etc/anytls/anytls.env

if [ ! -r "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE not readable" >&2
  exit 1
fi

PORT=''
PASSWORD=''
while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | tr -d '\r')
  case "$line" in
    ''|\#*) continue ;;
  esac
  key="${line%%=*}"
  value="${line#*=}"
  [ "$key" = "$line" ] && continue
  case "$key" in
    PORT) PORT="$value" ;;
    PASSWORD) PASSWORD="$value" ;;
  esac
done < "$ENV_FILE"

if [ -z "$PORT" ] || [ -z "$PASSWORD" ]; then
  echo "FATAL: missing PORT or PASSWORD in $ENV_FILE" >&2
  exit 1
fi

exec /usr/local/bin/anytls-server -l "0.0.0.0:${PORT}" -p "${PASSWORD}"
WRAP
  chmod 750 "$wrapper"
  chown root:"$SERVICE_USER" "$wrapper"

  log_info "安装 systemd 服务: $SERVICE_NAME"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=AnyTLS-Go Server (https://github.com/anytls/anytls-go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$wrapper
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$CONFIG_DIR
ProtectHome=yes
PrivateDevices=yes
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  local status='activating'
  local i
  for i in $(seq 1 15); do
    status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
    case "$status" in
      active) break ;;
      failed|inactive) break ;;
      activating) sleep 1 ;;
      *) sleep 1 ;;
    esac
  done
  if [ "$status" != "active" ]; then
    log_error "服务未成功启动 (状态: $status)。请检查: journalctl -u $SERVICE_NAME -n 80 --no-pager"
  fi

  log_info "安装完成 (版本: $version)"
  printf '\n\033[1;32m✅ AnyTLS 服务已就绪\033[0m\n'
  printf '  监听端口: %s\n' "$port"
  printf '  连接密码: 已写入 %s（仅 root 可读）\n' "$CONFIG_FILE"
  printf '  服务状态: %s\n' "$status"
  printf '  管理: systemctl start|stop|restart %s   journalctl -u %s -f\n' "$SERVICE_NAME" "$SERVICE_NAME"
  if command -v curl &>/dev/null; then
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [ -n "$ip" ] && printf '  建议客户端连接: anytls://<密码>@%s:%s\n' "$ip" "$port"
  fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  install_deps

  ARCH_TAG=$(detect_arch)
  log_info "架构: $ARCH_TAG"

  PORT=$(prompt_port)
  PASSWORD=$(prompt_password)
  log_info "端口: $PORT；密码已设置（不输出到终端）"

  # 从 API 取版本号用于展示（仅用于输出）
  VERSION=$(curl -sL --max-time 15 "$REPO_API" | sed -n 's/.*"tag_name": "v\?\([^"]*\)".*/\1/p' | head -n1)
  VERSION=${VERSION:-unknown}

  install_binary_and_service "$ARCH_TAG" "$PORT" "$PASSWORD" "$VERSION"
}

main "$@"
