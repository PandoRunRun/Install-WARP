#!/bin/bash

# ==========================================
# WARP Client Proxy Mode 一键安装脚本 (智能版)
# 功能：监测运行状态 -> 询问重装 -> 安装/配置 -> 端口 40000 -> 双栈IP检测
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

# ================= 核心功能函数 =================

# 1. 系统检测与依赖安装 (检测 IP 需要 jq，所以必须先运行)
install_dependencies() {
    echo -e "${CYAN}正在初始化环境并安装依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        apt-get update -y
        apt-get install -y curl gnupg lsb-release jq
        
        # 预先配置源，方便后续判断
        if [ ! -f /etc/apt/sources.list.d/cloudflare-client.list ]; then
            curl -s https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
        fi

    elif [ -f /etc/redhat-release ]; then
        # CentOS/AlmaLinux/Rocky
        yum install -y curl jq
        # 添加源
        if [ ! -f /etc/yum.repos.d/cloudflare-warp.repo ]; then
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el8.rpm 2>/dev/null || rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el9.rpm 2>/dev/null
        fi
    else
        echo -e "${RED}不支持的操作系统！${PLAIN}"
        exit 1
    fi
}

# 2. 状态检测与输出 (新增功能)
verify_status() {
    echo -e "\n${CYAN}正在检测连接状态...${PLAIN}"
    
    check_ip() {
        local type=$1 # 4 or 6
        # 使用 ip-api.com 获取 JSON 数据，超时时间 10秒
        local result=$(curl -s -m 10 -x socks5h://127.0.0.1:40000 -$type http://ip-api.com/json?fields=query,country,isp,status)
        
        if [[ $(echo "$result" | jq -r '.status') == "success" ]]; then
            local ip=$(echo "$result" | jq -r '.query')
            local country=$(echo "$result" | jq -r '.country')
            local isp=$(echo "$result" | jq -r '.isp')
            echo -e " WARP Free IPv${type}: ${GREEN}${ip}${PLAIN} ${YELLOW}${country}${PLAIN} ${CYAN}${isp}${PLAIN}"
        else
            echo -e " WARP Free IPv${type}: ${RED}连接失败 或 无此网络栈${PLAIN}"
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

# 3. 智能监测逻辑 (新增功能)
check_if_running() {
    # 检查 warp-cli 是否存在 且 warp-svc 是否运行中
    if command -v warp-cli &> /dev/null && systemctl is-active --quiet warp-svc; then
        echo -e "\n${YELLOW}========================================${PLAIN}"
        echo -e "${YELLOW}警告：检测到 WARP 已经在运行中！${PLAIN}"
        echo -e "${YELLOW}========================================${PLAIN}"
        read -p "是否要强制重新安装并重置配置？(y/n) [默认 n]: " choice
        case "$choice" in
            y|Y )
                echo -e "${CYAN}用户选择重装，即将开始...${PLAIN}"
                return 0 # 继续执行安装
                ;;
            * )
                echo -e "${GREEN}已跳过安装。直接检查当前连接状态...${PLAIN}"
                verify_status
                exit 0 # 退出脚本
                ;;
        esac
    fi
}

# 4. 安装 WARP
install_warp() {
    echo -e "${CYAN}正在安装/更新 Cloudflare WARP...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get install cloudflare-warp -y
    else
        yum install cloudflare-warp -y
    fi
}

# 5. 启动服务与等待
start_service() {
    echo -e "${CYAN}正在启动 WARP 服务...${PLAIN}"
    systemctl enable --now warp-svc
    
    # 循环检测 socket 是否生成
    local RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        if systemctl is-active --quiet warp-svc && [[ -S /var/lib/cloudflare-warp/warp_service.sock || -S /run/cloudflare-warp/warp_service.sock ]]; then
            return 0
        fi
        sleep 1
        ((RETRIES++))
    done
    echo -e "${RED}服务启动超时，请手动检查！${PLAIN}"
    exit 1
}

# 6. 配置 WARP
configure_warp() {
    echo -e "${CYAN}正在配置 Proxy 模式 (端口 40000)...${PLAIN}"
    
    # 强制断开并重置旧配置
    warp-cli disconnect &>/dev/null
    rm -rf /var/lib/cloudflare-warp/reg.json &>/dev/null

    # 智能识别版本
    HELP_INFO=$(warp-cli --help)
    
    if echo "$HELP_INFO" | grep -q "registration"; then
        # 新版语法
        warp-cli mode proxy
        warp-cli proxy port 40000
        echo -e "${YELLOW}正在注册账号...${PLAIN}"
        warp-cli registration new
        echo -e "${YELLOW}正在连接...${PLAIN}"
        warp-cli connect
    else
        # 旧版语法
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
install_dependencies # 先安装 jq 等依赖，用于检测和后续
check_if_running     # 检查运行状态，询问用户
install_warp         # 安装
start_service        # 启动
configure_warp       # 配置
verify_status        # 检测
