#!/usr/bin/env bash
# =============================================================================
# common.sh —— 所有部署脚本共用的常量与函数
# 用法：source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# =============================================================================
set -euo pipefail

# ------------------------------- 常量 ----------------------------------------
APP_NAME="opslink"
APP_USER="ops"
APP_HOME="/opt/ops-platform"
APP_RELEASES="${APP_HOME}/releases"
APP_SHARED="${APP_HOME}/shared"
APP_CURRENT="${APP_HOME}/current"
APP_VENV="${APP_HOME}/venv"
DATA_DIR="/data"
CONF_DIR="/etc/ops-platform"
LOG_DIR="/var/log/ops-platform"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
SECRETS_FILE="${CONF_DIR}/platform.env"
APP_ENV_FILE="${CONF_DIR}/app.env"

MON_HOME="/opt"
PROM_HOME="/opt/prometheus"
AM_HOME="/opt/alertmanager"
NE_HOME="/opt/node_exporter"
ME_HOME="/opt/mysqld_exporter"
NXE_HOME="/opt/nginx-prometheus-exporter"
PROM_CONF="/etc/prometheus"
AM_CONF="/etc/alertmanager"

PROM_VERSION="2.53.0"
AM_VERSION="0.27.0"
NE_VERSION="1.8.2"
ME_VERSION="0.15.1"
NXE_VERSION="1.4.1"
GRAFANA_DEB_VER="9.5.21"

# 国内镜像（脚本里所有下载都走这里，不用翻墙）
MIRROR_HW="https://mirrors.huaweicloud.com/prometheus"
MIRROR_TUNA="https://mirrors.tuna.tsinghua.edu.cn"
GH_PROXY="https://gh-proxy.com"

# 仓库根目录（deploy/lib/common.sh -> 仓库根）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ------------------------------- 输出 ----------------------------------------
if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_END=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_END=""
fi

log_info()  { printf '%s[INFO ]%s %s\n' "${C_BLU}" "${C_END}" "$*"; }
log_ok()    { printf '%s[ OK  ]%s %s\n' "${C_GRN}" "${C_END}" "$*"; }
log_warn()  { printf '%s[WARN ]%s %s\n' "${C_YEL}" "${C_END}" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_END}" "$*" >&2; }

die() { log_error "$*"; exit 1; }

step() {
  printf '\n%s==> %s%s\n' "${C_BLU}" "$*" "${C_END}"
}

# ------------------------------- 前置检查 ------------------------------------
need_root() {
  [[ ${EUID} -eq 0 ]] || die "请用 root 执行：sudo $0 $*"
}

check_ubuntu() {
  local id ver
  # 注意：/etc/os-release 里的变量只在该 subshell 中有效，必须在子 shell 内取值
  id="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
  ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-unknown}")"
  [[ "${id}" == "ubuntu" ]] || die "本项目只支持 Ubuntu，当前系统：${id}"
  if [[ "${ver}" != "22.04" ]]; then
    log_warn "当前 Ubuntu ${ver}，脚本按 22.04 编写（其他版本语法基本兼容，但请自行验证）"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

apt_install() {
  # 幂等安装：已装就跳过
  local missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_ok "软件包已安装：$*"
    return 0
  fi
  log_info "安装软件包：${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

# 备份被覆盖前的配置文件，避免「改坏了回不去」
backup_file() {
  local f="$1"
  if [[ -f "${f}" && ! -f "${f}.bak.orig" ]]; then
    cp -a "${f}" "${f}.bak.orig"
    log_info "已备份原配置：${f}.bak.orig"
  fi
}

ensure_dir() {
  local d
  for d in "$@"; do
    [[ -d "${d}" ]] || mkdir -p "${d}"
  done
}

# ------------------------------- 下载 ----------------------------------------
# download <目标文件> <url1> [url2] ...  逐个尝试，全失败才报错
download() {
  local dest="$1"; shift
  if [[ -s "${dest}" ]]; then
    log_ok "已存在，跳过下载：$(basename "${dest}")"
    return 0
  fi
  local url
  for url in "$@"; do
    log_info "下载 $(basename "${dest}")  <- ${url}"
    # --retry 处理国内镜像偶发 5xx；--connect-timeout 防止卡死
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
            --max-time 900 -o "${dest}.part" "${url}"; then
      # 国内镜像有时对不存在的文件返回 200 + HTML 错误页，必须验证内容再落盘
      if [[ "$(head -c 1 "${dest}.part" 2>/dev/null)" == "<" ]]; then
        log_warn "该地址返回的是 HTML（多半是镜像 404 页面），换下一个"
        rm -f "${dest}.part"
        continue
      fi
      if [[ "${dest}" == *.tar.gz ]] \
         && [[ "$(head -c 2 "${dest}.part" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]]; then
        log_warn "该地址返回的不是 gzip 文件，换下一个"
        rm -f "${dest}.part"
        continue
      fi
      mv "${dest}.part" "${dest}"
      log_ok "下载完成：$(basename "${dest}") ($(du -h "${dest}" | cut -f1))"
      return 0
    fi
    rm -f "${dest}.part"
    log_warn "该地址失败，尝试下一个：${url}"
  done
  die "全部下载地址失败：$(basename "${dest}")"
}

# ------------------------------- 随机密码 ------------------------------------
# 从 SECRETS_FILE 读取 KEY，没有就生成并写入（保证脚本可重复执行而不改密码）
get_or_create_secret() {
  local key="$1" len="${2:-24}" value=""
  if [[ -f "${SECRETS_FILE}" ]]; then
    value="$(grep -E "^${key}=" "${SECRETS_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  if [[ -z "${value}" ]]; then
    value="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}")"
    mkdir -p "$(dirname "${SECRETS_FILE}")"
    printf '%s=%s\n' "${key}" "${value}" >>"${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
  fi
  printf '%s' "${value}"
}

load_secrets() {
  [[ -f "${SECRETS_FILE}" ]] && set -a && . "${SECRETS_FILE}" && set +a
}

# ------------------------------- 服务操作 ------------------------------------
svc_reload_systemd() { systemctl daemon-reload; }

svc_restart() {
  local s="$1"
  systemctl enable --now "${s}" >/dev/null 2>&1 || true
  systemctl restart "${s}"
  sleep 1
  if systemctl is-active --quiet "${s}"; then
    log_ok "服务 ${s} 运行中"
  else
    log_error "服务 ${s} 启动失败，最近日志："
    journalctl -u "${s}" -n 30 --no-pager >&2 || true
    return 1
  fi
}

wait_http() {
  # wait_http <url> <超时秒> [期望状态码...]
  local url="$1" timeout="${2:-30}" expect="${3:-200}" i
  for ((i = 0; i < timeout; i++)); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}" || true)"
    if [[ "${code}" == "${expect}" ]]; then
      log_ok "接口就绪：${url} -> ${code}"
      return 0
    fi
    sleep 1
  done
  log_error "接口未就绪：${url} 期望 ${expect}"
  return 1
}

# 本机主 IP（NAT 网卡），用于生成访问地址与 BASE_DOMAIN
primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

banner() {
  printf '%s\n' "============================================================"
  printf '  %s\n' "$*"
  printf '%s\n' "============================================================"
}
