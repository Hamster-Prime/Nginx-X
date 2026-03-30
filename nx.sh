#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Nginx-X: Nginx 自动化管理脚本
# 支持：Ubuntu / Debian / CentOS
# ==============================

# ---------- ANSI 颜色 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- 全局变量 ----------
APP_NAME="Nginx-X"
APP_VERSION="0.2.0"
CONF_DIR="/etc/nginx/conf.d"
SSL_DIR="/etc/nginx/ssl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMAIL_CONF="${SCRIPT_DIR}/.email.conf"

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

# ---------- 输出函数 ----------
info() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }
note() { echo -e "${BLUE}[信息]${NC} $*"; }

pause() {
  echo
  read -rp "按回车继续..." _
}

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- 基础能力 ----------
check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_safe() {
  # 统一命令执行入口，便于后续扩展日志
  "$@"
}

nginx_test() {
  # 所有配置变更后必须调用 nginx -t
  ${SUDO} nginx -t >/dev/null 2>&1
}

reload_nginx_safe() {
  # reload 前必须先测试配置
  if ! nginx_test; then
    error "配置校验失败，已拦截 reload。"
    ${SUDO} nginx -t || true
    return 1
  fi

  if check_cmd systemctl; then
    ${SUDO} systemctl reload nginx
  else
    ${SUDO} service nginx reload
  fi
  info "Nginx 已重载。"
}

ensure_dirs() {
  ${SUDO} mkdir -p "$CONF_DIR"
  ${SUDO} mkdir -p "$SSL_DIR"
}

detect_os_id() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

detect_pkg_mgr() {
  if check_cmd apt-get; then
    echo "apt"
  elif check_cmd dnf; then
    echo "dnf"
  elif check_cmd yum; then
    echo "yum"
  else
    echo "unknown"
  fi
}

nginx_local_version() {
  if ! check_cmd nginx; then
    echo ""
    return
  fi
  nginx -v 2>&1 | sed -E 's#^nginx version: nginx/##'
}

nginx_latest_version_online() {
  # 使用 Nginx 官网下载页获取最新稳定版版本号
  local latest
  latest="$(curl -fsSL https://nginx.org/en/download.html | grep -Eo 'nginx-[0-9]+\.[0-9]+\.[0-9]+' | sed 's/nginx-//' | sort -V | tail -n1 || true)"
  echo "$latest"
}

version_gt() {
  # 若 $1 > $2 返回 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}

# ---------- 功能1：安装与初始化 ----------
install_nginx_official() {
  local os_id pkg
  os_id="$(detect_os_id)"
  pkg="$(detect_pkg_mgr)"

  ensure_dirs

  if check_cmd nginx; then
    warn "检测到 Nginx 已安装，跳过安装步骤。"
    info "已确保目录存在：${SSL_DIR}"
    return 0
  fi

  note "开始安装依赖：curl wget socat cron"

  case "$pkg" in
    apt)
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y curl wget socat cron gpg lsb-release ca-certificates

      note "配置 Nginx 官方 stable 源..."
      curl -fsSL https://nginx.org/keys/nginx_signing.key | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/$(. /etc/os-release; echo ${ID}) $(lsb_release -cs) nginx" | ${SUDO} tee /etc/apt/sources.list.d/nginx.list >/dev/null
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y nginx
      ;;
    dnf|yum)
      if [[ "$os_id" != "centos" && "$os_id" != "rhel" && "$os_id" != "rocky" && "$os_id" != "almalinux" ]]; then
        warn "当前系统 ID=$os_id，仍尝试按 RHEL 系列方式安装。"
      fi
      ${SUDO} "$pkg" install -y epel-release || true
      ${SUDO} "$pkg" install -y curl wget socat cronie

      note "配置 Nginx 官方 stable 源..."
      cat <<'REPO' | ${SUDO} tee /etc/yum.repos.d/nginx.repo >/dev/null
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
REPO
      ${SUDO} "$pkg" makecache -y || true
      ${SUDO} "$pkg" install -y nginx
      ;;
    *)
      error "不支持的包管理器，无法自动安装。"
      return 1
      ;;
  esac

  if check_cmd systemctl; then
    ${SUDO} systemctl enable --now nginx || true
    ${SUDO} systemctl enable --now cron 2>/dev/null || ${SUDO} systemctl enable --now crond 2>/dev/null || true
  fi

  info "Nginx 与依赖安装完成。"
  info "已创建证书目录：${SSL_DIR}"
}

# ---------- 功能2：智能版本升级 ----------
upgrade_nginx_smart() {
  if ! check_cmd nginx; then
    warn "Nginx 尚未安装，请先执行安装。"
    return 1
  fi

  local local_ver latest_ver backup_dir pkg
  local_ver="$(nginx_local_version)"
  latest_ver="$(nginx_latest_version_online)"

  if [[ -z "$latest_ver" ]]; then
    warn "无法获取官方最新版本，建议稍后重试。"
    return 1
  fi

  note "本地版本：${local_ver}"
  note "官方最新：${latest_ver}"

  if ! version_gt "$latest_ver" "$local_ver"; then
    info "当前已是最新版本，无需升级。"
    return 0
  fi

  backup_dir="/etc/nginx-backup-$(date +%F-%H%M%S)"
  note "检测到可升级版本，先备份配置到：${backup_dir}"
  ${SUDO} cp -a /etc/nginx "$backup_dir"

  pkg="$(detect_pkg_mgr)"
  case "$pkg" in
    apt)
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y --only-upgrade nginx
      ;;
    dnf|yum)
      ${SUDO} "$pkg" update -y nginx
      ;;
    *)
      error "不支持的包管理器，无法自动升级。"
      return 1
      ;;
  esac

  if nginx_test; then
    reload_nginx_safe
    info "Nginx 已平滑升级完成。"
  else
    error "升级后配置校验失败，请检查。备份目录：${backup_dir}"
    ${SUDO} nginx -t || true
    return 1
  fi
}

# ---------- 反向代理配置通用 ----------
valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_port_used_os() {
  local p="$1"
  ss -lnt "( sport = :${p} )" 2>/dev/null | awk 'NR>1{print}' | grep -q .
}

build_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local backend_port="$3"
  local out="$4"

  cat > "$out" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# listen_port=${listen_port}
# backend_port=${backend_port}

server {
    listen ${listen_port};
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${backend_port};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
}

apply_conf_with_rollback() {
  # 参数：临时文件、目标文件
  local tmp_conf="$1"
  local target_conf="$2"
  local backup="${target_conf}.rollback.$(date +%s)"

  if [[ -f "$target_conf" ]]; then
    ${SUDO} cp -a "$target_conf" "$backup"
  fi

  ${SUDO} cp -a "$tmp_conf" "$target_conf"

  if nginx_test; then
    reload_nginx_safe
    [[ -f "$backup" ]] && ${SUDO} rm -f "$backup"
    return 0
  fi

  # 回滚
  if [[ -f "$backup" ]]; then
    ${SUDO} cp -a "$backup" "$target_conf"
    ${SUDO} rm -f "$backup"
  else
    ${SUDO} rm -f "$target_conf"
  fi
  error "配置测试失败，已自动撤销本次修改。"
  ${SUDO} nginx -t || true
  return 1
}

add_reverse_proxy() {
  local domain listen_port backend_port target tmp

  read -rp "请输入域名（如 example.com）: " domain
  if ! valid_domain "$domain"; then
    error "域名格式不合法。"
    return 1
  fi

  read -rp "请输入监听端口（如 80/8080）: " listen_port
  if ! valid_port "$listen_port"; then
    error "监听端口不合法。"
    return 1
  fi

  read -rp "请输入后端/容器端口（如 3000）: " backend_port
  if ! valid_port "$backend_port"; then
    error "后端端口不合法。"
    return 1
  fi

  if is_port_used_os "$listen_port"; then
    error "监听端口 ${listen_port} 已被占用，无法继续。"
    return 1
  fi

  target="${CONF_DIR}/${domain}.conf"
  tmp="/tmp/nginxx-${domain}.conf"

  build_proxy_conf "$domain" "$listen_port" "$backend_port" "$tmp"
  if apply_conf_with_rollback "$tmp" "$target"; then
    info "反向代理配置已生效：${target}"
  fi
  rm -f "$tmp"
}

# ---------- 功能4：配置列表管理 ----------
list_all_conf_files() {
  ls -1 "$CONF_DIR" 2>/dev/null | grep -E '\.conf(\..*)?$' || true
}

print_conf_list() {
  local i=1
  mapfile -t FILES < <(list_all_conf_files)

  if [[ ${#FILES[@]} -eq 0 ]]; then
    warn "当前没有可管理的配置文件。"
    return 1
  fi

  echo "可管理配置列表："
  for f in "${FILES[@]}"; do
    if [[ "$f" =~ \.conf$ ]]; then
      echo "  ${i}) ${f}  [已启用]"
    else
      echo "  ${i}) ${f}  [已停用]"
    fi
    ((i++))
  done
  return 0
}

pick_conf_file() {
  local idx
  if ! print_conf_list; then
    return 1
  fi
  read -rp "选择文件序号: " idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#FILES[@]} )); then
    error "无效序号。"
    return 1
  fi
  echo "${FILES[$((idx-1))]}"
}

enable_conf() {
  local file src dst
  file="$(pick_conf_file)" || return 1
  src="${CONF_DIR}/${file}"

  if [[ "$file" =~ \.conf$ ]]; then
    warn "该配置已是启用状态。"
    return 0
  fi

  dst="${src%%.bak}"
  ${SUDO} mv "$src" "$dst"

  if nginx_test; then
    reload_nginx_safe
    info "已启用：$(basename "$dst")"
  else
    ${SUDO} mv "$dst" "$src"
    error "启用后配置校验失败，已回滚。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

disable_conf() {
  local file src dst
  file="$(pick_conf_file)" || return 1
  src="${CONF_DIR}/${file}"

  if [[ ! "$file" =~ \.conf$ ]]; then
    warn "该配置已是停用状态。"
    return 0
  fi

  dst="${src}.bak"
  ${SUDO} mv "$src" "$dst"

  if nginx_test; then
    reload_nginx_safe
    info "已停用：$(basename "$dst")"
  else
    ${SUDO} mv "$dst" "$src"
    error "停用后配置校验失败，已回滚。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

modify_conf() {
  local file src new_domain new_listen new_backend tmp new_target
  file="$(pick_conf_file)" || return 1
  src="${CONF_DIR}/${file}"

  read -rp "新的域名: " new_domain
  if ! valid_domain "$new_domain"; then
    error "域名格式不合法。"
    return 1
  fi

  read -rp "新的监听端口: " new_listen
  if ! valid_port "$new_listen"; then
    error "监听端口不合法。"
    return 1
  fi

  read -rp "新的后端端口: " new_backend
  if ! valid_port "$new_backend"; then
    error "后端端口不合法。"
    return 1
  fi

  # 监听端口占用检查（允许当前 nginx 使用旧配置的场景较复杂，这里采取严格策略）
  if is_port_used_os "$new_listen"; then
    warn "监听端口 ${new_listen} 当前被占用，可能导致冲突。"
    if ! confirm "仍继续尝试修改？"; then
      info "已取消修改。"
      return 0
    fi
  fi

  tmp="/tmp/nginxx-mod-${new_domain}.conf"
  build_proxy_conf "$new_domain" "$new_listen" "$new_backend" "$tmp"

  # 修改后默认写入 .conf；也可选择立即停用
  new_target="${CONF_DIR}/${new_domain}.conf"
  if apply_conf_with_rollback "$tmp" "$new_target"; then
    # 若原文件名和新文件名不同，且原文件仍存在则清理
    if [[ "$src" != "$new_target" && -f "$src" ]]; then
      ${SUDO} rm -f "$src"
    fi

    if confirm "是否立即停用该配置？"; then
      ${SUDO} mv "$new_target" "${new_target}.bak"
      if nginx_test; then
        reload_nginx_safe
        info "配置已修改并停用。"
      else
        ${SUDO} mv "${new_target}.bak" "$new_target"
        error "停用失败，已恢复启用状态。"
        ${SUDO} nginx -t || true
      fi
    else
      info "配置已修改并保持启用。"
    fi
  fi

  rm -f "$tmp"
}

delete_conf() {
  local file target
  file="$(pick_conf_file)" || return 1
  target="${CONF_DIR}/${file}"

  if ! confirm "确认永久删除 ${file} ?"; then
    info "已取消删除。"
    return 0
  fi

  # 先删，再校验，失败则无法自动恢复（所以先备份）
  local backup="${target}.delbak.$(date +%s)"
  ${SUDO} cp -a "$target" "$backup"
  ${SUDO} rm -f "$target"

  if nginx_test; then
    reload_nginx_safe
    ${SUDO} rm -f "$backup"
    info "已删除：${file}"
  else
    ${SUDO} cp -a "$backup" "$target"
    ${SUDO} rm -f "$backup"
    error "删除后配置失败，已恢复文件。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

config_manage_menu() {
  while true; do
    clear
    echo "========== 配置列表管理 =========="
    print_conf_list || true
    echo
    echo "1) 启用"
    echo "2) 停用"
    echo "3) 修改"
    echo "4) 删除"
    echo "0) 返回上一级"
    echo "==============================="
    read -rp "请选择: " c

    case "$c" in
      1) enable_conf; pause ;;
      2) disable_conf; pause ;;
      3) modify_conf; pause ;;
      4) delete_conf; pause ;;
      0) return 0 ;;
      *) warn "无效输入。"; pause ;;
    esac
  done
}

# ---------- 功能5：证书管理（acme.sh） ----------
load_email() {
  if [[ -f "$EMAIL_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$EMAIL_CONF"
  fi
}

save_email() {
  local email="$1"
  cat > "$EMAIL_CONF" <<EOF
ACME_EMAIL="${email}"
EOF
  info "邮箱已保存到：${EMAIL_CONF}"
}

ensure_acme_installed() {
  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    return 0
  fi
  note "未检测到 acme.sh，开始安装..."
  curl https://get.acme.sh | sh
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    error "acme.sh 安装失败。"
    return 1
  fi
  info "acme.sh 安装成功。"
}

ensure_acme_cron() {
  local cron_line
  cron_line="0 3 1 */2 * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh >/dev/null"

  if crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
    info "已检测到 acme.sh 自动续期任务。"
    return 0
  fi

  warn "未检测到 acme.sh 自动续期任务。"
  if confirm "是否一键添加自动续期任务（约每60天执行）？"; then
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    info "已开启自动续期任务。"
  else
    warn "你选择了不添加自动续期任务，后续需手动续期。"
  fi
}

set_acme_email() {
  local email
  read -rp "请输入证书通知邮箱: " email
  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    error "邮箱格式不合法。"
    return 1
  fi
  save_email "$email"
}

issue_cert() {
  local domain
  load_email

  if [[ -z "${ACME_EMAIL:-}" ]]; then
    error "未设置邮箱，请先执行“设置邮箱”。"
    return 1
  fi

  read -rp "请输入要申请证书的域名: " domain
  if ! valid_domain "$domain"; then
    error "域名格式不合法。"
    return 1
  fi

  ensure_acme_installed || return 1

  note "开始为 ${domain} 申请证书（HTTP 验证）..."
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true

  if ! "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --webroot /usr/share/nginx/html; then
    error "证书申请失败，请确认域名解析和 80 端口可访问。"
    return 1
  fi

  ${SUDO} mkdir -p "${SSL_DIR}/${domain}"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem"

  ensure_acme_cron
  info "证书申请并安装成功。"
}

cert_list_and_renew_check() {
  local base="$HOME/.acme.sh"
  if [[ ! -d "$base" ]]; then
    warn "未发现任何证书目录。"
  else
    echo "证书目录列表："
    find "$base" -maxdepth 1 -type d -name '*.com*' -o -name '*.cn*' 2>/dev/null | sed 's#^.*/##' || true
  fi
  ensure_acme_cron
}

enable_https_for_domain() {
  local domain conf_file ssl_conf tmp
  read -rp "请输入要启用 HTTPS 的域名（对应 conf 文件名）: " domain
  conf_file="${CONF_DIR}/${domain}.conf"

  if [[ ! -f "$conf_file" ]]; then
    error "配置文件不存在：${conf_file}"
    return 1
  fi

  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    error "未找到证书文件：${SSL_DIR}/${domain}/"
    return 1
  fi

  tmp="/tmp/nginxx-https-${domain}.conf"

  # 直接生成强制跳转 HTTPS 的配置（80 -> 443）
  cat > "$tmp" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# https_enabled=true

server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${SSL_DIR}/${domain}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  # 若原配置里能找到 proxy_pass 端口，自动复用
  local existing_backend
  existing_backend="$(grep -Eo 'proxy_pass http://127\.0\.0\.1:[0-9]+' "$conf_file" | head -n1 | awk -F: '{print $NF}' || true)"
  if [[ -n "$existing_backend" ]]; then
    sed -i "s/proxy_pass http:\/\/127.0.0.1:3000;/proxy_pass http:\/\/127.0.0.1:${existing_backend};/" "$tmp"
  fi

  if apply_conf_with_rollback "$tmp" "$conf_file"; then
    info "HTTPS 已启用，且已配置 80 -> 443 强制跳转。"
  fi

  rm -f "$tmp"
}

cert_menu() {
  while true; do
    clear
    echo "========== 证书管理（acme.sh） =========="
    echo "1) 设置邮箱"
    echo "2) 申请证书"
    echo "3) 证书列表与续期检查"
    echo "4) 启用证书（HTTPS 强制跳转）"
    echo "0) 返回上一级"
    echo "========================================"
    read -rp "请选择: " c

    case "$c" in
      1) set_acme_email; pause ;;
      2) issue_cert; pause ;;
      3) cert_list_and_renew_check; pause ;;
      4) enable_https_for_domain; pause ;;
      0) return 0 ;;
      *) warn "无效输入。"; pause ;;
    esac
  done
}

# ---------- 功能6：流量统计与状态 ----------
ensure_status_endpoint() {
  local status_conf="${CONF_DIR}/nginx_status.conf"
  if [[ -f "$status_conf" ]]; then
    return 0
  fi

  cat > /tmp/nginxx-status.conf <<'EOF'
server {
    listen 127.0.0.1:8088;
    server_name 127.0.0.1;

    location /nginx_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

  apply_conf_with_rollback /tmp/nginxx-status.conf "$status_conf" || return 1
  rm -f /tmp/nginxx-status.conf
}

show_nginx_realtime_status() {
  ensure_status_endpoint || true

  local stat active rw waiting
  stat="$(curl -fsS http://127.0.0.1:8088/nginx_status 2>/dev/null || true)"

  if [[ -z "$stat" ]]; then
    warn "未能读取 nginx_status，可能未启用或端口受限。"
  else
    active="$(echo "$stat" | awk '/Active connections/ {print $3}')"
    rw="$(echo "$stat" | awk 'NR==4 {print $1" "$2" "$3}')"
    reading="$(echo "$rw" | awk '{print $1}')"
    writing="$(echo "$rw" | awk '{print $2}')"
    waiting="$(echo "$rw" | awk '{print $3}')"

    echo "Nginx 连接状态："
    echo "  Active:  ${active:-N/A}"
    echo "  Reading: ${reading:-N/A}"
    echo "  Writing: ${writing:-N/A}"
    echo "  Waiting: ${waiting:-N/A}"
  fi

  # 汇总 nginx 进程 CPU/内存
  local cpu mem
  cpu="$(ps -C nginx -o %cpu= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.00"; else printf "%.2f", s}')"
  mem="$(ps -C nginx -o %mem= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.00"; else printf "%.2f", s}')"

  echo
  echo "Nginx 进程资源占用："
  echo "  CPU: ${cpu}%"
  echo "  MEM: ${mem}%"
}

# ---------- 菜单 ----------
banner() {
  clear
  cat <<'EOF'
 _   _       _             __   __
| \ | | __ _(_)_ __  __  __\ \ / /
|  \| |/ _` | | '_ \ \ \/ / \ V /
| |\  | (_| | | | | | >  <   | |
|_| \_|\__, |_|_| |_|/_/\_\  |_|
       |___/
EOF
  echo "${APP_NAME} v${APP_VERSION}"
  echo "========================================"
}

main_menu() {
  echo "1) 安装 Nginx 与环境初始化"
  echo "2) 智能版本升级"
  echo "3) 添加反向代理配置"
  echo "4) 配置列表管理"
  echo "5) 证书管理（acme.sh）"
  echo "6) 流量统计与状态检查"
  echo "0) 退出"
  echo "========================================"
}

main() {
  ensure_dirs

  while true; do
    banner
    main_menu
    read -rp "请选择功能: " choice

    case "$choice" in
      1) install_nginx_official; pause ;;
      2) upgrade_nginx_smart; pause ;;
      3) add_reverse_proxy; pause ;;
      4) config_manage_menu ;;
      5) cert_menu ;;
      6) show_nginx_realtime_status; pause ;;
      0) info "已退出 ${APP_NAME}。"; exit 0 ;;
      *) warn "无效输入，请输入菜单编号。"; pause ;;
    esac
  done
}

main
