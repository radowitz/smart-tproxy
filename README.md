# smart-tproxy

在 Debian 上使用 Docker 快速部署一个 TPROXY 透明代理
 - 基于 chnroute 进行国内外 IP 分流
 - 基于 smartdns 进行国内外 DNS 分流
 - 基于 Clash-Meta 的 sniff 嗅探功能进行策略组分流（RULESET+GEOSITE+GEOIP）

### 安装步骤

1. 开启内核转发和BBR CAKE，替换国内源（北外源）并安装 docker

        chmod +x docker.init.sh
        ./docker.init.sh
   
2. 修改 `/smartdns/smartdns.conf` 中的SOCKS5代理服务器及海外DNS（NextDNS+AdGuard DNS）的相关配置

3. 修改 `/meta/config.yaml`，基本只需修改各订阅链接，以及如果需要关闭境外quic就取消注释规则内两条`AND`规则

4. docker compose启动所有服务

        docker compose up -d
   
5. systemd服务文件管理chnroute载入和iptables
   
    5.1 修改 `chnroute.load.sh` 中最后一条自己的网络接口名

       nano chnroute.load.sh
   比如将 `ens192` 修改为 `eth0` ，可通过 `ip -a` 查看接口名

    5.2 使脚本可执行

        chmod +x chnroute.load.sh
        
    5.3 创建 systemd 服务文件

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
  
      保存并退出编辑器

    5.4 启用服务，使其在开机时自动启动
   
        systemctl enable chnroute-load.service
   
    5.5 启动服务（或者重启系统）
    
        systemctl start chnroute-load.service


   

### 控制面板

   访问地址

        http://IP:28002

   后端地址：

        http://IP:28001

   后端密码：

        smart-tproxy

