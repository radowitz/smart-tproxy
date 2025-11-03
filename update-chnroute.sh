#!/bin/bash

set -e

REMOTE_URL="https://cdn.jsdelivr.net/gh/soffchen/GeoIP2-CN@release/chnroute.ipset"
LOCAL_FILE="/root/smartmeta/chnroute.ipset"
BACKUP_DIR="/root/smartmeta/backups"
LOG_FILE="/var/log/chnroute-update.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# 创建必要目录
mkdir -p "$(dirname "$LOCAL_FILE")"
mkdir -p "$BACKUP_DIR"

# 下载新文件
download_chnroute() {
    local temp_file="${LOCAL_FILE}.tmp"
    
    log "开始下载 chnroute.ipset..." >&2
    
    if curl -fsSL --connect-timeout 10 --max-time 60 "$REMOTE_URL" -o "$temp_file"; then
        # 验证文件是否有效
        if [ -s "$temp_file" ]; then
            # 检查文件格式
            local first_line=$(head -n 1 "$temp_file")
            if [[ "$first_line" =~ ^create[[:space:]]+chnroute ]] || [[ "$first_line" =~ ^add[[:space:]]+chnroute ]]; then
                log "下载成功，文件大小: $(du -h "$temp_file" | cut -f1)" >&2
                echo "$temp_file"
                return 0
            else
                log_error "下载的文件格式不正确" >&2
                rm -f "$temp_file"
                return 1
            fi
        else
            log_error "下载的文件为空" >&2
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "下载失败" >&2
        rm -f "$temp_file"
        return 1
    fi
}

# 比较文件是否有变化
has_changes() {
    local new_file="$1"
    
    if [ ! -f "$LOCAL_FILE" ]; then
        log "本地文件不存在，需要更新"
        return 0
    fi
    
    # 比较文件内容（忽略注释和空行）
    local old_hash=$(grep -v "^#" "$LOCAL_FILE" 2>/dev/null | grep -v "^$" | md5sum | cut -d' ' -f1)
    local new_hash=$(grep -v "^#" "$new_file" 2>/dev/null | grep -v "^$" | md5sum | cut -d' ' -f1)
    
    if [ "$old_hash" != "$new_hash" ]; then
        log "检测到文件变化"
        return 0
    else
        log "文件内容无变化，跳过更新"
        return 1
    fi
}

# 备份旧文件
backup_old_file() {
    if [ -f "$LOCAL_FILE" ]; then
        local backup_file="${BACKUP_DIR}/chnroute.ipset.$(date +%Y%m%d-%H%M%S)"
        cp "$LOCAL_FILE" "$backup_file"
        log "已备份旧文件到: $backup_file"
        
        # 只保留最近 7 天的备份
        find "$BACKUP_DIR" -name "chnroute.ipset.*" -mtime +7 -delete 2>/dev/null || true
    fi
}

# 重新加载 ipset
reload_ipset() {
    log "重新加载 ipset..."
    
    # 检查文件是否存在
    if [ ! -f "$LOCAL_FILE" ]; then
        log_error "文件不存在: $LOCAL_FILE"
        return 1
    fi
    
    # 彻底销毁旧的 ipset（强制销毁，忽略错误）
    ipset destroy chnroute -exist 2>/dev/null || true
    ipset destroy chnroute 2>/dev/null || true
    
    # 等待一下确保完全销毁
    sleep 0.2
    
    # 加载新的 ipset
    if ipset restore -exist -f "$LOCAL_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        # 验证加载结果
        if ipset list chnroute &>/dev/null; then
            local count=$(ipset list chnroute 2>/dev/null | grep -c "^[0-9]" || echo 0)
            log "ipset 加载成功: $count 条规则"
            return 0
        fi
    fi
    
    log_error "ipset 加载失败"
    return 1
}

# 重新加载 nftables（如果使用）
reload_nftables() {
    if ! command -v nft &>/dev/null; then
        return 0
    fi
    
    if ! nft list table inet clash &>/dev/null; then
        return 0
    fi
    
    log "同步到 nftables..."
    
    # 清空 nftables set
    nft flush set inet clash chnroute 2>/dev/null || true
    
    # 批量添加
    local temp_file=$(mktemp)
    ipset list chnroute | grep -E "^[0-9]" | \
        awk '{print "add element inet clash chnroute { " $1 " }"}' > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        if nft -f "$temp_file" 2>&1 | tee -a "$LOG_FILE"; then
            local count=$(wc -l < "$temp_file")
            log "nftables 同步成功: $count 条规则"
        else
            log_error "nftables 同步失败"
        fi
    fi
    
    rm -f "$temp_file"
}

# 发送通知
send_notification() {
    local message="$1"
    logger -t chnroute-update "$message"
}

# 主函数
main() {
    log "========== 开始更新 chnroute.ipset =========="
    
    # 下载新文件
    local new_file
    new_file=$(download_chnroute)
    if [ $? -ne 0 ] || [ -z "$new_file" ]; then
        log_error "更新失败：下载出错"
        exit 1
    fi
    
    # 检查是否有变化
    if ! has_changes "$new_file"; then
        rm -f "$new_file"
        log "========== 更新完成（无变化） =========="
        exit 0
    fi
    
    # 备份旧文件
    backup_old_file
    
    # 替换文件
    mv "$new_file" "$LOCAL_FILE"
    log "已更新本地文件: $LOCAL_FILE"
    
    # 重新加载 ipset
    if reload_ipset; then
        reload_nftables
        send_notification "chnroute.ipset 已成功更新"
        log "========== 更新完成 =========="
    else
        log_error "========== 更新失败：ipset 加载出错 =========="
        
        # 恢复备份
        local latest_backup=$(ls -t "$BACKUP_DIR"/chnroute.ipset.* 2>/dev/null | head -n1)
        if [ -n "$latest_backup" ]; then
            log "正在恢复备份..."
            cp "$latest_backup" "$LOCAL_FILE"
            reload_ipset
        fi
        
        exit 1
    fi
}

main
