#!/bin/bash

set -e

# 配置路径
SMARTDNS_DIR="/root/smart-tproxy/smartdns"
CLASH_META_DIR="/root/smart-tproxy/meta"
CHNROUTE_DIR="/root/smart-tproxy"
BACKUP_DIR="${CHNROUTE_DIR}/backups"
LOG_FILE="/var/log/rules-update.log"

# CDN 镜像 URL（使用 hub.gitmirror.com）
CDN_MIRROR="https://hub.gitmirror.com/https://github.com"

# 下载源配置
declare -A DOWNLOADS=(
    # GeoIP/GeoSite for Clash Meta
    ["${CLASH_META_DIR}/GeoIP.dat"]="${CDN_MIRROR}/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    ["${CLASH_META_DIR}/GeoSite.dat"]="${CDN_MIRROR}/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

    # SmartDNS 规则列表
    ["${SMARTDNS_DIR}/apple.txt"]="${CDN_MIRROR}/Loyalsoldier/v2ray-rules-dat/releases/download/202501012212/apple-cn.txt"
    ["${SMARTDNS_DIR}/cn.txt"]="${CDN_MIRROR}/Loyalsoldier/v2ray-rules-dat/releases/download/202501012212/direct-list.txt"
    ["${SMARTDNS_DIR}/reject.txt"]="${CDN_MIRROR}/Loyalsoldier/v2ray-rules-dat/releases/download/202501012212/reject-list.txt"
    ["${SMARTDNS_DIR}/gfw.txt"]="${CDN_MIRROR}/Loyalsoldier/v2ray-rules-dat/releases/download/202501012212/gfw.txt"

    # chnroute ipset
    ["${CHNROUTE_DIR}/chnroute.ipset"]="${CDN_MIRROR}/soffchen/GeoIP2-CN/raw/release/chnroute.ipset"
)

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# 创建必要目录
create_directories() {
    mkdir -p "$SMARTDNS_DIR"
    mkdir -p "$CLASH_META_DIR"
    mkdir -p "$CHNROUTE_DIR"
    mkdir -p "$BACKUP_DIR"
}

# 下载单个文件
download_file() {
    local target_file="$1"
    local url="$2"
    local temp_file="${target_file}.tmp"

    log "下载: $(basename "$target_file")..." >&2

    if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$temp_file"; then
        if [ -s "$temp_file" ]; then
            local size=$(du -h "$temp_file" | cut -f1)
            log "  成功，大小: $size" >&2
            echo "$temp_file"
            return 0
        else
            log_error "  文件为空" >&2
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "  下载失败: $url" >&2
        rm -f "$temp_file"
        return 1
    fi
}

# 检查文件是否有变化
has_changes() {
    local new_file="$1"
    local old_file="$2"

    if [ ! -f "$old_file" ]; then
        return 0  # 文件不存在，需要更新
    fi

    # 比较 MD5
    local old_hash=$(md5sum "$old_file" | cut -d' ' -f1)
    local new_hash=$(md5sum "$new_file" | cut -d' ' -f1)

    if [ "$old_hash" != "$new_hash" ]; then
        return 0  # 有变化
    else
        return 1  # 无变化
    fi
}

# 备份文件
backup_file() {
    local file="$1"

    if [ -f "$file" ]; then
        local filename=$(basename "$file")
        local backup_file="${BACKUP_DIR}/${filename}.$(date +%Y%m%d-%H%M%S)"
        cp "$file" "$backup_file"
        log "  已备份: $filename"
    fi
}

# 更新所有文件
update_files() {
    local updated_files=()
    local failed_files=()

    for target_file in "${!DOWNLOADS[@]}"; do
        local url="${DOWNLOADS[$target_file]}"
        local filename=$(basename "$target_file")

        # 下载文件
        local temp_file
        temp_file=$(download_file "$target_file" "$url")
        if [ $? -eq 0 ] && [ -n "$temp_file" ]; then
            # 检查是否有变化
            if has_changes "$temp_file" "$target_file"; then
                # 备份旧文件
                backup_file "$target_file"

                # 替换文件
                mv "$temp_file" "$target_file"
                log "  已更新: $filename"
                updated_files+=("$filename")
            else
                log "  无变化: $filename"
                rm -f "$temp_file"
            fi
        else
            failed_files+=("$filename")
        fi
    done

    # 返回更新状态
    if [ ${#updated_files[@]} -gt 0 ]; then
        log "已更新 ${#updated_files[@]} 个文件: ${updated_files[*]}"
        return 0
    elif [ ${#failed_files[@]} -gt 0 ]; then
        log_error "有 ${#failed_files[@]} 个文件下载失败: ${failed_files[*]}"
        return 1
    else
        log "所有文件均为最新版本"
        return 2
    fi
}

# 重新加载 chnroute ipset
reload_ipset() {
    local ipset_file="${CHNROUTE_DIR}/chnroute.ipset"

    if [ ! -f "$ipset_file" ]; then
        log "chnroute.ipset 不存在，跳过"
        return 0
    fi

    log "重新加载 ipset..."

    # 销毁旧的 ipset
    ipset destroy chnroute -exist 2>/dev/null || true
    ipset destroy chnroute 2>/dev/null || true
    sleep 0.2

    # 加载新的 ipset
    if ipset restore -exist -f "$ipset_file" 2>&1 | grep -v "already exists" | tee -a "$LOG_FILE"; then
        if ipset list chnroute &>/dev/null; then
            local count=$(ipset list chnroute 2>/dev/null | grep -c "^[0-9]" || echo 0)
            log "ipset 加载成功: $count 条规则"
            return 0
        fi
    fi

    log_error "ipset 加载失败"
    return 1
}

# 重新加载 nftables
reload_nftables() {
    if ! command -v nft &>/dev/null; then
        return 0
    fi

    if ! nft list table inet clash &>/dev/null; then
        return 0
    fi

    log "同步到 nftables..."

    nft flush set inet clash chnroute 2>/dev/null || true

    local temp_file=$(mktemp)
    ipset list chnroute | grep -E "^[0-9]" | \
        awk '{print "add element inet clash chnroute { " $1 " }"}' > "$temp_file"

    if [ -s "$temp_file" ]; then
        if nft -f "$temp_file" 2>&1 | grep -v "already exists" | tee -a "$LOG_FILE"; then
            local count=$(wc -l < "$temp_file")
            log "nftables 同步成功: $count 条规则"
        fi
    fi

    rm -f "$temp_file"
}

# 重启 Docker 容器
restart_docker_containers() {
    local updated=$1
    local containers_reloaded=()

    if [ $updated -eq 0 ]; then
        # 查找并重启 clash-meta 容器（精确匹配）
        local meta_container=$(docker ps --filter "name=^clash-meta$" --format "{{.Names}}")
        if [ -n "$meta_container" ]; then
            log "重启 Docker 容器: $meta_container..."
            if docker restart "$meta_container" &>/dev/null; then
                containers_reloaded+=("$meta_container")
            else
                log_error "$meta_container 重启失败"
            fi
        fi

        # 查找并热重载 smartdns 容器（精确匹配）
        local smartdns_container=$(docker ps --filter "name=^smartdns$" --format "{{.Names}}")
        if [ -n "$smartdns_container" ]; then
            log "热重载 SmartDNS 配置: $smartdns_container..."
            # 尝试发送 HUP 信号热重载，失败则重启
            if docker exec "$smartdns_container" killall -HUP smartdns &>/dev/null; then
                containers_reloaded+=("$smartdns_container (热重载)")
            elif docker restart "$smartdns_container" &>/dev/null; then
                containers_reloaded+=("$smartdns_container (重启)")
            else
                log_error "$smartdns_container 重载失败"
            fi
        fi

        if [ ${#containers_reloaded[@]} -gt 0 ]; then
            log "已处理容器: ${containers_reloaded[*]}"
        else
            log "未找到需要处理的 Docker 容器"
        fi
    fi
}

# 清理旧备份
cleanup_backups() {
    log "清理 7 天前的备份..."
    find "$BACKUP_DIR" -type f -mtime +7 -delete 2>/dev/null || true
}

# 发送通知
send_notification() {
    local message="$1"
    logger -t rules-update "$message"
}

# 主函数
main() {
    log "========== 开始更新规则文件 =========="

    # 创建目录
    create_directories

    # 更新文件
    update_files
    local update_status=$?

    # 重新加载 ipset/nftables
    if [ $update_status -eq 0 ]; then
        reload_ipset
        reload_nftables
    fi

    # 重启 Docker 容器
    restart_docker_containers $update_status

    # 清理旧备份
    cleanup_backups

    # 发送通知
    case $update_status in
        0)
            send_notification "规则文件更新成功"
            log "========== 更新完成 =========="
            ;;
        1)
            send_notification "规则文件更新失败"
            log_error "========== 更新失败 =========="
            exit 1
            ;;
        2)
            log "========== 无需更新 =========="
            ;;
    esac
}

main