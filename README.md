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

   
5. （如果使用nftables，直接略过步骤5转至步骤6）systemd服务文件管理chnroute载入和iptables
   
 - 使脚本可执行

       chmod +x chnroute.load.sh
        
 - 创建 systemd 服务文件

    nano /etc/systemd/system/chnroute-load.service  

    在文件中添加以下内容：
   
       [Unit]  
       Description=Load chnroute ipset rules  
       After=network.target  
       [Service]  
       Type=oneshot  
       ExecStart=/root/smart-tproxy/chnroute.load.sh  
       RemainAfterExit=yes  
       [Install]  
       WantedBy=multi-user.target  

 - 启用服务，使其在开机时自动启动
   
       systemctl enable chnroute-load.service
   
 - 启动服务（或者重启系统）
    
       systemctl start chnroute-load.service


6. 使用nftables替代旧系统的iptables（可选，新系统更推荐）
    
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

        
## 控制面板

 - 访问地址

       http://IP:28002

 - 后端地址：

       http://IP:28001

 - 后端密码：

       smart-tproxy
