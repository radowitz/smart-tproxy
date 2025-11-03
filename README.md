## smart-tproxy

在 Debian 上使用 Docker 快速部署一个 TPROXY 透明代理
 - 基于 chnroute 进行国内外 IP 分流
 - 基于 smartdns 进行国内外 DNS 分流
 - 基于 Clash-Meta 的 sniff 嗅探功能进行策略组分流（RULESET+GEOSITE+GEOIP）
 - 使用 iptables 实现透明代理（兼容性更好）

## 快速开始（推荐）

使用一键管理脚本：

```bash
chmod +x manage.sh
./manage.sh
```

选择选项 1 进行完整安装，脚本会自动完成所有配置。

---

## 手动安装步骤

1. 开启内核转发和BBR CAKE，安装必要软件

       chmod +x init.sh
       ./init.sh


2. 修改 `/smartdns/smartdns.conf` 中的SOCKS5代理服务器及海外DNS（NextDNS+AdGuard DNS）的相关配置


3. 修改 `/meta/config.yaml`，基本只需修改各订阅链接，以及如果需要关闭境外quic就取消注释规则内两条`AND`规则


4. docker compose启动所有服务

       docker compose up -d


5. 使用 iptables 配置路由

 - systemd 服务

       nano /etc/systemd/system/clash-tproxy.service

    在文件中添加以下内容：

       [Unit]
       Description=Clash Transparent Proxy with iptables
       After=network-online.target docker.service
       Requires=docker.service
       Wants=network-online.target

       [Service]
       Type=oneshot
       RemainAfterExit=yes
       # 等待 Docker 完全启动（增加延迟以确保容器就绪）
       ExecStartPre=/bin/sleep 5
       ExecStart=/root/smart-tproxy/tproxy-iptables.sh
       ExecStop=/root/smart-tproxy/cleanup-iptables.sh
       StandardOutput=journal
       StandardError=journal
       # 启动失败时自动重试
       Restart=on-failure
       RestartSec=10s

       [Install]
       WantedBy=multi-user.target

 - 内核模块自动加载

       nano /etc/modules-load.d/clash-tproxy.conf

    在文件中添加以下内容：

       xt_TPROXY
       xt_socket
       xt_mark
       ip_set
       ip_set_hash_net

 - 赋予执行权限

       chmod +x /root/smart-tproxy/tproxy-iptables.sh
       chmod +x /root/smart-tproxy/cleanup-iptables.sh

 - 重载 systemd

       systemctl daemon-reload

 - 启用并启动服务

       systemctl enable clash-tproxy.service
       systemctl start clash-tproxy.service

 - 查看状态

       systemctl status clash-tproxy.service

 - 查看日志

       journalctl -u clash-tproxy.service -f

 - 检查 iptables 规则

       iptables -t mangle -L clash -n -v
       iptables -t nat -L POSTROUTING -n -v

 - 检查 ipset

       ipset list chnroute | head -20

 - 检查路由规则

       ip rule show
       ip route show table 100

 - 测试日志

       journalctl -u clash-tproxy.service --no-pager


6. 自动更新规则

 - systemd 服务

       nano /etc/systemd/system/update-all-rules.service

    在文件中添加以下内容：

       [Unit]
       Description=Update all rules (chnroute ipset) from remote source
       After=network-online.target
       Wants=network-online.target

       [Service]
       Type=oneshot
       ExecStart=/root/smart-tproxy/update-all-rules.sh
       StandardOutput=journal
       StandardError=journal

 - systemd 定时器

       nano /etc/systemd/system/update-all-rules.timer

    在文件中添加以下内容：

       [Unit]
       Description=Update all rules daily

       [Timer]
       # 每天凌晨 3 点执行
       OnCalendar=daily
       OnCalendar=03:00
       # 开机后 5 分钟执行一次
       OnBootSec=5min
       # 如果错过执行时间，立即执行
       Persistent=true
       # 随机延迟 0-30 分钟，避免集中访问
       RandomizedDelaySec=30min

       [Install]
       WantedBy=timers.target

 - 日志轮转配置

       nano /etc/logrotate.d/update-all-rules

    在文件中添加以下内容:

       /var/log/rules-update.log {
           daily
           missingok
           rotate 30
           compress
           delaycompress
           notifempty
           create 0640 root root
       }

 - 赋予执行权限

       chmod +x /root/smart-tproxy/update-all-rules.sh

 - 手动测试执行

       /root/smart-tproxy/update-all-rules.sh

 - 重载 systemd

       systemctl daemon-reload

 - 启用定时器

       systemctl enable update-all-rules.timer
       systemctl start update-all-rules.timer

 - 查看定时器状态

       systemctl status update-all-rules.timer

 - 查看下次执行时间

       systemctl list-timers update-all-rules.timer

 - 手动触发更新

       systemctl start update-all-rules.service

 - 查看更新日志

       journalctl -u update-all-rules.service -f

    或

       tail -f /var/log/rules-update.log

## 控制面板

 - 访问地址

       http://IP:28002

 - 后端地址：

       http://IP:28001

 - 后端密码：

       smart-tproxy

## 局域网设备配置

将局域网设备的网关和 DNS 设置为 Debian 服务器的 IP 地址，即可自动享受透明代理：

 - 网关：192.168.x.x（Debian 服务器 IP）
 - DNS：192.168.x.x（Debian 服务器 IP）

## 管理脚本功能

使用 `./manage.sh` 可以方便地管理所有功能：

1. 完整安装（首次安装，不包含定时更新）
2. 启动所有服务
3. 停止所有服务
4. 重启所有服务
5. 重启 Meta (Clash)
6. 重启 SmartDNS
7. 手动更新 chnroute
8. 手动更新全部规则文件
9. 查看服务状态
10. 查看服务日志
11. 设置定时更新规则
12. 取消定时更新规则
13. 卸载全部服务
