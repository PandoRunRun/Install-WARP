#!/bin/bash

# ==========================================
# WARP Client Proxy Mode 一键脚本 (终极版)
# 更新日志：
# - 启动时若检测到运行，先显示当前 IP 状态
# - 新增"仅重启服务"选项 (Restart Service Only)
# - 优化服务等待逻辑，避免重启时报错
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

# ================= 核心工具函数 =================

# 1. 等待服务就绪 (通用函数)
wait_for_service() {
    echo -e "${YELLOW}正在等待 WARP 服务就绪...${PLAIN}"
    local RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        # 检查服务状态 AND socket 文件是否存在
        if systemctl is-active --quiet warp-svc && [[ -S /var/lib/cloudflare-warp/warp_service.sock || -S /run/cloudflare-warp/warp_service.sock ]]; then
            echo -e "${GREEN}服务已就绪！${PLAIN}"
            return 0
        fi
        sleep 1
        ((RETRIES++))
    done
    echo -e "${RED}服务启动/重启超时！建议查看日志: systemctl status warp-svc${PLAIN}"
    exit 1
}

# 2. 状态检测与输出
verify_status() {
    echo -e "\n${CYAN}正在检测连接状态 (IP 信息)...${PLAIN}"
    
    check_ip() {
        local type=$1
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

# 3. 仅重启服务逻辑
restart_warp_only() {
    echo -e "${CYAN}正在重启 WARP 服务...${PLAIN}"
    systemctl restart warp-svc
    wait_for_service
    echo -e "${GREEN}重启完成，正在重新检测连通性...${PLAIN}"
    sleep 2
    verify_status
}

# 4. 系统检测与依赖安装
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

# 5. 智能监测逻辑 (带菜单)
check_if_running() {
    if command -v warp-cli &> /dev/null && systemctl is-active --quiet warp-svc; then
        echo -e "\n${YELLOW}========================================${PLAIN}"
        echo -e "${YELLOW}检测到 WARP 已在运行，当前状态如下：${PLAIN}"
        verify_status
        echo -e "${YELLOW}========================================${PLAIN}"
        
        echo -e "请选择操作："
        echo -e " ${GREEN}1.${PLAIN} 强制重装并重置 (Reinstall & Reset) - [适用于完全无法使用]"
        echo -e " ${GREEN}2.${PLAIN} 仅重启服务 (Restart Service) - [适用于连接不稳定/无网络]"
        echo -e " ${GREEN}3.${PLAIN} 退出 (Exit)"
        echo -e ""
        read -p "请输入数字 [1-3]: " choice
        
        case "$choice" in
            1 )
                echo -e "${CYAN}用户选择重装，即将开始...${PLAIN}"
                return 0 # 继续执行后续的安装流程
                ;;
            2 )
                restart_warp_only
                exit 0 # 重启完直接退出
                ;;
            * )
                echo -e "${GREEN}已退出。${PLAIN}"
                exit 0
                ;;
        esac
    fi
}

# 6. 安装 WARP
install_warp() {
    echo -e "${CYAN}正在安装/更新 Cloudflare WARP...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get install cloudflare-warp -y
    else
        yum install cloudflare-warp -y
    fi
}

# 7. 启动服务 (安装模式用)
start_service_initial() {
    echo -e "${CYAN}正在启动 WARP 服务...${PLAIN}"
    systemctl enable warp-svc
    systemctl restart warp-svc
    wait_for_service
}

# 8. 配置 WARP
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
install_dependencies # 必须先跑，为了有 jq 和 curl 检查状态
check_if_running     # 检查状态并显示菜单 (如果是选重启，会在这里结束)

# 如果用户选了 1 (重装)，或者是第一次安装，才会执行下面这些
install_warp
start_service_initial
configure_warp
verify_status
