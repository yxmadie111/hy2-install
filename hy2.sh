#!/bin/bash

# ============================================
#  Hysteria 2 一键管理脚本 v2.1
#  支持系统: Debian / Ubuntu / CentOS
#  功能: 安装/卸载/域名证书/多用户/端口跳跃/BBR加速
#  快捷命令: hy2
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

HY2_BIN="/usr/local/bin/hysteria"
HY2_DIR="/etc/hysteria"
HY2_CONF="${HY2_DIR}/config.yaml"
HY2_CERT="${HY2_DIR}/server.crt"
HY2_KEY="${HY2_DIR}/server.key"
HY2_USERS="${HY2_DIR}/users.txt"
HY2_SERVICE="/etc/systemd/system/hysteria-server.service"
HY2_HOPPING_CONF="${HY2_DIR}/port_hopping.conf"
HY2_META="${HY2_DIR}/meta.conf"
HY2_SCRIPT="/usr/local/bin/hy2"
ACME_DIR="/root/.acme.sh"

# ---------- 工具函数 ----------
msg_info()  { echo -e "${CYAN}[信息]${RESET} $1"; }
msg_ok()    { echo -e "${GREEN}[完成]${RESET} $1"; }
msg_warn()  { echo -e "${YELLOW}[警告]${RESET} $1"; }
msg_err()   { echo -e "${RED}[错误]${RESET} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "请使用 root 用户运行此脚本"
        exit 1
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -4s --max-time 5 https://ifconfig.me 2>/dev/null) \
    || ip=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -4s --max-time 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

check_installed() {
    [[ -f "$HY2_BIN" && -f "$HY2_CONF" ]]
}

press_any_key() {
    echo ""
    read -rp "按回车键返回..." _
}

# 安装 hy2 快捷命令
install_shortcut() {
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    if [[ "$self_path" == "/dev/"* ]] || [[ "$self_path" == "/proc/"* ]] || [[ ! -f "$self_path" ]]; then
        if [[ -f "$HY2_SCRIPT" ]]; then
            return 0
        fi
        curl -sL "https://raw.githubusercontent.com/yxmadie111/hy2-install/main/hy2_install.sh" -o "$HY2_SCRIPT" 2>/dev/null
    else
        cp -f "$self_path" "$HY2_SCRIPT" 2>/dev/null
    fi

    if [[ -f "$HY2_SCRIPT" ]]; then
        chmod +x "$HY2_SCRIPT"
    fi
}

# 解析域名 IP（兼容国内网络）
resolve_domain_ip() {
    local domain="$1"
    local resolved=""

    if command -v dig &>/dev/null; then
        resolved=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi

    if [[ -z "$resolved" ]] && command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9]+\.' | head -1)
    fi

    if [[ -z "$resolved" ]] && command -v getent &>/dev/null; then
        resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | grep -E '^[0-9]+\.' | head -1)
    fi

    echo "$resolved"
}

# ---------- 安装依赖 ----------
install_deps() {
    msg_info "安装依赖..."
    if command -v apt &>/dev/null; then
        apt update -y &>/dev/null
        apt install -y curl wget openssl iptables socat cron dnsutils &>/dev/null
        systemctl enable cron &>/dev/null 2>&1
        systemctl start cron &>/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget openssl iptables socat cronie bind-utils &>/dev/null
        systemctl enable crond &>/dev/null 2>&1
        systemctl start crond &>/dev/null 2>&1
    fi
    msg_ok "依赖安装完成"
}

# ---------- 下载 Hysteria 2 ----------
install_hysteria() {
    msg_info "下载 Hysteria 2..."

    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       msg_err "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    local latest_ver
    latest_ver=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$latest_ver" ]]; then
        msg_err "获取最新版本失败，请检查网络"
        return 1
    fi

    msg_info "最新版本: ${latest_ver}"

    local download_url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-${arch}"

    wget -q -O "$HY2_BIN" "$download_url"
    if [[ $? -ne 0 ]]; then
        msg_err "下载失败"
        return 1
    fi

    chmod +x "$HY2_BIN"
    msg_ok "Hysteria 2 (${latest_ver}) 下载完成"
}

# ========================================
#  证书管理
# ========================================

generate_self_signed_cert() {
    mkdir -p "$HY2_DIR"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -subj "/CN=bing.com" -days 3650 2>/dev/null
    msg_ok "自签证书生成完成"
}

install_acme() {
    if [[ -f "${ACME_DIR}/acme.sh" ]]; then
        msg_ok "acme.sh 已安装"
        return 0
    fi

    msg_info "安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=hy2auto@example.com 2>/dev/null

    if [[ -f "${ACME_DIR}/acme.sh" ]]; then
        msg_ok "acme.sh 安装完成"
        return 0
    else
        msg_err "acme.sh 安装失败"
        return 1
    fi
}

apply_acme_cert() {
    local domain="$1"

    install_acme || return 1

    if ss -tlnp | grep -q ':80 '; then
        msg_warn "端口 80 被占用，尝试临时释放..."
        local pid80=""
        if command -v fuser &>/dev/null; then
            pid80=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
        fi
        if [[ -z "$pid80" ]] && command -v lsof &>/dev/null; then
            pid80=$(lsof -ti:80 2>/dev/null | head -1)
        fi
        if [[ -z "$pid80" ]]; then
            pid80=$(ss -tlnp | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1)
        fi
        if [[ -n "$pid80" ]]; then
            msg_info "临时停止占用 80 端口的进程 (PID: ${pid80})..."
            kill "$pid80" 2>/dev/null
            sleep 2
        fi
    fi

    msg_info "正在为 ${domain} 申请证书 (可能需要 30 秒)..."

    "${ACME_DIR}/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --force 2>/dev/null

    if [[ $? -ne 0 ]]; then
        msg_err "证书申请失败！请检查："
        echo -e "  ${YELLOW}1. 域名 A 记录是否指向本机 IP${RESET}"
        echo -e "  ${YELLOW}2. 端口 80 是否被防火墙拦截${RESET}"
        echo -e "  ${YELLOW}3. 域名是否已生效 (刚修改 DNS 需等几分钟)${RESET}"
        return 1
    fi

    mkdir -p "$HY2_DIR"

    "${ACME_DIR}/acme.sh" --install-cert -d "$domain" --ecc \
        --key-file "$HY2_KEY" \
        --fullchain-file "$HY2_CERT" \
        --reloadcmd "systemctl restart hysteria-server 2>/dev/null" 2>/dev/null

    if [[ -f "$HY2_CERT" && -f "$HY2_KEY" ]]; then
        msg_ok "证书申请并安装成功 (自动续期已配置)"
        return 0
    else
        msg_err "证书安装失败"
        return 1
    fi
}

# ---------- 生成配置文件 ----------
generate_config() {
    local port="$1"
    local masquerade="$2"
    local domain="$3"
    local bandwidth_up="$4"
    local bandwidth_down="$5"

    local auth_block=""
    local user_count
    user_count=$(wc -l < "$HY2_USERS" 2>/dev/null || echo "0")

    if [[ "$user_count" -le 1 ]]; then
        local single_pw
        single_pw=$(head -1 "$HY2_USERS" | cut -d: -f2)
        auth_block="auth:
  type: password
  password: \"${single_pw}\""
    else
        auth_block="auth:
  type: userpass
  userpass:"
        while IFS=: read -r uname upw; do
            auth_block="${auth_block}
    \"${uname}\": \"${upw}\""
        done < "$HY2_USERS"
    fi

    cat > "$HY2_CONF" <<EOF
listen: :${port}

tls:
  cert: ${HY2_CERT}
  key: ${HY2_KEY}

${auth_block}

masquerade:
  type: proxy
  proxy:
    url: https://${masquerade}
    rewriteHost: true

bandwidth:
  up: ${bandwidth_up} mbps
  down: ${bandwidth_down} mbps

acl:
  inline:
    - direct(all)
EOF

    msg_ok "配置文件生成完成"
}

# ---------- 创建 systemd 服务 ----------
create_service() {
    cat > "$HY2_SERVICE" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=${HY2_BIN} server -c ${HY2_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server &>/dev/null
    systemctl start hysteria-server

    sleep 1
    if systemctl is-active --quiet hysteria-server; then
        msg_ok "服务启动成功"
    else
        msg_err "服务启动失败，请查看菜单中的 [查看日志] 排查"
    fi
}

# ---------- 防火墙管理 ----------
open_port() {
    local port="$1"
    local proto="${2:-udp}"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" &>/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" &>/dev/null
        firewall-cmd --reload &>/dev/null
    else
        if command -v iptables &>/dev/null; then
            iptables -C INPUT -p "$proto" --dport "${port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p "$proto" --dport "${port}" -j ACCEPT &>/dev/null
        fi
    fi
    msg_ok "已放行端口 ${port}/${proto}"
}

open_port_range() {
    local range_start="$1"
    local range_end="$2"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${range_start}:${range_end}/udp" &>/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${range_start}-${range_end}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
    else
        if command -v iptables &>/dev/null; then
            iptables -C INPUT -p udp --dport "${range_start}:${range_end}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "${range_start}:${range_end}" -j ACCEPT &>/dev/null
        fi
    fi
    msg_ok "已放行端口 ${range_start}-${range_end}/udp"
}

save_iptables_rules() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables.rules 2>/dev/null
        if [[ ! -f /etc/network/if-pre-up.d/iptables ]]; then
            mkdir -p /etc/network/if-pre-up.d 2>/dev/null
            cat > /etc/network/if-pre-up.d/iptables <<'EOIPT'
#!/bin/bash
iptables-restore < /etc/iptables.rules 2>/dev/null
EOIPT
            chmod +x /etc/network/if-pre-up.d/iptables 2>/dev/null
        fi
    fi
}

# ========================================
#  端口跳跃
# ========================================

setup_port_hopping() {
    if ! check_installed; then
        msg_err "请先安装 Hysteria 2"
        return
    fi

    local main_port
    main_port=$(grep '^listen:' "$HY2_CONF" | sed 's/listen: ://')
    msg_info "当前 Hysteria 2 监听端口: ${main_port}"

    read -rp "请输入端口跳跃起始端口 [默认 20000]: " hop_start
    hop_start="${hop_start:-20000}"
    read -rp "请输入端口跳跃结束端口 [默认 40000]: " hop_end
    hop_end="${hop_end:-40000}"

    if [[ "$hop_start" -ge "$hop_end" ]]; then
        msg_err "起始端口必须小于结束端口"
        return
    fi

    msg_info "配置端口跳跃: ${hop_start}-${hop_end} → ${main_port}"

    remove_port_hopping_rules silent

    iptables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j DNAT --to-destination ":${main_port}"
    ip6tables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j DNAT --to-destination ":${main_port}" 2>/dev/null

    open_port_range "$hop_start" "$hop_end"

    cat > "$HY2_HOPPING_CONF" <<EOF
HOP_START=${hop_start}
HOP_END=${hop_end}
MAIN_PORT=${main_port}
EOF

    cat > /etc/systemd/system/hy2-port-hopping.service <<EOF
[Unit]
Description=Hysteria 2 Port Hopping Rules
Before=hysteria-server.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${main_port}
ExecStart=/sbin/ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${main_port}
ExecStop=/sbin/iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${main_port}
ExecStop=/sbin/ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${main_port}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hy2-port-hopping &>/dev/null
    systemctl start hy2-port-hopping &>/dev/null

    save_iptables_rules

    msg_ok "端口跳跃配置完成: ${hop_start}-${hop_end} → ${main_port}"
}

remove_port_hopping_rules() {
    local silent="$1"

    if [[ -f "$HY2_HOPPING_CONF" ]]; then
        source "$HY2_HOPPING_CONF"
        iptables -t nat -D PREROUTING -p udp --dport "${HOP_START}:${HOP_END}" -j DNAT --to-destination ":${MAIN_PORT}" 2>/dev/null
        ip6tables -t nat -D PREROUTING -p udp --dport "${HOP_START}:${HOP_END}" -j DNAT --to-destination ":${MAIN_PORT}" 2>/dev/null
        rm -f "$HY2_HOPPING_CONF"
    fi

    if [[ -f /etc/systemd/system/hy2-port-hopping.service ]]; then
        systemctl stop hy2-port-hopping &>/dev/null
        systemctl disable hy2-port-hopping &>/dev/null
        rm -f /etc/systemd/system/hy2-port-hopping.service
        systemctl daemon-reload
    fi

    save_iptables_rules

    if [[ "$silent" != "silent" ]]; then
        msg_ok "端口跳跃规则已清除"
    fi
}

show_hopping_status() {
    if [[ -f "$HY2_HOPPING_CONF" ]]; then
        source "$HY2_HOPPING_CONF"
        echo ""
        msg_ok "端口跳跃已启用: ${HOP_START}-${HOP_END} → ${MAIN_PORT}"

        local rule_count
        rule_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "dpts:${HOP_START}:${HOP_END}")
        if [[ "$rule_count" -gt 0 ]]; then
            msg_ok "iptables 规则生效中"
        else
            msg_warn "iptables 规则未生效，请尝试重新配置"
        fi
    else
        echo ""
        msg_warn "端口跳跃未启用"
    fi
}

# ========================================
#  BBR 加速
# ========================================

enable_bbr() {
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$current_cc" == "bbr" ]]; then
        msg_ok "BBR 已经处于启用状态"
        show_bbr_status
        return
    fi

    if ! modprobe tcp_bbr &>/dev/null; then
        local kernel_major kernel_minor
        kernel_major=$(uname -r | cut -d'.' -f1)
        kernel_minor=$(uname -r | cut -d'.' -f2)
        if [[ "$kernel_major" -lt 4 ]] || { [[ "$kernel_major" -eq 4 ]] && [[ "$kernel_minor" -lt 9 ]]; }; then
            msg_err "当前内核 $(uname -r) 不支持 BBR (需要 4.9+)"
            return
        fi
    fi

    msg_info "正在启用 BBR..."

    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 65536
EOF

    sysctl --system &>/dev/null

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$new_cc" == "bbr" ]]; then
        msg_ok "BBR 启用成功"
    else
        msg_err "BBR 启用失败，当前拥塞控制: ${new_cc}"
        return
    fi

    show_bbr_status
}

disable_bbr() {
    rm -f /etc/sysctl.d/99-bbr.conf
    sysctl -w net.core.default_qdisc=pfifo_fast &>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=cubic &>/dev/null
    msg_ok "BBR 已关闭，恢复为 cubic"
}

show_bbr_status() {
    echo ""
    echo -e "${GREEN}---------- BBR 状态 ----------${RESET}"
    echo -e "  内核版本:     ${CYAN}$(uname -r)${RESET}"
    echo -e "  拥塞控制算法: ${CYAN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${RESET}"
    echo -e "  队列调度:     ${CYAN}$(sysctl -n net.core.default_qdisc 2>/dev/null)${RESET}"

    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        echo -e "  BBR 模块:     ${GREEN}已加载${RESET}"
    else
        echo -e "  BBR 模块:     ${YELLOW}未加载 (内核可能内置)${RESET}"
    fi
    echo -e "${GREEN}------------------------------${RESET}"
}

# ========================================
#  多用户管理
# ========================================

add_user() {
    if ! check_installed; then
        msg_err "请先安装 Hysteria 2"
        return
    fi

    read -rp "请输入用户名: " new_username
    if [[ -z "$new_username" ]]; then
        msg_err "用户名不能为空"
        return
    fi

    if [[ "$new_username" == *":"* ]]; then
        msg_err "用户名不能包含冒号 (:)"
        return
    fi

    if grep -q "^${new_username}:" "$HY2_USERS" 2>/dev/null; then
        msg_err "用户 ${new_username} 已存在"
        return
    fi

    read -rp "请输入密码 [回车随机生成]: " new_password
    new_password="${new_password:-$(openssl rand -hex 8)}"

    if [[ "$new_password" == *":"* ]]; then
        msg_err "密码不能包含冒号 (:)"
        return
    fi

    echo "${new_username}:${new_password}" >> "$HY2_USERS"

    rebuild_config
    systemctl restart hysteria-server &>/dev/null

    msg_ok "用户 ${new_username} 添加成功 (密码: ${new_password})"
}

remove_user() {
    if ! check_installed; then
        msg_err "请先安装 Hysteria 2"
        return
    fi

    list_users

    local user_count
    user_count=$(wc -l < "$HY2_USERS" 2>/dev/null || echo "0")

    if [[ "$user_count" -le 1 ]]; then
        msg_err "至少保留一个用户，无法删除"
        return
    fi

    read -rp "请输入要删除的用户名: " del_username
    if [[ -z "$del_username" ]]; then
        return
    fi

    if ! grep -q "^${del_username}:" "$HY2_USERS" 2>/dev/null; then
        msg_err "用户 ${del_username} 不存在"
        return
    fi

    sed -i "/^${del_username}:/d" "$HY2_USERS"

    rebuild_config
    systemctl restart hysteria-server &>/dev/null

    msg_ok "用户 ${del_username} 已删除"
}

list_users() {
    echo ""
    echo -e "${GREEN}---------- 用户列表 ----------${RESET}"

    if [[ ! -f "$HY2_USERS" ]] || [[ ! -s "$HY2_USERS" ]]; then
        echo -e "  ${YELLOW}(无用户)${RESET}"
    else
        local idx=1
        while IFS=: read -r uname upw; do
            echo -e "  ${CYAN}${idx}.${RESET} 用户名: ${GREEN}${uname}${RESET}  密码: ${GREEN}${upw}${RESET}"
            ((idx++))
        done < "$HY2_USERS"
    fi

    echo -e "${GREEN}------------------------------${RESET}"
}

show_user_links() {
    if ! check_installed; then
        msg_err "Hysteria 2 未安装"
        return
    fi

    local server_ip port masquerade insecure sni_value
    server_ip=$(get_public_ip)
    port=$(grep '^listen:' "$HY2_CONF" | sed 's/listen: ://')
    masquerade=$(grep '    url:' "$HY2_CONF" | sed 's|.*https://||')

    local DOMAIN=""
    if [[ -f "$HY2_META" ]]; then
        source "$HY2_META"
    fi

    if [[ -n "$DOMAIN" ]]; then
        insecure="0"
        sni_value="$DOMAIN"
    else
        insecure="1"
        sni_value="$masquerade"
    fi

    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  所有用户的客户端链接${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo ""
    echo -e "  服务器:    ${CYAN}${server_ip}${RESET}"
    echo -e "  端口:      ${CYAN}${port}${RESET}"
    echo -e "  伪装域名:  ${CYAN}${masquerade}${RESET}"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  绑定域名:  ${CYAN}${DOMAIN}${RESET} (真证书)"
    else
        echo -e "  证书类型:  ${YELLOW}自签证书 (insecure=1)${RESET}"
    fi
    echo ""

    local user_count
    user_count=$(wc -l < "$HY2_USERS" 2>/dev/null || echo "0")

    while IFS=: read -r uname upw; do
        local url
        if [[ "$user_count" -le 1 ]]; then
            url="hysteria2://${upw}@${server_ip}:${port}/?insecure=${insecure}&sni=${sni_value}#Hy2-${uname}"
        else
            url="hysteria2://${uname}:${upw}@${server_ip}:${port}/?insecure=${insecure}&sni=${sni_value}#Hy2-${uname}"
        fi
        echo -e "  ${YELLOW}[${uname}]${RESET}"
        echo -e "  ${GREEN}${url}${RESET}"
        echo ""

        if [[ -f "$HY2_HOPPING_CONF" ]]; then
            source "$HY2_HOPPING_CONF"
            local hop_url
            if [[ "$user_count" -le 1 ]]; then
                hop_url="hysteria2://${upw}@${server_ip}:${port}/?insecure=${insecure}&sni=${sni_value}&mport=${HOP_START}-${HOP_END}#Hy2-Hop-${uname}"
            else
                hop_url="hysteria2://${uname}:${upw}@${server_ip}:${port}/?insecure=${insecure}&sni=${sni_value}&mport=${HOP_START}-${HOP_END}#Hy2-Hop-${uname}"
            fi
            echo -e "  ${YELLOW}[${uname} - 端口跳跃]${RESET}"
            echo -e "  ${GREEN}${hop_url}${RESET}"
            echo ""
        fi
    done < "$HY2_USERS"

    echo -e "${GREEN}============================================${RESET}"
}

rebuild_config() {
    if [[ ! -f "$HY2_META" ]]; then
        msg_err "元数据文件不存在，无法重建配置"
        return 1
    fi

    source "$HY2_META"
    generate_config "$PORT" "$MASQUERADE" "$DOMAIN" "$BW_UP" "$BW_DOWN"
}

# ========================================
#  安装完成展示
# ========================================

show_install_result() {
    local ip="$1" port="$2" masquerade="$3" domain="$4"

    local insecure sni_value
    if [[ -n "$domain" ]]; then
        insecure="0"
        sni_value="$domain"
    else
        insecure="1"
        sni_value="$masquerade"
    fi

    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  Hysteria 2 安装成功！${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo ""
    echo -e "  服务器地址:   ${CYAN}${ip}${RESET}"
    echo -e "  端口:         ${CYAN}${port}${RESET}"
    echo -e "  伪装域名:     ${CYAN}${masquerade}${RESET}"

    if [[ -n "$domain" ]]; then
        echo -e "  绑定域名:     ${CYAN}${domain}${RESET}"
        echo -e "  证书类型:     ${GREEN}真证书 (Let's Encrypt)${RESET}"
    else
        echo -e "  证书类型:     ${YELLOW}自签证书 (insecure=1)${RESET}"
    fi

    echo ""
    echo -e "${YELLOW}  用户链接:${RESET}"
    echo ""

    local user_count
    user_count=$(wc -l < "$HY2_USERS" 2>/dev/null || echo "0")

    while IFS=: read -r uname upw; do
        local url
        if [[ "$user_count" -le 1 ]]; then
            url="hysteria2://${upw}@${ip}:${port}/?insecure=${insecure}&sni=${sni_value}#Hy2-${uname}"
        else
            url="hysteria2://${uname}:${upw}@${ip}:${port}/?insecure=${insecure}&sni=${sni_value}#Hy2-${uname}"
        fi
        echo -e "  ${YELLOW}[${uname}]${RESET} ${GREEN}${url}${RESET}"
    done < "$HY2_USERS"

    echo ""
    echo -e "  ${CYAN}提示: 以后输入 ${GREEN}hy2${CYAN} 即可打开管理菜单${RESET}"
    echo ""
    echo -e "${GREEN}============================================${RESET}"
}

# ---------- 优化 UDP 缓冲区 ----------
tune_udp_buffer() {
    local changed=0
    local params=(
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.core.rmem_default=1048576"
        "net.core.wmem_default=1048576"
    )
    for param in "${params[@]}"; do
        local key="${param%%=*}"
        local val="${param##*=}"
        if ! grep -qE "^${key}\s*=" /etc/sysctl.conf 2>/dev/null; then
            echo "${key} = ${val}" >> /etc/sysctl.conf
            changed=1
        fi
    done
    sysctl -p &>/dev/null
    [[ "$changed" -eq 1 ]] && msg_ok "UDP 缓冲区已优化" || msg_ok "UDP 缓冲区已是最优配置"
}

# ========================================
#  安装流程
# ========================================

do_install() {
    if check_installed; then
        msg_warn "Hysteria 2 已安装，如需重装请先卸载"
        return
    fi

    local server_ip
    server_ip=$(get_public_ip)
    if [[ -z "$server_ip" ]]; then
        msg_err "无法获取公网 IP"
        return
    fi
    msg_info "检测到公网 IP: ${server_ip}"

    echo ""
    read -rp "请输入端口 [默认 443]: " input_port
    local port="${input_port:-443}"

    echo ""
    echo -e "${CYAN}是否绑定域名? (绑定域名可获得真证书，更安全)${RESET}"
    echo -e "  ${CYAN}1.${RESET} 绑定域名 (需要提前将域名 A 记录指向 ${server_ip})"
    echo -e "  ${CYAN}2.${RESET} 不绑定，使用自签证书"
    echo ""
    read -rp "请选择 [1/2，默认 2]: " domain_choice
    domain_choice="${domain_choice:-2}"

    local domain=""
    local cert_mode="self"

    if [[ "$domain_choice" == "1" ]]; then
        read -rp "请输入你的域名 (例: hy2.example.com): " domain
        if [[ -z "$domain" ]]; then
            msg_err "域名不能为空，改用自签证书"
            cert_mode="self"
        else
            cert_mode="acme"

            msg_info "检查域名解析..."
            local resolved_ip
            resolved_ip=$(resolve_domain_ip "$domain")

            if [[ "$resolved_ip" == "$server_ip" ]]; then
                msg_ok "域名 ${domain} 已正确指向 ${server_ip}"
            elif [[ -z "$resolved_ip" ]]; then
                msg_warn "无法解析域名 ${domain}"
                read -rp "是否继续? (可能是 DNS 尚未生效) [y/N]: " force_continue
                if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
                    msg_info "改用自签证书"
                    cert_mode="self"
                    domain=""
                fi
            else
                msg_warn "域名解析结果 (${resolved_ip}) 与本机 IP (${server_ip}) 不一致"
                read -rp "是否继续? [y/N]: " force_continue
                if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
                    msg_info "改用自签证书"
                    cert_mode="self"
                    domain=""
                fi
            fi
        fi
    fi

    echo ""
    read -rp "请输入伪装网站 [默认 www.bing.com]: " input_mask
    local masquerade="${input_mask:-www.bing.com}"

    echo ""
    read -rp "请输入第一个用户名 [默认 user1]: " input_username
    local username="${input_username:-user1}"
    read -rp "请输入密码 [回车随机生成]: " input_pw
    local password="${input_pw:-$(openssl rand -hex 8)}"

    echo ""
    read -rp "请输入上行带宽 (Mbps) [默认 100]: " input_bw_up
    local bw_up="${input_bw_up:-100}"
    read -rp "请输入下行带宽 (Mbps) [默认 100]: " input_bw_down
    local bw_down="${input_bw_down:-100}"

    echo ""
    local use_hopping="n"
    local hop_start="" hop_end=""
    read -rp "是否启用端口跳跃? [y/N]: " use_hopping
    if [[ "$use_hopping" =~ ^[Yy]$ ]]; then
        read -rp "  跳跃起始端口 [默认 20000]: " hop_start
        hop_start="${hop_start:-20000}"
        read -rp "  跳跃结束端口 [默认 40000]: " hop_end
        hop_end="${hop_end:-40000}"
    fi

    echo ""
    local use_bbr="Y"
    read -rp "是否启用 BBR 加速? [Y/n]: " use_bbr
    use_bbr="${use_bbr:-Y}"

    echo ""
    echo -e "${CYAN}============================================${RESET}"
    echo -e "  端口: ${GREEN}${port}${RESET}"
    if [[ -n "$domain" ]]; then
        echo -e "  域名: ${GREEN}${domain}${RESET} (真证书)"
    else
        echo -e "  证书: ${YELLOW}自签证书${RESET}"
    fi
    echo -e "  伪装: ${GREEN}${masquerade}${RESET}"
    echo -e "  用户: ${GREEN}${username}${RESET} / ${GREEN}${password}${RESET}"
    echo -e "  带宽: ${GREEN}↑${bw_up} Mbps / ↓${bw_down} Mbps${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo ""
    read -rp "确认安装? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_info "已取消"
        return
    fi

    install_deps
    tune_udp_buffer

    if [[ "$cert_mode" == "acme" ]]; then
        open_port 80 tcp
    fi

    install_hysteria || return

    mkdir -p "$HY2_DIR"
    echo "${username}:${password}" > "$HY2_USERS"

    cat > "$HY2_META" <<EOF
PORT=${port}
MASQUERADE=${masquerade}
DOMAIN=${domain}
BW_UP=${bw_up}
BW_DOWN=${bw_down}
EOF

    if [[ "$cert_mode" == "acme" ]]; then
        if ! apply_acme_cert "$domain"; then
            msg_warn "真证书申请失败，改用自签证书"
            domain=""
            sed -i 's/^DOMAIN=.*/DOMAIN=/' "$HY2_META"
            generate_self_signed_cert
        fi
    else
        generate_self_signed_cert
    fi

    generate_config "$port" "$masquerade" "$domain" "$bw_up" "$bw_down"
    create_service
    open_port "$port" udp

    if [[ "$use_hopping" =~ ^[Yy]$ ]]; then
        iptables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j DNAT --to-destination ":${port}"
        ip6tables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -j DNAT --to-destination ":${port}" 2>/dev/null
        open_port_range "$hop_start" "$hop_end"

        cat > "$HY2_HOPPING_CONF" <<EOF
HOP_START=${hop_start}
HOP_END=${hop_end}
MAIN_PORT=${port}
EOF

        cat > /etc/systemd/system/hy2-port-hopping.service <<EOF
[Unit]
Description=Hysteria 2 Port Hopping Rules
Before=hysteria-server.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${port}
ExecStart=/sbin/ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${port}
ExecStop=/sbin/iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${port}
ExecStop=/sbin/ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${port}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hy2-port-hopping &>/dev/null
        systemctl start hy2-port-hopping &>/dev/null
        msg_ok "端口跳跃配置完成: ${hop_start}-${hop_end} → ${port}"
    fi

    save_iptables_rules

    if [[ "$use_bbr" =~ ^[Yy]$ ]]; then
        enable_bbr
    fi

    install_shortcut

    show_install_result "$server_ip" "$port" "$masquerade" "$domain"
}

# ========================================
#  卸载
# ========================================

do_uninstall() {
    echo ""
    read -rp "确认卸载 Hysteria 2? 所有配置将被删除 [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        msg_info "已取消"
        return
    fi

    msg_info "正在卸载 Hysteria 2..."
    systemctl stop hysteria-server &>/dev/null
    systemctl disable hysteria-server &>/dev/null
    rm -f "$HY2_SERVICE"
    rm -f "$HY2_BIN"
    remove_port_hopping_rules silent
    rm -rf "$HY2_DIR"
    systemctl daemon-reload
    msg_ok "卸载完成 (快捷命令 hy2 已保留，可手动删除: rm -f ${HY2_SCRIPT})"
}

do_show_config() {
    if ! check_installed; then
        msg_err "Hysteria 2 未安装"
        return
    fi
    show_user_links
}

# 重启功能（修复了逻辑问题）
do_restart() {
    systemctl restart hysteria-server
    sleep 1
    if systemctl is-active --quiet hysteria-server; then
        msg_ok "重启成功"
    else
        msg_err "重启失败，请查看日志排查"
    fi
}

do_status() {
    echo ""
    systemctl status hysteria-server --no-pager
}

do_view_log() {
    while true; do
        echo ""
        echo -e "${CYAN}  --- 日志选项 ---${RESET}"
        echo -e "  ${CYAN}1.${RESET} 查看最近 30 条日志"
        echo -e "  ${CYAN}2.${RESET} 查看最近 100 条日志"
        echo -e "  ${CYAN}3.${RESET} 实时跟踪日志 (按 Ctrl+C 退出)"
        echo -e "  ${CYAN}0.${RESET} 返回"
        echo ""

        read -rp "  请选择 [0-3]: " log_choice
        case "$log_choice" in
            1) journalctl -u hysteria-server -n 30 --no-pager ;;
            2) journalctl -u hysteria-server -n 100 --no-pager ;;
            3) journalctl -u hysteria-server -f ;;
            0) return ;;
            *) msg_err "无效选择" ;;
        esac
        press_any_key
    done
}

do_update() {
    if ! check_installed; then
        msg_err "Hysteria 2 未安装"
        return
    fi

    local current_ver
    current_ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "未知")

    local latest_ver
    latest_ver=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$latest_ver" ]]; then
        msg_err "获取最新版本失败"
        return
    fi

    echo ""
    echo -e "  当前版本: ${CYAN}${current_ver}${RESET}"
    echo -e "  最新版本: ${CYAN}${latest_ver}${RESET}"
    echo ""

    read -rp "是否更新? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi

    systemctl stop hysteria-server &>/dev/null

    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       msg_err "不支持的架构"; return ;;
    esac

    local download_url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-${arch}"

    msg_info "下载中..."
    wget -q -O "$HY2_BIN" "$download_url"
    if [[ $? -ne 0 ]]; then
        msg_err "下载失败"
        return
    fi
    chmod +x "$HY2_BIN"

    systemctl start hysteria-server
    sleep 1

    if systemctl is-active --quiet hysteria-server; then
        msg_ok "更新成功，已重启服务"
    else
        msg_err "更新后启动失败，请查看日志"
    fi

    install_shortcut
}

# ========================================
#  域名证书管理（循环子菜单）
# ========================================

do_domain_manage() {
    if ! check_installed; then
        msg_err "请先安装 Hysteria 2"
        return
    fi

    while true; do
        echo ""
        echo -e "${CYAN}  --- 域名证书管理 ---${RESET}"
        echo -e "  ${CYAN}1.${RESET} 绑定域名 (申请真证书)"
        echo -e "  ${CYAN}2.${RESET} 切换为自签证书"
        echo -e "  ${CYAN}3.${RESET} 查看当前证书信息"
        echo -e "  ${CYAN}0.${RESET} 返回主菜单"
        echo ""

        read -rp "  请选择 [0-3]: " cert_choice
        case "$cert_choice" in
            1)
                local server_ip
                server_ip=$(get_public_ip)
                echo ""
                echo -e "  ${YELLOW}请先确保域名 A 记录已指向: ${server_ip}${RESET}"
                echo ""
                read -rp "请输入域名: " new_domain
                if [[ -z "$new_domain" ]]; then
                    msg_err "域名不能为空"
                    press_any_key
                    continue
                fi

                open_port 80 tcp

                if apply_acme_cert "$new_domain"; then
                    sed -i "s/^DOMAIN=.*/DOMAIN=${new_domain}/" "$HY2_META"
                    rebuild_config
                    systemctl restart hysteria-server
                    msg_ok "域名绑定成功，服务已重启"
                fi
                ;;
            2)
                generate_self_signed_cert
                if [[ -f "$HY2_META" ]]; then
                    sed -i 's/^DOMAIN=.*/DOMAIN=/' "$HY2_META"
                fi
                rebuild_config
                systemctl restart hysteria-server
                msg_ok "已切换为自签证书，服务已重启"
                ;;
            3)
                echo ""
                if [[ -f "$HY2_CERT" ]]; then
                    echo -e "${GREEN}---------- 证书信息 ----------${RESET}"
                    openssl x509 -in "$HY2_CERT" -noout -subject -issuer -dates 2>/dev/null | while read -r line; do
                        echo -e "  ${CYAN}${line}${RESET}"
                    done
                    echo -e "${GREEN}------------------------------${RESET}"
                else
                    msg_warn "未找到证书文件"
                fi
                ;;
            0) return ;;
            *) msg_err "无效选择" ;;
        esac
        press_any_key
    done
}

# ========================================
#  端口跳跃子菜单（循环）
# ========================================

port_hopping_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}  --- 端口跳跃管理 ---${RESET}"
        echo -e "  ${CYAN}1.${RESET} 配置端口跳跃"
        echo -e "  ${CYAN}2.${RESET} 关闭端口跳跃"
        echo -e "  ${CYAN}3.${RESET} 查看端口跳跃状态"
        echo -e "  ${CYAN}0.${RESET} 返回主菜单"
        echo ""

        read -rp "  请选择 [0-3]: " hop_choice
        case "$hop_choice" in
            1) setup_port_hopping ;;
            2) remove_port_hopping_rules ;;
            3) show_hopping_status ;;
            0) return ;;
            *) msg_err "无效选择" ;;
        esac
        press_any_key
    done
}

# ========================================
#  BBR 子菜单（循环）
# ========================================

bbr_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}  --- BBR 加速管理 ---${RESET}"
        echo -e "  ${CYAN}1.${RESET} 启用 BBR"
        echo -e "  ${CYAN}2.${RESET} 关闭 BBR"
        echo -e "  ${CYAN}3.${RESET} 查看 BBR 状态"
        echo -e "  ${CYAN}0.${RESET} 返回主菜单"
        echo ""

        read -rp "  请选择 [0-3]: " bbr_choice
        case "$bbr_choice" in
            1) enable_bbr ;;
            2) disable_bbr ;;
            3) show_bbr_status ;;
            0) return ;;
            *) msg_err "无效选择" ;;
        esac
        press_any_key
    done
}

# ========================================
#  多用户管理菜单
# ========================================

user_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}  --- 多用户管理 ---${RESET}"
        echo -e "  ${CYAN}1.${RESET} 查看所有用户"
        echo -e "  ${CYAN}2.${RESET} 添加用户"
        echo -e "  ${CYAN}3.${RESET} 删除用户"
        echo -e "  ${CYAN}4.${RESET} 查看所有用户链接"
        echo -e "  ${CYAN}0.${RESET} 返回主菜单"
        echo ""

        read -rp "  请选择 [0-4]: " user_choice
        case "$user_choice" in
            1) list_users ;;
            2) add_user ;;
            3) remove_user ;;
            4) show_user_links ;;
            0) return ;;
            *) msg_err "无效选择" ;;
        esac
        press_any_key
    done
}

# ========================================
#  主菜单（循环）
# ========================================

show_menu() {
    clear
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║      Hysteria 2 一键管理脚本 v2.1       ║${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${RESET}"
    echo ""

    if check_installed; then
        echo -e "  Hysteria 2:  ${GREEN}已安装${RESET}"
        if systemctl is-active --quiet hysteria-server 2>/dev/null; then
            echo -e "  服务状态:    ${GREEN}运行中${RESET}"
        else
            echo -e "  服务状态:    ${RED}未运行${RESET}"
        fi

        local DOMAIN=""
        if [[ -f "$HY2_META" ]]; then
            source "$HY2_META"
            if [[ -n "$DOMAIN" ]]; then
                echo -e "  域名证书:    ${GREEN}${DOMAIN} (真证书)${RESET}"
            else
                echo -e "  域名证书:    ${YELLOW}自签证书${RESET}"
            fi
        fi

        if [[ -f "$HY2_HOPPING_CONF" ]]; then
            source "$HY2_HOPPING_CONF"
            echo -e "  端口跳跃:    ${GREEN}已启用 (${HOP_START}-${HOP_END})${RESET}"
        else
            echo -e "  端口跳跃:    ${YELLOW}未启用${RESET}"
        fi

        local user_count=0
        [[ -f "$HY2_USERS" ]] && user_count=$(wc -l < "$HY2_USERS")
        echo -e "  用户数量:    ${CYAN}${user_count}${RESET}"
    else
        echo -e "  Hysteria 2:  ${YELLOW}未安装${RESET}"
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "  BBR 加速:    ${GREEN}已启用${RESET}"
    else
        echo -e "  BBR 加速:    ${YELLOW}未启用 (${current_cc})${RESET}"
    fi

    echo ""
    echo -e "  ${CYAN} 1.${RESET} 安装 Hysteria 2"
    echo -e "  ${CYAN} 2.${RESET} 卸载 Hysteria 2"
    echo -e "  ${CYAN} 3.${RESET} 查看客户端配置/链接"
    echo -e "  ${CYAN} 4.${RESET} 多用户管理"
    echo -e "  ${CYAN} 5.${RESET} 域名证书管理"
    echo -e "  ${CYAN} 6.${RESET} 端口跳跃管理"
    echo -e "  ${CYAN} 7.${RESET} BBR 加速管理"
    echo -e "  ${CYAN} 8.${RESET} 重启服务"
    echo -e "  ${CYAN} 9.${RESET} 查看服务状态"
    echo -e "  ${CYAN}10.${RESET} 查看运行日志"
    echo -e "  ${CYAN}11.${RESET} 更新 Hysteria 2"
    echo -e "  ${CYAN} 0.${RESET} 退出脚本"
    echo ""

    read -rp "请选择 [0-11]: " choice
    case "$choice" in
        1)  do_install ;;
        2)  do_uninstall ;;
        3)  do_show_config ;;
        4)  user_menu ;;
        5)  do_domain_manage ;;
        6)  port_hopping_menu ;;
        7)  bbr_menu ;;
        8)  do_restart ;;
        9)  do_status ;;
        10) do_view_log ;;
        11) do_update ;;
        0)  echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
        *)  msg_err "无效选择" ;;
    esac
}

# ---------- 入口 ----------
check_root
install_shortcut

while true; do
    show_menu
    press_any_key
done