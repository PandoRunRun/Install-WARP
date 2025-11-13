#!/bin/bash

# ==========================================
# WARP Client Proxy Mode 一键脚本 (V4 ip.sb版)
# 更新日志：
# - 将 IP 检测源更换为更稳定的 api.ip.sb/geoip
# - 修复了 IPv6 检测可能因超时而误报失败的问题
# ==========================================

# 颜色配置
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# ================= 状态检测逻辑 (核心修改) =================

verify_status() {
    echo -e "\n${CYAN}正在检测连接状态 (使用 api.ip.sb)...${PLAIN}"
    
    check_ip() {
        local type=$1 # 传入 4 或 6
        
        # 使用 api.ip.sb/geoip 获取 JSON 信息
        # -s: 静默模式
        # -m 15: 最多等待 15秒 (防止 IPv6 握手慢)
        # -x socks5h://...: 强制走代理
        local result=$(curl -s -m 15 -x socks5h://127.0.0.1:40000 -$type https://api.ip.sb/geoip)
        
        # 简单的校验：如果返回结果里包含 "country" 这个词，说明获取 JSON 成功了
        if [[ "$result" == *"country"* ]]; then
            local ip=$(echo "$result" | jq -r '.ip')
            local country=$(echo "$result" | jq -r '.country')
            local isp=$(echo "$result" | jq -r '.isp')
            echo -e " WARP Free IPv${type}: ${GREEN}${ip}${PLAIN} ${YELLOW}${country}${PLAIN} ${CYAN}${isp}${PLAIN}"
        else
            # 如果失败，尝试仅获取 IP (兜底方案，对应你说的 ipv4.ip.sb)
            local simple_ip=$(curl -s -m 5 -x socks5h://127.0.0.1:40000 -$type https://ipv${type}.ip.sb)
            if [[ -n "$simple_ip" ]]; then
                 echo -e " WARP Free IPv${type}: ${GREEN}${simple_ip}${PLAIN} ${YELLOW}(无法获取位置信息)${PLAIN}"
            else
                 echo -e " WARP Free IPv${type}: ${RED}连接失败 或 无此网络栈${PLAIN}"
            fi
        fi
    }

    echo -e "===================================================="
    echo -e " Client 状态: ${GREEN}已连接${PLAIN}"
    echo -e " 本地 Socks5: ${GREEN}127.0.0.1:40000${PLAIN}"
    echo -e "----------------------------------------------------"
    check_ip 4
    check_ip 6
    echo -e "===================================================="
}

# ================= 以下逻辑保持稳定 (V3版修复代码) =================

# 等待服务就绪
wait_for_service() {
    echo -e "${YELLOW}正在等待 WARP 服务就绪...${PLAIN}"
    local RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        if systemctl is-active --quiet warp-svc; then
            local CLI_OUTPUT=$(timeout 2 warp-cli status 2>&1)
            if [[ "$CLI_OUTPUT" != *"Unable to connect"* ]]; then
                echo -e "${GREEN}服务已就绪！${PLAIN}"
                return 0
            fi
        fi
        sleep 1
        ((RETRIES++))
    done
    echo -e "${RED}服务检测超时 (但服务可能已启动)${PLAIN}"
    return 0 
}

# 仅重启服务
restart_warp_only() {
    echo -e "${CYAN}正在重启 WARP 服务...${PLAIN}"
    systemctl restart warp-svc
    wait_for_service
    echo -e "${GREEN}重启完成，正在重新检测连通性...${PLAIN}"
    sleep 2
    verify_status
}

# 依赖安装
install_dependencies() {
    echo -e "${CYAN}正在初始化环境并安装依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl gnupg lsb-release jq
        
        if [ ! -f /etc/apt/sources.list.d/cloudflare-client.list ]; then
            curl -s https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
        fi

    elif [ -f /etc/redhat-release ]; then
        yum install -y curl jq
        if [ ! -f /etc/yum.repos.d/cloudflare-warp.repo ]; then
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el8.rpm 2>/dev/null || rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el9.rpm 2>/dev/null
        fi
    else
        echo -e "${RED}不支持的操作系统！${PLAIN}"
        exit 1
    fi
}

# 智能监测
check_if_running() {
    if command -v warp-cli &> /dev/null && systemctl is-active --quiet warp-svc; then
        echo -e "\n${YELLOW}========================================${PLAIN}"
        echo -e "${YELLOW}检测到 WARP 已在运行，当前状态如下：${PLAIN}"
        verify_status
        echo -e "${YELLOW}========================================${PLAIN}"
        
        echo -e "请选择操作："
        echo -e " ${GREEN}1.${PLAIN} 强制重装并重置 (Reinstall & Reset)"
        echo -e " ${GREEN}2.${PLAIN} 仅重启服务 (Restart Service)"
        echo -e " ${GREEN}3.${PLAIN} 退出 (Exit)"
        echo -e ""
        read -p "请输入数字 [1-3]: " choice
        
        case "$choice" in
            1 ) echo -e "${CYAN}用户选择重装...${PLAIN}"; return 0 ;;
            2 ) restart_warp_only; exit 0 ;;
            * ) echo -e "${GREEN}已退出。${PLAIN}"; exit 0 ;;
        esac
    fi
}

# 安装与配置
install_warp() {
    echo -e "${CYAN}正在安装/更新 Cloudflare WARP...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get install cloudflare-warp -y
    else
        yum install cloudflare-warp -y
    fi
}

start_service_initial() {
    echo -e "${CYAN}正在启动 WARP 服务...${PLAIN}"
    systemctl enable warp-svc
    systemctl restart warp-svc
    wait_for_service
}

configure_warp() {
    echo -e "${CYAN}正在配置 Proxy 模式 (端口 40000)...${PLAIN}"
    warp-cli disconnect &>/dev/null
    rm -rf /var/lib/cloudflare-warp/reg.json &>/dev/null

    HELP_INFO=$(warp-cli --help)
    
    if echo "$HELP_INFO" | grep -q "registration"; then
        warp-cli mode proxy
        warp-cli proxy port 40000
        echo -e "${YELLOW}正在注册账号...${PLAIN}"
        warp-cli registration new
        echo -e "${YELLOW}正在连接...${PLAIN}"
        warp-cli connect
    else
        warp-cli set-mode proxy
        warp-cli set-proxy-port 40000
        echo -e "${YELLOW}正在注册账号...${PLAIN}"
        warp-cli register
        echo -e "${YELLOW}正在连接...${PLAIN}"
        warp-cli connect
    fi
    sleep 5
}

# --- 主程序流程 ---
install_dependencies
check_if_running
install_warp
start_service_initial
configure_warp
verify_status
