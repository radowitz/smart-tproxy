## smart-tproxy

在 Debian 上使用 Docker 快速部署一个 TPROXY 透明代理
 - 基于 chnroute 进行国内外 IP 分流
 - 基于 smartdns 进行国内外 DNS 分流
 - 基于 Clash-Meta 的 sniff 嗅探功能进行策略组分流（RULESET+GEOSITE+GEOIP）

## 安装步骤

1. 开启内核转发和BBR CAKE，安装必要软件

       chmod +x init.sh
       ./init.sh


2. 修改 `/smartdns/smartdns.conf` 中的SOCKS5代理服务器及海外DNS（NextDNS+AdGuard DNS）的相关配置


3. 修改 `/meta/config.yaml`，基本只需修改各订阅链接，以及如果需要关闭境外quic就取消注释规则内两条`AND`规则


4. docker compose启动所有服务

       docker compose up -d


5. 使用 nftables 配置路由
    
 - systemd 服务 

       nano /etc/systemd/system/clash-tproxy.service

    在文件中添加以下内容：    

       [unit]
       Description=Clash Transparent Proxy with nftables
       After=network-online.target nftables.service
       Wants=network-online.target
       Before=network.target
       [Service]
       Type=oneshot
       RemainAfterExit=yes
       ExecStart=/root/smart-tproxy/tproxy-nft.sh
       ExecStop=/root/smart-tproxy/cleanup-nft.sh
       StandardOutput=journal
       StandardError=journal
       Restart=on-failure
       RestartSec=5s
       [Install]
       WantedBy=multi-user.target

 - 内核模块自动加载 

       nano /etc/modules-load.d/clash-tproxy.conf
        
    在文件中添加以下内容：    

       nf_tables
       nft_tproxy
       nf_tproxy_ipv4
       nft_socket
       ip_set
       ip_set_hash_net

 - 赋予执行权限
   
       chmod +x /root/smart-tproxy/tproxy-nft.sh
       chmod +x /root/smart-tproxy/cleanup-nft.sh

 - 重载 systemd
   
       systemctl daemon-reload

 - 启用并启动服务
   
       systemctl enable clash-tproxy.service
       systemctl start clash-tproxy.service

 - 查看状态
   
       systemctl status clash-tproxy.service

 - 查看日志

       journalctl -u clash-tproxy.service -f

 - 检查 nftables 规则

       nft list ruleset

 - 检查 ipset

       ipset list chnroute | head -20

 - 检查路由规则

       ip rule show
       ip route show table 100

 - 测试日志

       journalctl -u clash-tproxy.service --no-pager


6. 自动更新 chnroute

 - systemd 服务 

       nano /etc/systemd/system/chnroute-update.service

    在文件中添加以下内容：    

       [Unit]
       Description=Update chnroute ipset from remote source
       After=network-online.target
       Wants=network-online.target

       [Service]
       Type=oneshot
       ExecStart=/root/smart-tproxy/update-chnroute.sh
       StandardOutput=journal
       StandardError=journal

 - systemd 定时器 

       nano /etc/systemd/system/chnroute-update.timer

    在文件中添加以下内容：    

       [Unit]
       Description=Update chnroute ipset daily

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

       nano /etc/logrotate.d/chnroute-update

    在文件中添加以下内容：
   
       /var/log/chnroute-update.log {
           daily
           missingok
           rotate 30
           compress
           delaycompress
           notifempty
           create 0640 root root
       }

 - 赋予执行权限

       chmod +x /root/smart-tproxy/update-chnroute.sh

 - 手动测试执行
   
       /root/smart-tproxy/update-chnroute.sh

 - 重载 systemd
   
       systemctl daemon-reload

 - 启用定时器

       systemctl enable chnroute-update.timer
       systemctl start chnroute-update.timer

 - 查看定时器状态
   
       systemctl status chnroute-update.timer

 - 查看下次执行时间
   
       systemctl list-timers chnroute-update.timer

 - 手动触发更新

       systemctl start chnroute-update.service

 - 查看更新日志
   
       journalctl -u chnroute-update.service -f

    或
   
       tail -f /var/log/chnroute-update.log

## 控制面板

 - 访问地址

       http://IP:28002

 - 后端地址：

       http://IP:28001

 - 后端密码：

       smart-tproxy
