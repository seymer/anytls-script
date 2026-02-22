# AnyTLS-Go 服务端安装脚本（重写版）

基于**第一性原理**与**最佳实践**重写的安装/卸载/更新脚本，与 [anytls/anytls-go](https://github.com/anytls/anytls-go) 配套使用。

## 设计原则

| 原则 | 说明 |
|------|------|
| **单一职责** | `install.sh` 只做安装；`uninstall.sh` 只做卸载；`update.sh` 只做二进制升级并保留配置。 |
| **配置唯一来源** | 端口与密码仅存在于 `/etc/anytls/anytls.env`，systemd 通过 `EnvironmentFile` 读取，脚本不解析 `ExecStart`。 |
| **安全** | 不在终端或日志中输出密码；使用 GitHub Release 的 `digest` 校验下载（可选，依赖 `sha256sum`/`shasum`）。 |
| **可移植** | 仅用 Bash + POSIX 常用命令；解析 API 时优先 `jq`，无 `jq` 时用 `grep`/`sed` 回退；不使用 `grep -P`。 |
| **最小影响** | 不修改系统级网络配置（如 gai.conf、iptables），仅安装二进制、配置与 systemd 单元。 |

## 文件说明

- **install.sh** — 安装：安装依赖 → 下载并校验 → 安装二进制、创建用户、写入配置与 systemd → 启动。
- **uninstall.sh** — 卸载：确认后停止服务、删除单元、二进制、`/etc/anytls`、用户。
- **update.sh** — 更新：从 `/etc/anytls/anytls.env` 读取配置，下载最新 release、校验、替换二进制并重启服务。

## 依赖

- **必需**：`curl`、`unzip`（脚本会尝试用系统包管理器安装）。
- **推荐**：`jq`（用于可靠解析 GitHub API；无则回退到 grep/sed）。
- **校验**：`sha256sum` 或 `shasum`（无则跳过下载校验）。

## 用法

```bash
# 安装（交互输入端口与密码，或随机生成）
sudo ./install.sh

# 安装并指定端口与密码
sudo ./install.sh --port 8443 --password 'your-secret'

# 更新（保留当前配置）
sudo ./update.sh

# 卸载
sudo ./uninstall.sh
```

## 安装结果

- 二进制：`/usr/local/bin/anytls-server`
- 配置：`/etc/anytls/anytls.env`（`PORT=`、`PASSWORD=`，权限 0640，仅 root 可读）
- 服务：`systemctl start|stop|restart anytls`，`journalctl -u anytls -f`
- 运行用户：`anytls`（nologin，最小权限）

## 支持的系统

- 架构：`linux_amd64`、`linux_arm64`
- 包管理器：apt（Debian/Ubuntu）、dnf/yum（RHEL/CentOS/Rocky/Alma）、apk（Alpine）

## 与旧版脚本的差异

- 不做 IP 优先级（gai.conf/iptables），仅安装并启动服务。
- 支持 `--port` / `--password` 非交互安装。
- 使用 GitHub Release 的 digest 做下载完整性校验（在工具可用时）。
- 更新时以 `/etc/anytls/anytls.env` 为唯一配置来源，不解析 systemd 单元。
