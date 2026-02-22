#!/usr/bin/env bash
#
# AnyTLS-Go 服务端卸载脚本（与 install.sh 配套）
# 单一职责: 停止服务 → 删除单元、二进制、配置、用户
#

set -e

readonly SERVICE_NAME='anytls'
readonly BINARY_PATH='/usr/local/bin/anytls-server'
readonly CONFIG_DIR='/etc/anytls'
readonly SERVICE_USER='anytls'

log_info() { printf '\033[32m[INFO]\033[0m %s\n' "$1"; }
log_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$1"; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || log_error "请使用 root 运行（如 sudo $0）"
}

main() {
  require_root

  read -r -p "确定卸载 AnyTLS 服务？(y/N): " confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) log_info "已取消"; exit 0 ;;
  esac

  if systemctl list-unit-files --type=service | grep -q "^${SERVICE_NAME}.service"; then
    log_info "停止并禁用服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  else
    log_warn "未找到服务单元 ${SERVICE_NAME}.service"
  fi

  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    log_info "删除 systemd 单元..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
  fi

  if [ -f "$BINARY_PATH" ]; then
    log_info "删除二进制: $BINARY_PATH"
    rm -f "$BINARY_PATH"
  fi

  if [ -d "$CONFIG_DIR" ]; then
    log_info "删除配置目录: $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
  fi

  if id "$SERVICE_USER" &>/dev/null; then
    log_info "删除用户: $SERVICE_USER"
    userdel "$SERVICE_USER" 2>/dev/null || true
  fi

  printf '\n\033[1;32m✅ 卸载完成\033[0m\n'
}

main "$@"
