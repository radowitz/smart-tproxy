#!/bin/bash

# 开启内核转发和 BBR
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system

apt-get update -y
apt-get install -y ipset 

ipset restore < chnroute.ipset

ip rule add fwmark 1 table 100
ip route add local 0.0.0.0/0 dev lo table 100
iptables -t mangle -N clash
iptables -t mangle -A clash -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A clash -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A clash -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A clash -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A clash -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A clash -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A clash -d 240.0.0.0/4 -j RETURN
iptables -t mangle -A clash -m set --match-set chnroute dst -j RETURN
iptables -t mangle -A clash -p udp -j TPROXY --on-port 7893 --tproxy-mark 1
iptables -t mangle -A clash -p tcp -j TPROXY --on-port 7893 --tproxy-mark 1
iptables -t mangle -A PREROUTING -j clash

apt install iptables-persistent -y
netfilter-persistent save

echo "iptables rules have been set up successfully."
