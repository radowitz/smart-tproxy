#!/bin/bash

# 检查启动状态的诊断脚本

echo "=========================================="
echo "检查 Smart-TPROXY 启动状态"
echo "=========================================="
echo ""

# 1. 检查 systemd 服务状态
echo "1. clash-tproxy 服务状态："
systemctl status clash-tproxy.service --no-pager
echo ""

# 2. 检查服务是否已启用
echo "2. 服务启用状态："
systemctl is-enabled clash-tproxy.service
echo ""

# 3. 查看服务日志
echo "3. 服务日志（最后 30 行）："
journalctl -u clash-tproxy.service -n 30 --no-pager
echo ""

# 4. 检查 iptables 规则
echo "4. iptables TPROXY 规则："
iptables -t mangle -L clash -n 2>/dev/null || echo "clash 链不存在"
echo ""

# 5. 检查路由规则
echo "5. 路由规则："
ip rule show | grep "fwmark 1" || echo "路由规则不存在"
echo ""

# 6. 检查 ipset
echo "6. ipset 状态："
ipset list chnroute 2>/dev/null | head -5 || echo "chnroute 不存在"
echo ""

# 7. 检查 Docker 容器
echo "7. Docker 容器状态："
docker ps --filter "name=clash-meta" --format "table {{.Names}}\t{{.Status}}"
echo ""

# 8. 检查 Clash 端口
echo "8. Clash 监听端口："
ss -tlnp | grep 7893 || echo "端口 7893 未监听"
echo ""

# 9. 检查 nftables（可能的冲突）
echo "9. nftables 规则检查："
if command -v nft &>/dev/null; then
    if nft list ruleset 2>/dev/null | grep -q "managed by iptables-nft"; then
        echo "⚠️  警告：检测到 Docker 的 nftables 规则，可能导致冲突"
    else
        echo "✓ 正常：没有 nftables 冲突"
    fi
else
    echo "nft 命令不存在"
fi
echo ""

echo "=========================================="
echo "诊断完成"
echo "=========================================="
