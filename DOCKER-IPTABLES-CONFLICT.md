# Docker 与 iptables 冲突问题说明

## 问题描述

当系统重启后，Docker 会在启动时创建 nftables 规则，这些规则会与我们的 iptables TPROXY 规则冲突，导致透明代理无法正常工作。

## 问题现象

重启后执行 `nft list ruleset` 会看到 Docker 创建的规则：

```
# Warning: table ip nat is managed by iptables-nft, do not touch!
# Warning: table ip filter is managed by iptables-nft, do not touch!
```

这些规则会干扰我们的 iptables 规则。

## 解决方案

### 自动解决（推荐）

脚本已经更新，会自动检测并清理 Docker 的 nftables 规则：

1. **tproxy-iptables.sh 自动清理**
   - 脚本会在启动时检测 Docker 创建的 nftables 规则
   - 如果检测到，会自动执行 `nft flush ruleset` 清空
   - 然后再配置 iptables 规则

2. **systemd 服务依赖**
   - clash-tproxy.service 现在依赖 docker.service
   - 会在 Docker 启动 3 秒后再运行
   - 确保 Docker 完全启动后再配置规则

### 手动解决

如果自动解决不生效，可以手动执行：

```bash
# 1. 清空 nftables 规则
nft flush ruleset

# 2. 重新运行 iptables 脚本
/root/smart-tproxy/tproxy-iptables.sh
```

或者使用管理脚本：

```bash
./manage.sh
# 选择选项 4: 重启所有服务
```

## 为什么会发生这个问题？

1. **Docker 使用 iptables-nft 后端**
   - 新版 Docker 使用 iptables-nft 作为后端
   - iptables-nft 实际上创建的是 nftables 规则
   - 这会与纯 iptables 规则混在一起

2. **规则冲突**
   - Docker 的 NAT 规则会优先于我们的 TPROXY 规则
   - 导致流量被 Docker 的规则处理，而不是我们的透明代理

## 长期解决方案

### 选项 1: 使用 iptables-legacy（推荐）

让 Docker 使用传统的 iptables：

```bash
# 配置 Docker 使用 iptables-legacy
cat > /etc/docker/daemon.json << EOF
{
  "iptables": true,
  "ip6tables": false
}
EOF

# 重启 Docker
systemctl restart docker

# 重新配置透明代理
/root/smart-tproxy/tproxy-iptables.sh
```

### 选项 2: 禁用 Docker 的 iptables 管理

如果不需要 Docker 的网络隔离：

```bash
# 配置 Docker 不管理 iptables
cat > /etc/docker/daemon.json << EOF
{
  "iptables": false
}
EOF

# 重启 Docker
systemctl restart docker

# 注意：这会让 Docker 容器无法自动配置端口转发
```

### 选项 3: 完全切换到 nftables

修改项目使用 nftables：

```bash
# 使用 nftables 版本的脚本
/root/smart-tproxy/tproxy-nft.sh
```

> **注意**：nftables 版本目前存在兼容性问题，暂不推荐使用。

## 验证修复

执行以下命令验证规则是否正确：

```bash
# 1. 检查 iptables 规则
iptables -t mangle -L clash -n -v

# 2. 检查路由规则
ip rule show | grep "fwmark 1"

# 3. 测试连通性
curl -I https://google.com
```

## 相关文件

- `tproxy-iptables.sh` - 已添加自动清理 nftables 的功能
- `manage.sh` - 管理脚本，选项 4 可重启所有服务
- `/etc/systemd/system/clash-tproxy.service` - systemd 服务配置

## 更新日志

- **2025-11-03**: 添加自动检测和清理 Docker nftables 规则的功能
- **2025-11-03**: 更新 systemd 服务配置，添加 Docker 依赖和启动延迟
