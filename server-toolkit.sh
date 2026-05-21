#!/usr/bin/env bash
# ============================================================
#  SERVER TOOLKIT  v2.0  —  Optimizer + Protection
#  Поддержка: Debian 10/11/12, Ubuntu 20.04/22.04/24.04
#             Rocky Linux 8/9, AlmaLinux 8/9, RHEL 8/9, CentOS Stream
# ============================================================

set -euo pipefail

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

# ─── Определение ОС ──────────────────────────────────────────
detect_os() {
  [[ -f /etc/os-release ]] || err "Не удалось определить ОС"
  . /etc/os-release
  OS_ID="${ID,,}"
  OS_VER="${VERSION_ID:-0}"
  OS_MAJOR="${OS_VER%%.*}"
  OS_PRETTY="${PRETTY_NAME:-$ID}"

  case "$OS_ID" in
    debian|ubuntu|linuxmint)
      FAMILY="debian"
      PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
      ;;
    rhel|centos|rocky|almalinux|ol|fedora|centos-stream)
      FAMILY="rhel"
      PKG_INSTALL="dnf install -y"
      ;;
    *)
      err "Неподдерживаемая ОС: $OS_ID"
      ;;
  esac

  info "ОС: $OS_PRETTY  |  Семейство: $FAMILY"
}

require_root() {
  [[ $EUID -eq 0 ]] || err "Запусти скрипт от root: sudo bash $0"
}

pkg_install() {
  eval "$PKG_INSTALL $*" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
#  БЛОК 1 — ОПТИМИЗАТОР
# ═══════════════════════════════════════════════════════════════

install_kernel_optimized() {
  step "Установка оптимизированного ядра"

  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]] || err "Поддерживается только x86_64, у тебя: $ARCH"

  case "$FAMILY" in

    # ── Debian/Ubuntu → XanMod ──────────────────────────────
    debian)
      info "Устанавливаю XanMod Kernel..."
      pkg_install gnupg curl wget ca-certificates

      XLEVEL=$(awk '/^flags/{
        if ($0~/avx512/){print "x86-64-v4";exit}
        if ($0~/avx2/)  {print "x86-64-v3";exit}
        if ($0~/avx/)   {print "x86-64-v2";exit}
        print "x86-64-v1";exit}' /proc/cpuinfo)
      info "Уровень CPU: $XLEVEL"

      curl -fsSL https://dl.xanmod.org/archive.key \
        | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] \
http://deb.xanmod.org releases main" \
        > /etc/apt/sources.list.d/xanmod-release.list
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-xanmod-${XLEVEL}"
      log "XanMod (${XLEVEL}) установлен. Перезагрузи сервер."
      ;;

    # ── Rocky/RHEL → kernel-ml (ELRepo) ─────────────────────
    rhel)
      info "Устанавливаю kernel-ml через ELRepo..."
      if (( OS_MAJOR >= 8 )); then
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null || true
        ELREPO_RPM="https://www.elrepo.org/elrepo-release-${OS_MAJOR}.el${OS_MAJOR}.elrepo.noarch.rpm"
        dnf install -y "$ELREPO_RPM" 2>/dev/null || warn "ELRepo уже установлен, продолжаю..."
        dnf --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel

        grub2-set-default 0
        [[ -f /etc/default/grub ]] && \
          sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
        if [[ -d /sys/firmware/efi ]]; then
          grub2-mkconfig -o /boot/efi/EFI/*/grub.cfg 2>/dev/null || \
          grub2-mkconfig -o /boot/grub2/grub.cfg
        else
          grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
        log "kernel-ml установлен. Перезагрузи сервер для активации."
      else
        warn "ELRepo поддерживает только RHEL/Rocky 8+. Пропускаю."
      fi
      ;;
  esac
}

tune_bbr3() {
  step "BBRv3 + TCP sysctl оптимизация"

  SYSCTL_FILE="/etc/sysctl.d/99-server-toolkit.conf"

  modprobe tcp_bbr3 2>/dev/null && BBR_MOD="tcp_bbr3" || \
  { modprobe tcp_bbr 2>/dev/null && BBR_MOD="tcp_bbr"; } || \
  BBR_MOD="bbr"
  info "BBR модуль: $BBR_MOD"

  cat > "$SYSCTL_FILE" << 'SYSCTL'
# ── Congestion Control / BBR ──────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── TCP буферы ────────────────────────────────────────────────
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 8192 262144 134217728
net.ipv4.tcp_wmem = 8192 262144 134217728
net.ipv4.tcp_mem = 786432 1048576 26777216

# ── TCP Fast Open ─────────────────────────────────────────────
net.ipv4.tcp_fastopen = 3

# ── TCP оптимизации ───────────────────────────────────────────
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# ── Очереди и backlog ─────────────────────────────────────────
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.ip_local_port_range = 1024 65535

# ── Прочее ───────────────────────────────────────────────────
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSCTL

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  QD=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  log "BBR+sysctl применены  |  CC: ${BOLD}$CC${NC}  Qdisc: ${BOLD}$QD${NC}"
}

tune_mss_clamp() {
  step "MSS Clamp (iptables)"

  _ensure_iptables

  iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu

  _save_iptables
  log "MSS clamp применён"
}

tune_conntrack() {
  step "Conntrack: tier-aware тюнинг"

  modprobe nf_conntrack 2>/dev/null || true

  RAM_GB=$(awk '/MemTotal/{printf "%d",$2/1024/1024}' /proc/meminfo)
  info "RAM: ${RAM_GB}GB"

  if   (( RAM_GB >= 16 )); then CT_MAX=2000000; HASHSIZE=512000
  elif (( RAM_GB >=  8 )); then CT_MAX=1000000; HASHSIZE=256000
  elif (( RAM_GB >=  4 )); then CT_MAX=500000;  HASHSIZE=128000
  else                          CT_MAX=200000;  HASHSIZE=65536
  fi
  info "max=$CT_MAX  hashsize=$HASHSIZE"

  [[ -f /sys/module/nf_conntrack/parameters/hashsize ]] && \
    echo "$HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
  echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf

  cat >> /etc/sysctl.d/99-server-toolkit.conf << SYSCTL

# ── Conntrack ────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_generic_timeout = 120
SYSCTL

  sysctl -p /etc/sysctl.d/99-server-toolkit.conf >/dev/null 2>&1 || true
  log "Conntrack настроен (max=$CT_MAX, hashsize=$HASHSIZE)"
}

# ═══════════════════════════════════════════════════════════════
#  БЛОК 2 — ЗАЩИТА
# ═══════════════════════════════════════════════════════════════

_ensure_iptables() {
  case "$FAMILY" in
    debian)
      pkg_install iptables ipset
      ;;
    rhel)
      pkg_install iptables iptables-services ipset ipset-service
      # На Rocky/RHEL firewalld конфликтует с iptables — отключаем
      if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "Останавливаю firewalld → переходим на iptables"
        systemctl stop firewalld
        systemctl disable firewalld
        systemctl mask firewalld
      fi
      systemctl enable --now iptables 2>/dev/null || true
      ;;
  esac
}

_save_iptables() {
  mkdir -p /etc/iptables
  case "$FAMILY" in
    debian)
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      ;;
    rhel)
      service iptables save 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
      ;;
  esac
}

setup_ddos_filter() {
  step "DDoS-фильтр (kernel-space)"

  _ensure_iptables

  ipset create blacklist hash:ip timeout 3600 2>/dev/null || ipset flush blacklist

  iptables -D INPUT -m set --match-set blacklist src -j DROP 2>/dev/null || true
  iptables -I INPUT 1 -m set --match-set blacklist src -j DROP

  # SYN flood
  iptables -N SYN_FLOOD 2>/dev/null || iptables -F SYN_FLOOD
  iptables -A SYN_FLOOD -m limit --limit 200/s --limit-burst 1000 -j RETURN
  iptables -A SYN_FLOOD -j SET --add-set blacklist src
  iptables -A SYN_FLOOD -j DROP
  iptables -D INPUT -p tcp --syn -j SYN_FLOOD 2>/dev/null || true
  iptables -I INPUT 2 -p tcp --syn -j SYN_FLOOD

  # UDP flood
  iptables -N UDP_FLOOD 2>/dev/null || iptables -F UDP_FLOOD
  iptables -A UDP_FLOOD -m limit --limit 500/s --limit-burst 2000 -j RETURN
  iptables -A UDP_FLOOD -j SET --add-set blacklist src
  iptables -A UDP_FLOOD -j DROP
  iptables -D INPUT -p udp -j UDP_FLOOD 2>/dev/null || true
  iptables -I INPUT 3 -p udp -j UDP_FLOOD

  # ICMP
  iptables -D INPUT -p icmp -j DROP 2>/dev/null || true
  iptables -A INPUT -p icmp -m limit --limit 10/s --limit-burst 20 -j ACCEPT
  iptables -A INPUT -p icmp -j DROP

  # Connlimit
  iptables -D INPUT -p tcp -m connlimit --connlimit-above 50 \
    -j REJECT 2>/dev/null || true
  iptables -A INPUT -p tcp -m connlimit --connlimit-above 50 \
    --connlimit-mask 32 -j REJECT --reject-with tcp-reset

  # INVALID
  iptables -D INPUT -m state --state INVALID -j DROP 2>/dev/null || true
  iptables -I INPUT 1 -m state --state INVALID -j DROP

  _save_iptables
  log "DDoS-фильтр активен"
  info "Забанить IP:  ipset add blacklist 1.2.3.4"
  info "Список банов: ipset list blacklist | tail -20"
}

setup_portscan_protection() {
  step "Защита от сканирования портов"

  _ensure_iptables

  iptables -N PORTSCAN 2>/dev/null || iptables -F PORTSCAN

  iptables -D INPUT -p tcp --tcp-flags ALL ALL  -j PORTSCAN 2>/dev/null || true
  iptables -D INPUT -p tcp --tcp-flags ALL NONE -j PORTSCAN 2>/dev/null || true
  iptables -D INPUT -p tcp --tcp-flags ALL FIN  -j PORTSCAN 2>/dev/null || true

  iptables -A INPUT -p tcp --tcp-flags ALL ALL  -j PORTSCAN
  iptables -A INPUT -p tcp --tcp-flags ALL NONE -j PORTSCAN
  iptables -A INPUT -p tcp --tcp-flags ALL FIN  -j PORTSCAN

  iptables -A PORTSCAN -m recent --name SCANNER --set -j DROP

  iptables -D INPUT -m recent --name SCANNER \
    --update --seconds 60 --hitcount 5 -j DROP 2>/dev/null || true
  iptables -I INPUT 2 -m recent --name SCANNER \
    --update --seconds 60 --hitcount 5 -j DROP

  _save_iptables
  log "Защита от port scan активна"
  info "Активные сканеры: cat /proc/net/xt_recent/SCANNER"
}

setup_stealth_node() {
  step "Скрытность ноды (анти-РКН fingerprint)"

  SYSCTL_FILE="/etc/sysctl.d/99-server-toolkit.conf"

  cat >> "$SYSCTL_FILE" << 'SYSCTL'

# ── Stealth / anti-fingerprint ───────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 0
SYSCTL

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

  if [[ -f /etc/ssh/sshd_config ]]; then
    grep -q "^DebianBanner no" /etc/ssh/sshd_config || \
      echo "DebianBanner no" >> /etc/ssh/sshd_config
    [[ "$FAMILY" == "rhel" ]] && {
      grep -q "^Banner none" /etc/ssh/sshd_config || \
        echo "Banner none" >> /etc/ssh/sshd_config
    }
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    info "SSH banner скрыт"
  fi

  log "Стелс-настройки применены"
}

# ═══════════════════════════════════════════════════════════════
#  МЕНЮ
# ═══════════════════════════════════════════════════════════════

print_banner() {
  clear
  echo -e "${BOLD}${CYAN}"
  cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║          SERVER TOOLKIT  v2.0                        ║
  ║    Debian/Ubuntu • Rocky/RHEL/AlmaLinux/CentOS       ║
  ╚══════════════════════════════════════════════════════╝
BANNER
  echo -e "${NC}"
}

print_menu() {
  echo -e "${BOLD}  ОПТИМИЗАТОР${NC}"
  echo -e "  ${CYAN}[1]${NC} Ядро: XanMod ${DIM}(Debian/Ubuntu)${NC} / kernel-ml ${DIM}(Rocky/RHEL)${NC}"
  echo -e "  ${CYAN}[2]${NC} BBRv3 + TCP sysctl"
  echo -e "  ${CYAN}[3]${NC} MSS Clamp"
  echo -e "  ${CYAN}[4]${NC} Conntrack (tier-aware по RAM)"
  echo -e "  ${CYAN}[5]${NC} ${BOLD}Весь оптимизатор${NC} ${DIM}(2+3+4, без ядра)${NC}"
  echo -e "  ${CYAN}[6]${NC} ${BOLD}Весь оптимизатор + новое ядро${NC}"
  echo ""
  echo -e "${BOLD}  ЗАЩИТА${NC}"
  echo -e "  ${CYAN}[7]${NC} DDoS-фильтр"
  echo -e "  ${CYAN}[8]${NC} Защита от сканеров портов"
  echo -e "  ${CYAN}[9]${NC} Скрытность ноды (анти-РКН)"
  echo -e "  ${CYAN}[10]${NC} ${BOLD}Вся защита${NC} ${DIM}(7+8+9)${NC}"
  echo ""
  echo -e "${BOLD}  КОМБО${NC}"
  echo -e "  ${CYAN}[11]${NC} ${BOLD}Всё сразу${NC} ${DIM}(оптимизатор + защита, без ядра)${NC}"
  echo -e "  ${CYAN}[12]${NC} ${BOLD}Всё сразу + новое ядро${NC}"
  echo ""
  echo -e "  ${RED}[0]${NC}  Выход"
  echo ""
  echo -ne "${BOLD}Выбор:${NC} "
}

run_choice() {
  case "$1" in
    1)  install_kernel_optimized ;;
    2)  tune_bbr3 ;;
    3)  tune_mss_clamp ;;
    4)  tune_conntrack ;;
    5)  tune_bbr3; tune_mss_clamp; tune_conntrack ;;
    6)  install_kernel_optimized; tune_bbr3; tune_mss_clamp; tune_conntrack ;;
    7)  setup_ddos_filter ;;
    8)  setup_portscan_protection ;;
    9)  setup_stealth_node ;;
    10) setup_ddos_filter; setup_portscan_protection; setup_stealth_node ;;
    11) tune_bbr3; tune_mss_clamp; tune_conntrack
        setup_ddos_filter; setup_portscan_protection; setup_stealth_node ;;
    12) install_kernel_optimized; tune_bbr3; tune_mss_clamp; tune_conntrack
        setup_ddos_filter; setup_portscan_protection; setup_stealth_node ;;
    0)  echo -e "\n${DIM}Пока!${NC}\n"; exit 0 ;;
    *)  warn "Неверный выбор: $1" ;;
  esac
}

main() {
  require_root
  detect_os

  if [[ $# -gt 0 ]]; then
    run_choice "$1"
    echo ""
    log "Готово!"
    exit 0
  fi

  while true; do
    print_banner
    info "ОС: $OS_PRETTY"
    echo ""
    print_menu
    read -r choice
    run_choice "$choice"
    echo ""
    echo -ne "${DIM}Нажми Enter для возврата в меню...${NC}"
    read -r
  done
}

main "$@"
