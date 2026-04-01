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
APP_VERSION="1.7.0"
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

require_nginx_installed() {
  if ! check_cmd nginx; then
    error "未检测到 Nginx，请先执行 [1) 安装 Nginx]。"
    return 1
  fi
}

run_safe() {
  # 统一命令执行入口，便于后续扩展日志
  "$@"
}

nginx_test() {
  # 所有配置变更后必须调用 nginx -t
  require_nginx_installed || return 1
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
    if ${SUDO} systemctl is-active --quiet nginx; then
      ${SUDO} systemctl reload nginx
      info "Nginx 已重载。"
    else
      ${SUDO} systemctl start nginx
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  else
    if ${SUDO} service nginx status >/dev/null 2>&1; then
      ${SUDO} service nginx reload
      info "Nginx 已重载。"
    else
      ${SUDO} service nginx start
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  fi
}

ensure_dirs() {
  ${SUDO} mkdir -p "$CONF_DIR"
  ${SUDO} mkdir -p "$SSL_DIR"
}

disable_default_conf_if_exists() {
  local default_conf="${CONF_DIR}/default.conf"
  local disabled_conf="${CONF_DIR}/default.conf.bak"

  if [[ -f "$default_conf" ]]; then
    ${SUDO} mv "$default_conf" "$disabled_conf"
    info "已自动停用默认配置：${default_conf} -> ${disabled_conf}"
  fi
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

  # 安装后自动停用可能引发冲突的默认配置
  disable_default_conf_if_exists
  reload_nginx_safe || true

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

  # 仅在检测到 nginx 官方源时，才按官网版本做对比，避免 Debian/Ubuntu 默认源误判
  local using_official_repo="0"
  if [[ -f /etc/apt/sources.list.d/nginx.list ]] || [[ -f /etc/yum.repos.d/nginx.repo ]]; then
    using_official_repo="1"
  fi

  if [[ "$using_official_repo" == "1" ]]; then
    latest_ver="$(nginx_latest_version_online)"
  else
    latest_ver=""
  fi

  note "本地版本：${local_ver}"
  if [[ "$using_official_repo" == "1" ]]; then
    if [[ -z "$latest_ver" ]]; then
      warn "无法获取官方最新版本，建议稍后重试。"
      return 1
    fi
    note "官方最新：${latest_ver}"

    if ! version_gt "$latest_ver" "$local_ver"; then
      info "当前已是最新版本，无需升级。"
      return 0
    fi
  else
    warn "当前未检测到 nginx 官方源（nginx.org），将按系统仓库执行升级检查。"
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

# ---------- 功能1：安装升级Nginx（合并入口） ----------
install_or_upgrade_nginx() {
  # 未安装时先安装；已安装时走智能升级逻辑
  if ! check_cmd nginx; then
    install_nginx_official
  else
    upgrade_nginx_smart
  fi
}

# ---------- 反向代理配置通用 ----------
valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_ipv4_host() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

valid_server_name_input() {
  local v="$1"
  valid_domain "$v" || valid_ipv4_host "$v"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_port_used_os() {
  local p="$1"
  ss -lnt "( sport = :${p} )" 2>/dev/null | awk 'NR>1{print}' | grep -q .
}

port_has_ssl_listener() {
  local p="$1"
  grep -R -E "listen[[:space:]]+${p}([[:space:]]|;).*ssl" "${CONF_DIR}"/*.conf >/dev/null 2>&1
}

conf_target_path() {
  local domain="$1"
  local listen_port="$2"
  echo "${CONF_DIR}/${domain}-${listen_port}.conf"
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

    # ACME HTTP-01 验证路径（证书申请/续期）
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

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

build_external_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local upstream_url="$3"
  local stream_mode="$4"
  local out="$5"
  local stream_block=""

  if [[ "$stream_mode" == "media" ]]; then
    stream_block=$(cat <<'BLOCK'
        # Stream 转发优化（Emby/Jellyfin 等）
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;
        client_max_body_size 0;
BLOCK
)
  fi

  cat > "$out" <<EOF
# managed_by=Nginx-X
# mode=external
# stream_mode=${stream_mode}
# domain=${domain}
# listen_port=${listen_port}
# upstream_url=${upstream_url}

server {
    listen ${listen_port};
    server_name ${domain};

    # ACME HTTP-01 验证路径（证书申请/续期）
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        proxy_pass ${upstream_url};
        proxy_http_version 1.1;

${stream_block}

        # 外部上游建议保留 SNI
        proxy_ssl_server_name on;

        proxy_set_header Host \$proxy_host;
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
  local test_output=""

  if [[ -f "$target_conf" ]]; then
    ${SUDO} cp -a "$target_conf" "$backup"
  fi

  ${SUDO} cp -a "$tmp_conf" "$target_conf"

  if test_output="$(${SUDO} nginx -t 2>&1)"; then
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
  echo "$test_output"
  return 1
}

add_reverse_proxy() {
  local domain listen_port backend_port target tmp auto_https
  local desired_port create_port force_enable_https="0"
  local desired_port create_port force_enable_https="0"

  require_nginx_installed || return 1

  read -rp "请输入域名或本机IP（如 example.com / 192.168.1.10）: " domain
  if ! valid_server_name_input "$domain"; then
    error "输入格式不合法，请输入域名或 IPv4 地址。"
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

  desired_port="$listen_port"
  create_port="$listen_port"

  if is_port_used_os "$listen_port"; then
    warn "监听端口 ${listen_port} 当前已被占用（Nginx 多站点场景通常可复用）。"
    if ! confirm "是否继续写入配置并交由 nginx -t 校验？"; then
      info "已取消添加配置。"
      return 0
    fi

    # 443 端口复用时，若当前域名还没有证书，直接写入 listen 443 往往会与现有 ssl 配置冲突。
    # 这里先引导落到 80，后续通过“自动申请证书+启用HTTPS”切到 443。
    if [[ "$listen_port" == "443" ]] && [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      warn "检测到 443 端口复用且当前域名证书不存在，已自动改为先使用 80 端口创建配置。"
      warn "后续可在同流程自动申请证书并启用 HTTPS。"
      create_port="80"
    fi

    # 非 443 的复用端口，如果当前端口已用于 HTTPS 监听，也要避免直接写入纯 HTTP 配置
    if port_has_ssl_listener "$desired_port"; then
      if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
        warn "检测到端口 ${desired_port} 已用于 HTTPS，且当前域名已有证书。"
        warn "将先写入临时 HTTP 配置，再自动切换为 ${desired_port} HTTPS。"
        create_port="80"
        force_enable_https="1"
      else
        warn "检测到端口 ${desired_port} 已用于 HTTPS，但当前域名暂无证书。"
        warn "已自动改为先使用 80 端口创建配置，后续申请证书后再切换 HTTPS。"
        create_port="80"
      fi
    fi
  fi

  target="$(conf_target_path "$domain" "$desired_port")"
  tmp="/tmp/nginxx-${domain}.conf"

  build_proxy_conf "$domain" "$create_port" "$backend_port" "$tmp"
  if apply_conf_with_rollback "$tmp" "$target"; then
    info "反向代理配置已生效：${target}"

    if [[ "$force_enable_https" == "1" ]]; then
      if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
        info "已完成：同端口 HTTPS 复用配置已自动启用。"
      else
        warn "自动切换 HTTPS 失败，请检查证书和配置。"
      fi
      rm -f "$tmp"
      return 0
    fi

    if valid_ipv4_host "$domain"; then
      warn "当前使用的是 IP，证书自动申请通常不适用，已跳过证书流程。"
      rm -f "$tmp"
      return 0
    fi

    if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      if confirm "检测到已有证书，是否立即启用证书（HTTPS 强制跳转）？"; then
        if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
          info "已完成：反向代理 + HTTPS 启用。"
        else
          warn "启用 HTTPS 失败，请检查配置后重试。"
        fi
      fi
    else
      if confirm "是否立即自动申请证书并启用 HTTPS（80 强制跳转 443）？"; then
        # 在当前界面直接设置/保存邮箱（若未设置）
        if ! ensure_email_interactive; then
          warn "邮箱未设置成功，已跳过自动证书流程。你可稍后在证书管理里设置。"
        else
          if issue_cert_for_domain "$domain"; then
            if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
              info "已完成：反向代理 + 自动证书 + 自动 HTTPS。"
            else
              warn "证书已申请成功，但启用 HTTPS 失败，请检查配置后重试。"
            fi
          else
            warn "自动证书申请失败，当前仅保留 HTTP 反向代理配置。"
          fi
        fi
      fi
    fi
  fi
  rm -f "$tmp"
}

add_external_url_proxy() {
  local domain listen_port upstream_url target tmp mode stream_mode
  local desired_port create_port force_enable_https="0"

  require_nginx_installed || return 1

  read -rp "请输入域名或本机IP（如 example.com / 192.168.1.10）: " domain
  if ! valid_server_name_input "$domain"; then
    error "输入格式不合法，请输入域名或 IPv4 地址。"
    return 1
  fi

  read -rp "请输入监听端口（如 80/8080）: " listen_port
  if ! valid_port "$listen_port"; then
    error "监听端口不合法。"
    return 1
  fi

  desired_port="$listen_port"
  create_port="$listen_port"

  read -rp "请输入外部上游 URL（http/https）: " upstream_url
  if [[ ! "$upstream_url" =~ ^https?:// ]]; then
    error "上游 URL 格式不合法，必须以 http:// 或 https:// 开头。"
    return 1
  fi

  echo "请选择外部反代模式："
  echo "1) 标准模式"
  echo "2) Stream 模式"
  read -rp "选择模式 [1/2]: " mode
  case "$mode" in
    2) stream_mode="media" ;;
    *) stream_mode="normal" ;;
  esac

  if is_port_used_os "$listen_port"; then
    warn "监听端口 ${listen_port} 当前已被占用（Nginx 多站点场景通常可复用）。"
    if ! confirm "是否继续写入配置并交由 nginx -t 校验？"; then
      info "已取消添加配置。"
      return 0
    fi

    if [[ "$listen_port" == "443" ]] && [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      warn "检测到 443 端口复用且当前域名证书不存在，已自动改为先使用 80 端口创建配置。"
      warn "后续可在同流程自动申请证书并启用 HTTPS。"
      create_port="80"
    fi

    if port_has_ssl_listener "$desired_port"; then
      if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
        warn "检测到端口 ${desired_port} 已用于 HTTPS，且当前域名已有证书。"
        warn "将先写入临时 HTTP 配置，再自动切换为 ${desired_port} HTTPS。"
        create_port="80"
        force_enable_https="1"
      else
        warn "检测到端口 ${desired_port} 已用于 HTTPS，但当前域名暂无证书。"
        warn "已自动改为先使用 80 端口创建配置，后续申请证书后再切换 HTTPS。"
        create_port="80"
      fi
    fi
  fi

  target="$(conf_target_path "$domain" "$desired_port")"
  tmp="/tmp/nginxx-external-${domain}.conf"

  build_external_proxy_conf "$domain" "$create_port" "$upstream_url" "$stream_mode" "$tmp"
  if apply_conf_with_rollback "$tmp" "$target"; then
    info "外部反代配置已生效：${target}"

    if [[ "$force_enable_https" == "1" ]]; then
      if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
        info "已完成：同端口 HTTPS 复用配置已自动启用。"
      else
        warn "自动切换 HTTPS 失败，请检查证书和配置。"
      fi
      rm -f "$tmp"
      return 0
    fi

    if valid_ipv4_host "$domain"; then
      warn "当前使用的是 IP，证书自动申请通常不适用，已跳过证书流程。"
      rm -f "$tmp"
      return 0
    fi

    if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      if confirm "检测到已有证书，是否立即启用证书（HTTPS 强制跳转）？"; then
        if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
          info "已完成：外部反代 + HTTPS 启用。"
        else
          warn "启用 HTTPS 失败，请检查配置后重试。"
        fi
      fi
    else
      if confirm "是否立即自动申请证书并启用 HTTPS（80 强制跳转 443）？"; then
        if ! ensure_email_interactive; then
          warn "邮箱未设置成功，已跳过自动证书流程。你可稍后在证书管理里设置。"
        else
          if issue_cert_for_domain "$domain"; then
            if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
              info "已完成：外部反代 + 自动证书 + 自动 HTTPS。"
            else
              warn "证书已申请成功，但启用 HTTPS 失败，请检查配置后重试。"
            fi
          else
            warn "自动证书申请失败，当前仅保留 HTTP 反代配置。"
          fi
        fi
      fi
    fi
  fi

  rm -f "$tmp"
}

# ---------- 功能4：配置列表管理 ----------
list_all_conf_files() {
  ls -1 "$CONF_DIR" 2>/dev/null | grep -E '\.conf(\..*)?$' || true
}

print_conf_list() {
  local i=1
  local -a enabled_files disabled_files

  # 二级列表：先显示已启用（.conf），再显示已停用（.bak/其他后缀）
  mapfile -t enabled_files < <(ls -1 "$CONF_DIR" 2>/dev/null | grep -E '\.conf$' | sort || true)
  mapfile -t disabled_files < <(ls -1 "$CONF_DIR" 2>/dev/null | grep -E '\.conf\..+$' | sort || true)

  FILES=("${enabled_files[@]}" "${disabled_files[@]}")

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

enable_conf() {
  local file src dst
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
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
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
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
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
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
  new_target="$(conf_target_path "$new_domain" "$new_listen")"
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
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
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

edit_conf_manual() {
  local file target backup editor_cmd
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi

  target="${CONF_DIR}/${file}"
  if [[ ! -f "$target" ]]; then
    error "配置文件不存在：${target}"
    return 1
  fi

  backup="${target}.editbak.$(date +%s)"
  ${SUDO} cp -a "$target" "$backup"

  # 优先使用环境变量 EDITOR，其次 nano，再次 vi
  if [[ -n "${EDITOR:-}" ]]; then
    editor_cmd="$EDITOR"
  elif check_cmd nano; then
    editor_cmd="nano"
  else
    editor_cmd="vi"
  fi

  ${SUDO} "$editor_cmd" "$target"

  if nginx_test; then
    reload_nginx_safe
    ${SUDO} rm -f "$backup"
    info "配置已编辑并生效：${file}"
  else
    ${SUDO} cp -a "$backup" "$target"
    ${SUDO} rm -f "$backup"
    error "编辑后配置校验失败，已回滚到修改前。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

config_file_action_menu() {
  local file="$1"

  while true; do
    clear
    echo "====== 配置操作：${file} ======"
    echo "1) 启用"
    echo "2) 停用"
    echo "3) 修改"
    echo "4) 编辑"
    echo "5) 删除"
    echo "0) 返回上一级"
    echo "============================"
    read -rp "请选择: " c

    case "$c" in
      1) enable_conf "$file"; pause; return 0 ;;
      2) disable_conf "$file"; pause; return 0 ;;
      3) modify_conf "$file"; pause; return 0 ;;
      4) edit_conf_manual "$file"; pause; return 0 ;;
      5) delete_conf "$file"; pause; return 0 ;;
      0) return 0 ;;
      *) warn "无效输入。"; pause ;;
    esac
  done
}

config_manage_menu() {
  require_nginx_installed || {
    pause
    return 1
  }

  while true; do
    clear
    echo "========== 配置列表管理 =========="
    if ! print_conf_list; then
      pause
      return 0
    fi
    echo
    echo "0) 返回上一级"
    echo "==============================="
    read -rp "请选择配置序号: " c

    if [[ "$c" == "0" ]]; then
      return 0
    fi

    if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > ${#FILES[@]} )); then
      warn "无效序号。"
      pause
      continue
    fi

    config_file_action_menu "${FILES[$((c-1))]}"
  done
}

config_entry_menu() {
  while true; do
    clear
    echo "========== 配置管理 =========="
    echo "1) 添加配置"
    echo "2) 外部反代"
    echo "3) 配置列表"
    echo "0) 返回上一级"
    echo "=============================="
    read -rp "请选择: " c

    case "$c" in
      1) add_reverse_proxy; pause ;;
      2) add_external_url_proxy; pause ;;
      3) config_manage_menu ;;
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

has_acme_cron_task() {
  crontab -l 2>/dev/null | grep -q 'acme.sh --cron'
}

disable_acme_cron() {
  if has_acme_cron_task; then
    crontab -l 2>/dev/null | grep -v 'acme.sh --cron' | crontab - || true
    info "已关闭自动续期任务。"
  else
    warn "当前未检测到自动续期任务。"
  fi
}

enable_acme_cron() {
  ensure_acme_cron
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

ensure_email_interactive() {
  # 若未设置邮箱，允许在当前界面直接录入并保存
  load_email
  if [[ -n "${ACME_EMAIL:-}" ]]; then
    return 0
  fi

  warn "当前未设置 Acme 邮箱。"
  read -rp "请输入邮箱（将保存到 ${EMAIL_CONF}）: " email
  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    error "邮箱格式不合法。"
    return 1
  fi

  save_email "$email"
  # shellcheck disable=SC2034
  ACME_EMAIL="$email"
}

ensure_acme_location_for_domain_conf() {
  # 为已存在的反代配置补齐 ACME 验证 location，避免申请证书时被反代到后端
  local domain="$1"
  local conf_file="${CONF_DIR}/${domain}.conf"
  local tmp_file

  [[ -f "$conf_file" ]] || return 0

  if grep -q '/\.well-known/acme-challenge/' "$conf_file"; then
    return 0
  fi

  tmp_file="/tmp/nginxx-acme-loc-${domain}.conf"
  awk '
    BEGIN{inserted=0}
    {
      if (inserted==0 && $0 ~ /^[[:space:]]*location \/ \{/ ) {
        print "    # ACME HTTP-01 验证路径（证书申请/续期）"
        print "    location ^~ /.well-known/acme-challenge/ {"
        print "        root /usr/share/nginx/html;"
        print "        default_type \"text/plain\";"
        print "        try_files $uri =404;"
        print "    }"
        print ""
        inserted=1
      }
      print $0
    }
  ' "$conf_file" > "$tmp_file"

  ${SUDO} cp -a "$tmp_file" "$conf_file"
  rm -f "$tmp_file"
}

ensure_http_challenge_server() {
  # 为“非80端口业务配置”补一个临时 80 验证入口，保证 HTTP-01 可达
  local domain="$1"
  local challenge_conf="${CONF_DIR}/.acme-challenge-${domain}.conf"

  if grep -R -E "server_name[[:space:]]+${domain}[[:space:]]*;" "${CONF_DIR}"/*.conf 2>/dev/null | grep -q "listen 80"; then
    # 已存在80监听同域名配置，无需额外创建
    echo ""
    return 0
  fi

  cat > /tmp/.acme-challenge-${domain}.conf <<EOF
server {
    listen 80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

  ${SUDO} cp -a /tmp/.acme-challenge-${domain}.conf "$challenge_conf"
  rm -f /tmp/.acme-challenge-${domain}.conf
  echo "$challenge_conf"
}

cleanup_http_challenge_server() {
  local challenge_conf="$1"
  [[ -z "$challenge_conf" ]] && return 0
  ${SUDO} rm -f "$challenge_conf" 2>/dev/null || true
}

issue_cert() {
  local domain challenge_conf
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

  ensure_acme_location_for_domain_conf "$domain"
  challenge_conf="$(ensure_http_challenge_server "$domain")"

  # 确保挑战配置已生效
  if ! reload_nginx_safe; then
    cleanup_http_challenge_server "$challenge_conf"
    error "证书申请前校验失败：Nginx 配置未生效。"
    return 1
  fi

  ensure_acme_installed || return 1

  note "开始为 ${domain} 申请证书（HTTP 验证）..."
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true

  local issue_output retry_after
  issue_output="$($HOME/.acme.sh/acme.sh --issue -d "$domain" --webroot /usr/share/nginx/html 2>&1)" || {
    echo "$issue_output"
    cleanup_http_challenge_server "$challenge_conf"
    reload_nginx_safe || true

    if echo "$issue_output" | grep -qi 'rateLimited\|too many certificates'; then
      retry_after="$(echo "$issue_output" | sed -n 's/.*retry after \([^:]*UTC\).*/\1/p' | head -n1)"
      error "证书申请失败：触发 Let\'s Encrypt 频率限制（429）。"
      [[ -n "$retry_after" ]] && warn "可重试时间（UTC）：$retry_after"
      warn "这是 CA 侧限制，不是你服务器或端口配置问题。"
    else
      error "证书申请失败，请确认域名解析和 80 端口可访问。"
    fi
    return 1
  }

  cleanup_http_challenge_server "$challenge_conf"
  reload_nginx_safe || true

  ${SUDO} mkdir -p "${SSL_DIR}/${domain}"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem"

  ensure_acme_cron
  info "证书申请并安装成功。"
}

issue_cert_for_domain() {
  # 参数：域名；用于“添加反向代理后自动申请证书”场景
  local domain="$1"
  local challenge_conf
  load_email

  if [[ -z "${ACME_EMAIL:-}" ]]; then
    error "未设置邮箱，无法自动申请证书。"
    return 1
  fi

  ensure_acme_location_for_domain_conf "$domain"
  challenge_conf="$(ensure_http_challenge_server "$domain")"

  # 确保挑战配置已生效
  if ! reload_nginx_safe; then
    cleanup_http_challenge_server "$challenge_conf"
    error "证书申请前校验失败：Nginx 配置未生效。"
    return 1
  fi

  ensure_acme_installed || return 1

  note "开始为 ${domain} 自动申请证书（HTTP 验证）..."
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true

  local issue_output retry_after
  issue_output="$($HOME/.acme.sh/acme.sh --issue -d "$domain" --webroot /usr/share/nginx/html 2>&1)" || {
    echo "$issue_output"
    cleanup_http_challenge_server "$challenge_conf"
    reload_nginx_safe || true

    if echo "$issue_output" | grep -qi 'rateLimited\|too many certificates'; then
      retry_after="$(echo "$issue_output" | sed -n 's/.*retry after \([^:]*UTC\).*/\1/p' | head -n1)"
      error "自动申请证书失败：触发 Let\'s Encrypt 频率限制（429）。"
      [[ -n "$retry_after" ]] && warn "可重试时间（UTC）：$retry_after"
      warn "这是 CA 侧限制，不是你服务器或端口配置问题。"
    else
      error "自动申请证书失败，请确认域名解析和 80 端口可访问。"
    fi
    return 1
  }

  cleanup_http_challenge_server "$challenge_conf"
  reload_nginx_safe || true

  ${SUDO} mkdir -p "${SSL_DIR}/${domain}"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem"

  ensure_acme_cron
  info "证书申请并安装成功。已开启自动续期任务。"
}

cert_list_action_menu() {
  local domain="$1"
  while true; do
    clear
    echo "====== 证书操作：${domain} ======"
    echo "1) 重新申请"
    echo "2) 启停续期"
    echo "3) 删除证书"
    echo "0) 返回上一级"
    echo "============================="
    read -rp "请选择: " c

    case "$c" in
      1)
        load_email
        if [[ -z "${ACME_EMAIL:-}" ]]; then
          if ! ensure_email_interactive; then
            error "邮箱未设置，无法重新申请。"
            pause
            return 1
          fi
        fi
        issue_cert_for_domain "$domain"
        pause
        return 0
        ;;
      2)
        if has_acme_cron_task; then
          if confirm "当前续期任务已开启，是否关闭？"; then
            disable_acme_cron
          fi
        else
          if confirm "当前续期任务未开启，是否开启？"; then
            enable_acme_cron
          fi
        fi
        pause
        return 0
        ;;
      3)
        if ! confirm "确认删除证书 ${domain} ?"; then
          info "已取消。"
          pause
          return 0
        fi

        if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
          "$HOME/.acme.sh/acme.sh" --remove -d "$domain" >/dev/null 2>&1 || true
        fi
        rm -rf "$HOME/.acme.sh/${domain}" "$HOME/.acme.sh/${domain}_ecc" 2>/dev/null || true
        ${SUDO} rm -rf "${SSL_DIR}/${domain}" 2>/dev/null || true
        info "证书已删除：${domain}"
        pause
        return 0
        ;;
      0) return 0 ;;
      *) warn "无效输入。"; pause ;;
    esac
  done
}

cert_list_menu() {
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    warn "未检测到 acme.sh，请先申请证书。"
    return 1
  fi

  local -a certs
  local line domain idx renew_status
  mapfile -t certs < <(
    "$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}'
  )

  if [[ ${#certs[@]} -eq 0 ]]; then
    warn "当前未发现已签发证书。"
    return 0
  fi

  while true; do
    clear
    echo "========== 证书列表 =========="
    if has_acme_cron_task; then
      renew_status="已开启"
    else
      renew_status="未开启"
    fi

    for i in "${!certs[@]}"; do
      echo "$((i+1))) ${certs[$i]}  [续期任务: ${renew_status}]"
    done
    echo "0) 返回上一级"
    echo "============================"
    read -rp "请输入证书编号: " idx

    if [[ "$idx" == "0" ]]; then
      return 0
    fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#certs[@]} )); then
      warn "无效编号。"
      pause
      continue
    fi

    domain="${certs[$((idx-1))]}"
    cert_list_action_menu "$domain"

    # 操作后刷新证书列表
    mapfile -t certs < <(
      "$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}'
    )
    if [[ ${#certs[@]} -eq 0 ]]; then
      warn "当前已无证书。"
      pause
      return 0
    fi
  done
}

enable_https_for_domain() {
  enable_https_from_config_list
}

extract_domain_from_conf() {
  local conf_file="$1"
  local d
  d="$(grep -E '^# domain=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# domain=//')"
  if [[ -z "$d" ]]; then
    # 回退：用文件名去掉 -端口.conf
    d="$(basename "$conf_file" | sed -E 's/-[0-9]+\.conf$//; s/\.conf$//')"
  fi
  echo "$d"
}

enable_https_from_config_list() {
  local -a confs
  local idx conf_file domain

  mapfile -t confs < <(ls -1 "${CONF_DIR}"/*.conf 2>/dev/null | sort || true)
  if [[ ${#confs[@]} -eq 0 ]]; then
    warn "未找到可启用 HTTPS 的配置文件。"
    return 1
  fi

  echo "请选择要启用证书的配置："
  for i in "${!confs[@]}"; do
    domain="$(extract_domain_from_conf "${confs[$i]}")"
    echo "  $((i+1))) $(basename "${confs[$i]}")  [域名: ${domain}]"
  done
  echo "  0) 返回上一级"
  read -rp "选择序号: " idx

  if [[ "$idx" == "0" ]]; then
    return 0
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#confs[@]} )); then
    error "无效序号。"
    return 1
  fi

  conf_file="${confs[$((idx-1))]}"
  domain="$(extract_domain_from_conf "$conf_file")"

  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    warn "检测到域名 ${domain} 还没有可用证书，准备自动申请。"

    if ! ensure_email_interactive; then
      error "邮箱未设置，无法自动申请证书。"
      return 1
    fi

    if ! issue_cert_for_domain "$domain"; then
      error "自动申请证书失败，无法继续启用 HTTPS。"
      return 1
    fi
  fi

  enable_https_for_conf_file "$domain" "$conf_file"
}

enable_https_for_domain_value() {
  # 参数：域名（若同域名存在多个配置，将提示选择）
  local domain="$1"
  local -a matches
  local idx conf_file

  mapfile -t matches < <(grep -l "^# domain=${domain}$" "${CONF_DIR}"/*.conf 2>/dev/null || true)

  if [[ ${#matches[@]} -eq 0 ]]; then
    error "未找到该域名对应配置：${domain}"
    return 1
  elif [[ ${#matches[@]} -eq 1 ]]; then
    conf_file="${matches[0]}"
  else
    echo "检测到多个同域名配置，请选择："
    for i in "${!matches[@]}"; do
      echo "  $((i+1))) $(basename "${matches[$i]}")"
    done
    read -rp "选择序号: " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#matches[@]} )); then
      error "无效序号。"
      return 1
    fi
    conf_file="${matches[$((idx-1))]}"
  fi

  enable_https_for_conf_file "$domain" "$conf_file"
}

enable_https_for_conf_file() {
  local domain="$1"
  local conf_file="$2"
  local force_port="${3:-}"
  local ssl_conf tmp listen_port redirect_suffix stream_mode stream_block

  if [[ ! -f "$conf_file" ]]; then
    error "配置文件不存在：${conf_file}"
    return 1
  fi

  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    error "未找到证书文件：${SSL_DIR}/${domain}/"
    return 1
  fi

  # 优先读取配置注释中的监听端口，缺失时回退 443
  listen_port="$(grep -E '^# listen_port=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# listen_port=//')"
  [[ -n "$force_port" ]] && listen_port="$force_port"
  [[ -z "$listen_port" ]] && listen_port="443"
  if [[ "$listen_port" == "443" ]]; then
    redirect_suffix=""
  else
    redirect_suffix=":${listen_port}"
  fi

  stream_mode="$(grep -E '^# stream_mode=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# stream_mode=//')"
  stream_block=""
  if [[ "$stream_mode" == "media" ]]; then
    stream_block=$(cat <<'BLOCK'
        # Stream 转发优化（Emby/Jellyfin 等）
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;
        client_max_body_size 0;
BLOCK
)
  fi

  tmp="/tmp/nginxx-https-${domain}.conf"

  # 生成 HTTPS 配置：继承原监听端口（支持非标端口，如 7777）
  cat > "$tmp" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# https_enabled=true
# listen_port=${listen_port}
# stream_mode=${stream_mode:-normal}

server {
    listen 80;
    server_name ${domain};

    # 保留 ACME 验证路径，避免被 301 跳转影响签发/续期
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    return 301 https://\$host${redirect_suffix}\$request_uri;
}

server {
    listen ${listen_port} ssl;
    http2 on;
    server_name ${domain};

    ssl_certificate     ${SSL_DIR}/${domain}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass __UPSTREAM_PLACEHOLDER__;
        proxy_http_version 1.1;

${stream_block}

__SSL_SERVER_NAME_LINE__

        proxy_set_header Host __HOST_HEADER__;
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

  # 复用原配置上游：优先读取注释元数据，避免同端口多域名场景误取到错误上游
  local existing_upstream host_header ssl_sni_line backend_port_meta upstream_url_meta
  upstream_url_meta="$(grep -E '^# upstream_url=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# upstream_url=//')"
  backend_port_meta="$(grep -E '^# backend_port=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# backend_port=//')"

  if [[ -n "$upstream_url_meta" ]]; then
    existing_upstream="$upstream_url_meta"
  elif [[ -n "$backend_port_meta" ]]; then
    existing_upstream="http://127.0.0.1:${backend_port_meta}"
  else
    existing_upstream="$(grep -Eo 'proxy_pass [^;]+' "$conf_file" | head -n1 | sed 's/^proxy_pass //')"
  fi

  [[ -z "$existing_upstream" ]] && existing_upstream="http://127.0.0.1:3000"

  # 外部上游（尤其 https）需要 SNI 与上游 Host，避免 502/握手失败
  if [[ "$existing_upstream" =~ ^https?://127\.0\.0\.1(:[0-9]+)?(/|$) ]]; then
    host_header='\$host'
    ssl_sni_line=''
  else
    host_header='\$proxy_host'
    if [[ "$existing_upstream" =~ ^https:// ]]; then
      ssl_sni_line='        proxy_ssl_server_name on;'
    else
      ssl_sni_line=''
    fi
  fi

  sed -i "s|proxy_pass __UPSTREAM_PLACEHOLDER__;|proxy_pass ${existing_upstream};|" "$tmp"
  sed -i "s|proxy_set_header Host __HOST_HEADER__;|proxy_set_header Host ${host_header};|" "$tmp"
  sed -i "s|__SSL_SERVER_NAME_LINE__|${ssl_sni_line}|" "$tmp"

  if apply_conf_with_rollback "$tmp" "$conf_file"; then
    info "HTTPS 已启用，且已配置 80 -> ${listen_port} 强制跳转。"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

cert_menu() {
  require_nginx_installed || {
    pause
    return 1
  }

  while true; do
    clear
    echo "========== 证书管理（acme.sh） =========="
    echo "1) 设置邮箱"
    echo "2) 申请证书"
    echo "3) 证书列表"
    echo "4) 启用证书（HTTPS 强制跳转）"
    echo "0) 返回上一级"
    echo "========================================"
    read -rp "请选择: " c

    case "$c" in
      1) set_acme_email; pause ;;
      2) issue_cert; pause ;;
      3) cert_list_menu ;;
      4) enable_https_for_domain ;;
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
  require_nginx_installed || return 1

  ensure_status_endpoint || true

  local prev_requests=0 prev_rx=0 prev_tx=0 initialized=0

  while true; do
    local stat active reading writing waiting accepts handled requests qps
    local cpu mem workers master_pid start_time rx tx rx_rate tx_rate

    stat="$(curl -fsS http://127.0.0.1:8088/nginx_status 2>/dev/null || true)"

    active="N/A"
    reading="N/A"
    writing="N/A"
    waiting="N/A"
    accepts="N/A"
    handled="N/A"
    requests="0"
    qps="0"

    if [[ -n "$stat" ]]; then
      active="$(echo "$stat" | awk '/Active connections/ {print $3}')"
      accepts="$(echo "$stat" | awk 'NR==3 {print $1}')"
      handled="$(echo "$stat" | awk 'NR==3 {print $2}')"
      requests="$(echo "$stat" | awk 'NR==3 {print $3}')"
      reading="$(echo "$stat" | awk 'NR==4 {print $2}')"
      writing="$(echo "$stat" | awk 'NR==4 {print $4}')"
      waiting="$(echo "$stat" | awk 'NR==4 {print $6}')"
    fi

    if [[ $initialized -eq 1 ]]; then
      qps=$((requests - prev_requests))
      (( qps < 0 )) && qps=0
    fi

    cpu="$(ps -C nginx -o %cpu= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.0"; else printf "%.1f", s}')"
    mem="$(ps -C nginx -o %mem= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.0"; else printf "%.1f", s}')"

    workers="$(pgrep -fc 'nginx: worker process' 2>/dev/null || echo 0)"
    master_pid="$(pgrep -xo nginx 2>/dev/null || true)"
    if [[ -n "$master_pid" ]]; then
      start_time="$(ps -p "$master_pid" -o lstart= 2>/dev/null | awk '{$1=$1;print}')"
    else
      start_time="N/A"
    fi

    rx="$(awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$3} END{print s+0}' /proc/net/dev 2>/dev/null)"
    tx="$(awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$11} END{print s+0}' /proc/net/dev 2>/dev/null)"

    if [[ $initialized -eq 1 ]]; then
      rx_rate="$(awk -v d=$((rx-prev_rx)) 'BEGIN{if(d<0)d=0; printf "%.1f", d/1024/1024}')"
      tx_rate="$(awk -v d=$((tx-prev_tx)) 'BEGIN{if(d<0)d=0; printf "%.1f", d/1024/1024}')"
    else
      rx_rate="0.0"
      tx_rate="0.0"
      initialized=1
    fi

    prev_requests="$requests"
    prev_rx="$rx"
    prev_tx="$tx"

    clear
    cat <<EOF
==============================
 Nginx 实时状态
==============================

连接状态
Active: ${active}
Reading: ${reading}
Writing: ${writing}
Waiting: ${waiting}

请求统计
Accepts: ${accepts}
Handled: ${handled}
Requests: ${requests}
QPS: ${qps} req/s

系统资源
CPU: ${cpu} %
MEM: ${mem} %

Nginx信息
Worker进程: ${workers}
启动时间: ${start_time}

网络流量
RX: ${rx_rate} MB/s
TX: ${tx_rate} MB/s

==============================
按回车返回（每5秒自动刷新）
EOF

    # 每5秒刷新；检测到任意键输入则退出
    if read -r -s -n 1 -t 5 _key; then
      break
    fi
  done
}

# ---------- 功能7：卸载 ----------
uninstall_script_only() {
  note "将执行：卸载 nx 快捷命令、删除脚本目录下运行文件。"
  if ! confirm "确认继续卸载本脚本？"; then
    info "已取消。"
    return 0
  fi

  # 1) 清理快捷启动命令
  if [[ -f /usr/local/bin/nx ]]; then
    ${SUDO} rm -f /usr/local/bin/nx
    info "已移除：/usr/local/bin/nx"
  else
    warn "未发现 /usr/local/bin/nx，跳过。"
  fi

  # 2) 清理脚本目录下运行状态文件
  rm -f "${SCRIPT_DIR}/.email.conf" 2>/dev/null || true

  # 3) 彻底删除脚本目录（延迟执行，避免当前进程占用）
  local dir_to_remove
  dir_to_remove="$(realpath "$SCRIPT_DIR")"
  if [[ -n "$dir_to_remove" && "$dir_to_remove" != "/" ]]; then
    nohup bash -c "sleep 1; rm -rf '$dir_to_remove'" >/dev/null 2>&1 &
    info "已安排删除脚本目录：${dir_to_remove}"
  fi

  info "本脚本卸载完成。"
  exit 0
}

uninstall_nginx_only() {
  local pkg
  pkg="$(detect_pkg_mgr)"

  warn "将彻底卸载 Nginx 并清空相关配置/日志目录。"
  if ! confirm "确认继续卸载 Nginx？"; then
    info "已取消。"
    return 0
  fi

  if check_cmd systemctl; then
    ${SUDO} systemctl stop nginx 2>/dev/null || true
    ${SUDO} systemctl disable nginx 2>/dev/null || true
  fi

  case "$pkg" in
    apt)
      ${SUDO} apt-get purge -y 'nginx*' || true
      ${SUDO} apt-get autoremove -y || true
      ${SUDO} rm -f /etc/apt/sources.list.d/nginx.list || true
      ;;
    dnf|yum)
      ${SUDO} "$pkg" remove -y 'nginx*' || true
      ${SUDO} rm -f /etc/yum.repos.d/nginx.repo || true
      ;;
    *)
      warn "未知包管理器，尝试仅清理目录。"
      ;;
  esac

  ${SUDO} rm -rf /etc/nginx /var/log/nginx /var/cache/nginx /usr/share/nginx 2>/dev/null || true
  info "Nginx 及其配置已清理完成。"
}

uninstall_acme_only() {
  warn "将彻底卸载 acme.sh 并清空证书/配置及邮箱信息。"
  if ! confirm "确认继续卸载 Acme？"; then
    info "已取消。"
    return 0
  fi

  # 1) 删除 acme.sh 安装目录及证书目录
  rm -rf "$HOME/.acme.sh" 2>/dev/null || true
  ${SUDO} rm -rf "$SSL_DIR" 2>/dev/null || true

  # 2) 删除 crontab 中 acme 自动续期任务
  if crontab -l >/tmp/.nginxx_cron 2>/dev/null; then
    grep -v 'acme.sh --cron' /tmp/.nginxx_cron | crontab - || true
    rm -f /tmp/.nginxx_cron
  fi

  # 3) 清理邮箱持久化信息
  rm -f "$EMAIL_CONF" 2>/dev/null || true

  info "Acme 及相关配置已清理完成。"
}

uninstall_all() {
  warn "将执行全部卸载：本脚本 + Nginx（含配置清理）。"
  if ! confirm "确认继续全部卸载？"; then
    info "已取消。"
    return 0
  fi

  uninstall_nginx_only
  uninstall_acme_only
  uninstall_script_only
}

uninstall_menu() {
  while true; do
    clear
    echo "========== 卸载 =========="
    echo "1) 卸载脚本（彻底卸载本脚本并清理）"
    echo "2) 卸载 Nginx（彻底卸载并清空 Nginx 配置）"
    echo "3) 卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）"
    echo "4) 全部卸载（脚本 + Nginx + Acme 全清理）"
    echo "0) 返回上一级"
    echo "=========================="
    read -rp "请选择: " c

    case "$c" in
      1) uninstall_script_only; pause ;;
      2) uninstall_nginx_only; pause ;;
      3) uninstall_acme_only; pause ;;
      4) uninstall_all; pause ;;
      0) return 0 ;;
      *) warn "无效输入。"; pause ;;
    esac
  done
}

# ---------- 菜单 ----------
banner() {
  clear
  echo "${APP_NAME} v${APP_VERSION}"
  echo "========================================"
}

main_menu() {
  echo "1) 安装升级Nginx"
  echo "2) 配置管理"
  echo "3) 证书管理"
  echo "4) 实时信息"
  echo "5) 卸载"
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
      1) install_or_upgrade_nginx; pause ;;
      2) config_entry_menu ;;
      3) cert_menu ;;
      4) show_nginx_realtime_status ;;
      5) uninstall_menu ;;
      0) info "已退出 ${APP_NAME}。"; exit 0 ;;
      *) warn "无效输入，请输入菜单编号。"; pause ;;
    esac
  done
}

main
  desired_port="$listen_port"
  create_port="$listen_port"
