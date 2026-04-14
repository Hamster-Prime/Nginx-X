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

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  echo "[INFO] 未检测到 git，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    if ! ${SUDO} apt-get update; then
      echo "[ERROR] apt-get update 失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
    if ! ${SUDO} apt-get install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! ${SUDO} dnf install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! ${SUDO} yum install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
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

  # 兼容极简系统：确保 /usr/local/bin 存在并安装脚本
  ${SUDO} mkdir -p "$(dirname "$TARGET_BIN")"
  ${SUDO} install -m 0755 "$source_script" "$TARGET_BIN"

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
    if ! ${SUDO} git -C "$INSTALL_DIR" pull --ff-only; then
      echo "[ERROR] 拉取最新代码失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  elif [[ -e "$INSTALL_DIR" ]]; then
    echo "[WARN] 目标目录已存在，但不是 Git 仓库：$INSTALL_DIR"
    if [[ -t 0 && -t 1 ]]; then
      if ! confirm "是否清空该目录并重新安装？"; then
        echo "[INFO] 已取消安装。"
        exit 0
      fi
    else
      echo "[ERROR] 非交互模式下不会自动删除已有目录，请先手动清理：$INSTALL_DIR"
      exit 1
    fi

    ${SUDO} rm -rf "$INSTALL_DIR"
    echo "[INFO] 已清理旧目录，重新克隆仓库到 $INSTALL_DIR"
    if ! ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR"; then
      echo "[ERROR] 克隆仓库失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  else
    echo "[INFO] 克隆仓库到 $INSTALL_DIR"
    if ! ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR"; then
      echo "[ERROR] 克隆仓库失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  fi

  # 进入安装目录执行同一个 install.sh（仅安装，不在子进程里启动 nx）
  if ! ${SUDO} env NO_RUN=1 bash "$INSTALL_DIR/install.sh" --no-run; then
    echo "[ERROR] 安装器执行失败。请根据上面的输出检查具体报错。"
    exit 1
  fi

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
