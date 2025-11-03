#!/bin/bash

# 错误处理
set -e

# 检查并加载必要的内核模块
echo "加载必要的内核模块..."
modprobe -q xt_TPROXY 2>/dev/null || true
modprobe -q xt_socket 2>/dev/null || true
modprobe -q xt_mark 2>/dev/null || true
modprobe -q nf_tproxy_ipv4 2>/dev/null || true

# 确保使用 iptables-legacy (很多新系统默认使用 nftables)
if command -v iptables-legacy &> /dev/null; then
    echo "检测到 nftables，切换到 iptables-legacy..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
fi

# 恢复 ipset
echo "恢复 ipset 规则..."
if [ -f /root/smart-tproxy/chnroute.ipset ]; then
    # 彻底销毁旧的 ipset（强制销毁，忽略错误）
    ipset destroy chnroute -exist 2>/dev/null || true
    ipset destroy chnroute 2>/dev/null || true
    # 等待一下确保完全销毁
    sleep 0.2
    # 加载新的 ipset
    ipset restore -exist -f /root/smart-tproxy/chnroute.ipset 2>/dev/null
else
    echo "警告: chnroute.ipset 文件不存在"
fi

# 配置路由规则
echo "配置路由规则..."
ip rule del fwmark 1 table 100 2>/dev/null || true
ip rule add fwmark 1 table 100

ip route flush table 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100

# 清理旧规则
echo "清理旧规则..."
iptables -t mangle -D PREROUTING -j clash 2>/dev/null || true
iptables -t mangle -F clash 2>/dev/null || true
iptables -t mangle -X clash 2>/dev/null || true

# 创建 clash 链
echo "创建 iptables 规则..."
iptables -t mangle -N clash

# 跳过私有地址
iptables -t mangle -A clash -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A clash -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A clash -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A clash -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A clash -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A clash -d 240.0.0.0/4 -j RETURN

# 跳过国内 IP
if ipset list chnroute &>/dev/null; then
    iptables -t mangle -A clash -m set --match-set chnroute dst -j RETURN
fi

# TPROXY 规则
iptables -t mangle -A clash -p udp -j TPROXY --on-port 7893 --tproxy-mark 1
iptables -t mangle -A clash -p tcp -j TPROXY --on-port 7893 --tproxy-mark 1

# 应用规则
iptables -t mangle -A PREROUTING -j clash

# Debian 本机发出的流量也走 Clash
iptables -t mangle -A OUTPUT -p tcp -j clash
iptables -t mangle -A OUTPUT -p udp -j clash

# NAT 规则 (自动检测网卡)
ETH_DEVICE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$ETH_DEVICE" ]; then
    ETH_DEVICE="eth0"
fi

echo "使用网卡: $ETH_DEVICE"
iptables -t nat -C POSTROUTING -o $ETH_DEVICE -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o $ETH_DEVICE -j MASQUERADE

echo "透明代理规则配置完成"
