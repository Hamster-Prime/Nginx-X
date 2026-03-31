#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Xiuyixx/Nginx-X.git"
INSTALL_DIR="/opt/Nginx-X"
TARGET_BIN="/usr/local/bin/nx"
NO_RUN="0"

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  echo "[INFO] 未检测到 git，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    ${SUDO} dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    ${SUDO} yum install -y git
  else
    echo "[ERROR] 无法自动安装 git，请手动安装后重试。"
    exit 1
  fi
}

install_local() {
  local script_dir source_script
  script_dir="$(get_script_dir)"
  source_script="${script_dir}/nx.sh"

  if [[ ! -f "$source_script" ]]; then
    echo "[ERROR] nx.sh not found in ${script_dir}"
    exit 1
  fi

  chmod +x "$source_script"

  # 兼容极简系统：确保 /usr/local/bin 存在
  if [[ $EUID -ne 0 ]]; then
    sudo mkdir -p "$(dirname "$TARGET_BIN")"
  else
    mkdir -p "$(dirname "$TARGET_BIN")"
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "[INFO] Need sudo to install launcher to ${TARGET_BIN}"
    sudo install -m 0755 "$source_script" "$TARGET_BIN"
  else
    install -m 0755 "$source_script" "$TARGET_BIN"
  fi

  echo "[OK] Installed. You can now run: nx"

  # 如果当前在交互终端，安装后直接进入菜单，免去手动再输入 nx
  if [[ "$NO_RUN" != "1" && -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Nginx-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      exec "$TARGET_BIN"
    fi
  fi
}

bootstrap_install() {
  echo "[INFO] 开始一键安装 Nginx-X..."

  install_git_if_needed

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] 检测到已安装目录，正在更新到最新版本..."
    ${SUDO} git -C "$INSTALL_DIR" pull --ff-only
  else
    echo "[INFO] 克隆仓库到 $INSTALL_DIR"
    ${SUDO} rm -rf "$INSTALL_DIR"
    ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR"
  fi

  # 进入安装目录执行同一个 install.sh（仅安装，不在子进程里启动 nx）
  ${SUDO} bash "$INSTALL_DIR/install.sh" --no-run

  if [[ -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Nginx-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      echo "[OK] 安装完成，正在启动 Nginx-X..."
      exec "$TARGET_BIN"
    fi
  fi
}

get_script_dir() {
  # 兼容两种调用方式：
  # 1) 本地文件执行: bash install.sh
  # 2) 远程一键执行: bash -c "$(curl ... )"（此时 BASH_SOURCE 可能不可用）
  local src=""

  if [[ ${BASH_SOURCE[0]-} != "" ]]; then
    src="${BASH_SOURCE[0]}"
  else
    src="$0"
  fi

  if [[ -n "$src" ]] && [[ -e "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    pwd
  fi
}

has_local_nx() {
  local script_dir
  script_dir="$(get_script_dir)"
  [[ -f "${script_dir}/nx.sh" ]]
}

for arg in "$@"; do
  case "$arg" in
    --no-run)
      NO_RUN="1"
      ;;
  esac
done

# 统一入口：
# - 在仓库目录执行（存在 nx.sh）=> 本地安装
# - 通过 curl 一键执行（通常无 nx.sh）=> 引导克隆后安装
if has_local_nx; then
  install_local
else
  bootstrap_install
fi
