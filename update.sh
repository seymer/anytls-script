#!/usr/bin/env bash
#
# AnyTLS-Go 服务端更新脚本（仅升级二进制，保留配置）
# 配置唯一来源: /etc/anytls/anytls.env，不解析 systemd
#

set -e
set -o pipefail

readonly REPO_API='https://api.github.com/repos/anytls/anytls-go/releases/latest'
readonly BINARY_NAME='anytls-server'
readonly INSTALL_PREFIX='/usr/local/bin'
readonly CONFIG_FILE='/etc/anytls/anytls.env'
readonly SERVICE_NAME='anytls'

log_info() { printf '\033[32m[INFO]\033[0m %s\n' "$1"; }
log_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$1"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

cleanup() {
  [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

require_root() {
  [ "$(id -u)" -eq 0 ] || log_error "请使用 root 运行（如 sudo $0）"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo 'linux_amd64'; ;;
    aarch64|arm64) echo 'linux_arm64'; ;;
    *) log_error "不支持的架构: $(uname -m)"; ;;
  esac
}

fetch_release_info() {
  local arch_tag=$1
  local api_json
  api_json=$(curl -sL --connect-timeout 10 --max-time 30 "$REPO_API") || log_error "无法获取 GitHub API"
  if command -v jq &>/dev/null; then
    echo "$api_json" | jq -r --arg a "$arch_tag" '.assets[] | select(.name | test($a)) | .browser_download_url' | head -n1
    echo "$api_json" | jq -r --arg a "$arch_tag" '.assets[] | select(.name | test($a)) | .digest' | head -n1
  else
    local block
    block=$(echo "$api_json" | grep -A 14 "\"name\": \"anytls_.*_${arch_tag}.zip\"" | head -n 15)
    echo "$block" | grep "browser_download_url" | sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' | head -n1
    echo "$block" | grep '"digest"' | sed -n 's/.*"digest": "\([^"]*\)".*/\1/p' | head -n1
  fi
}

verify_digest() {
  local file=$1 expected=$2
  [ -z "$expected" ] && return 0
  [ ! -f "$file" ] && return 1
  local hash="${expected#*:}"
  local actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    return 0
  fi
  [ "$actual" = "$hash" ] || log_error "校验失败: 期望 $hash，得到 $actual"
}

main() {
  require_root
  [ -f "$INSTALL_PREFIX/$BINARY_NAME" ] || log_error "未检测到已安装的 $BINARY_NAME，请先执行 install.sh"
  [ -f "$CONFIG_FILE" ] || log_error "未找到配置 $CONFIG_FILE"

  # 配置唯一来源：解析 env 文件（不 source，避免特殊字符导致解析失败）
  PORT=$(sed -n 's/^PORT=//p' "$CONFIG_FILE" | head -n1)
  PASSWORD=$(sed -n 's/^PASSWORD=//p' "$CONFIG_FILE" | head -n1)
  [ -n "${PORT:-}" ] && [ -n "${PASSWORD:-}" ] || log_error "CONFIG_FILE 中缺少 PORT 或 PASSWORD"

  ARCH_TAG=$(detect_arch)
  log_info "架构: $ARCH_TAG"

  {
    read -r download_url
    read -r expected_digest
  } < <(fetch_release_info "$ARCH_TAG")
  [ -z "$download_url" ] && log_error "未找到适配 $ARCH_TAG 的 release"

  VERSION=$(curl -sL --max-time 15 "$REPO_API" | sed -n 's/.*"tag_name": "v\?\([^"]*\)".*/\1/p' | head -n1)
  log_info "停止服务并下载 v${VERSION:-unknown}..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  curl -sSL --connect-timeout 15 --max-time 120 -o anytls.zip "$download_url" || log_error "下载失败"
  verify_digest anytls.zip "$expected_digest"
  unzip -o -q anytls.zip
  [ ! -f "$BINARY_NAME" ] && log_error "解压后未找到 $BINARY_NAME"
  install -m 755 "$BINARY_NAME" "$INSTALL_PREFIX/$BINARY_NAME"

  systemctl start "$SERVICE_NAME"
  status='activating'
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
    log_error "服务未成功启动 (状态: $status)。请检查: journalctl -u $SERVICE_NAME -n 50"
  fi

  printf '\n\033[1;32m✅ 更新完成\033[0m\n'
  printf '  版本: v%s  状态: %s  端口: %s\n' "${VERSION:-unknown}" "$status" "${PORT:-}"
}

main "$@"
