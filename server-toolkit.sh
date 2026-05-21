#!/usr/bin/env bash
# ============================================================
#  NODE-ARMOR  v1.0
#  Оптимизатор + nftables-щит + CrowdSec — всё в одном слое
#  Для VPN-нод (Reality / VLESS / Hysteria / QUIC)
#  Debian 11/12 • Ubuntu 22.04/24.04 • Rocky/RHEL/Alma 8/9
# ============================================================
#  Принцип: ВСЁ работает через nftables (никакого iptables),
#  поэтому компоненты не конфликтуют между собой.
# ============================================================

set -euo pipefail

# ╔══════════════════════════════════════════════════════════╗
# ║  КОНФИГУРАЦИЯ — ОТРЕДАКТИРУЙ ПЕРЕД ЗАПУСКОМ                ║
# ╚══════════════════════════════════════════════════════════╝

# Порты, которые держим ОТКРЫТЫМИ (входящие). SSH добавится автоматически.
VPN_TCP_PORTS="443 8443"          # Reality / VLESS / TCP-транспорты
VPN_UDP_PORTS="443 8443 51820"    # Hysteria / QUIC / WireGuard

# SSH-порт. "auto" = определить из текущего соединения и sshd_config.
SSH_PORT="auto"

# Доверенные IP (твои другие ноды, домашний IP, мониторинг) — без лимитов.
# Пример: TRUSTED_IPS="203.0.113.5 198.51.100.0/24"
TRUSTED_IPS=""

# CGNAT-вайтлист для мобильных операторов (мягкие лимиты, не баним подсеть).
# 100.64.0.0/10 — общий shared-space CGNAT (RFC 6598).
# Добавь сюда публичные подсети своих операторов при необходимости.
ENABLE_CGNAT="yes"
CGNAT_RANGES="100.64.0.0/10"

# Лимиты защиты (per-IP). Подняты под VPN-нагрузку, чтобы не ловить false-positive.
SYN_RATE="300/second"             # SYN-пакетов с одного IP
CONN_LIMIT="600"                  # одновременных TCP-соединений с одного IP
NEWCONN_RATE="800/minute"         # новых соединений с одного IP в минуту
UDP_RATE="3000/second"            # UDP-пакетов с одного IP (для QUIC щедро)

# Компоненты к установке (yes/no)
DO_SYSCTL="yes"                   # BBR + TCP-тюнинг + conntrack + stealth
DO_FIREWALL="yes"                 # nftables-щит
DO_CROWDSEC="yes"                 # CrowdSec + nftables-bouncer + community blocklist
DO_KERNEL="no"                    # XanMod/kernel-ml (требует reboot; по умолч. off)

# ─── служебное ───────────────────────────────────────────────
NFT_CONF="/etc/nftables.d/node-armor.nft"
SYSCTL_FILE="/etc/sysctl.d/99-node-armor.conf"
BACKUP_DIR="/var/backups/node-armor"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

require_root() { [[ $EUID -eq 0 ]] || err "Запусти от root: sudo bash $0"; }

detect_os() {
  [[ -f /etc/os-release ]] || err "Не удалось определить ОС"
  . /etc/os-release
  OS_ID="${ID,,}"; OS_PRETTY="${PRETTY_NAME:-$ID}"
  case "$OS_ID" in
    debian|ubuntu|linuxmint) FAMILY="debian"; PKG="apt-get install -y" ;;
    rhel|centos|rocky|almalinux|ol|fedora) FAMILY="rhel"; PKG="dnf install -y" ;;
    *) err "Неподдерживаемая ОС: $OS_ID" ;;
  esac
  info "ОС: $OS_PRETTY  |  Семейство: $FAMILY"
}

pkg() { DEBIAN_FRONTEND=noninteractive eval "$PKG $*"; }

detect_ssh_port() {
  if [[ "$SSH_PORT" == "auto" ]]; then
    # сначала — порт текущего соединения (самый надёжный источник)
    local p
    p=$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')
    [[ -z "$p" ]] && p=$(grep -iE '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [[ -z "$p" ]] && p=22
    SSH_PORT="$p"
  fi
  info "SSH-порт: ${BOLD}$SSH_PORT${NC} (будет открыт всегда)"
}

# ═══════════════════════════════════════════════════════════════
#  1. SYSCTL: BBR + TCP-тюнинг + conntrack + stealth
# ═══════════════════════════════════════════════════════════════
setup_sysctl() {
  step "Sysctl: BBR + TCP + conntrack + stealth"
  modprobe tcp_bbr 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true

  local RAM_GB CT_MAX HASHSIZE
  RAM_GB=$(awk '/MemTotal/{printf "%d",$2/1024/1024}' /proc/meminfo)
  if   (( RAM_GB >= 16 )); then CT_MAX=2000000; HASHSIZE=512000
  elif (( RAM_GB >=  8 )); then CT_MAX=1000000; HASHSIZE=256000
  elif (( RAM_GB >=  4 )); then CT_MAX=500000;  HASHSIZE=128000
  else                          CT_MAX=200000;  HASHSIZE=65536; fi
  info "RAM ${RAM_GB}GB → conntrack_max=$CT_MAX, hashsize=$HASHSIZE"
  echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf

  cat > "$SYSCTL_FILE" << SYSCTL
# ── BBR / congestion control ──────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── VPN: форвардинг трафика (КРИТИЧНО для ноды) ────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ── TCP буферы ────────────────────────────────────────────────
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 8192 262144 134217728
net.ipv4.tcp_wmem = 8192 262144 134217728
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15

# ── Очереди / backlog ─────────────────────────────────────────
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65535

# ── Анти-DDoS / SYN cookies ───────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1

# ── Conntrack ─────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# ── Stealth / anti-fingerprint ────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 0
SYSCTL

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  # скрыть SSH-баннер
  if [[ -f /etc/ssh/sshd_config ]]; then
    grep -q "^DebianBanner no" /etc/ssh/sshd_config 2>/dev/null || \
      echo "DebianBanner no" >> /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  fi
  local CC; CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  log "Sysctl применён | CC=$CC"
}

# ═══════════════════════════════════════════════════════════════
#  2. NFTABLES-ЩИТ (единый firewall)
# ═══════════════════════════════════════════════════════════════
build_firewall() {
  step "Сборка nftables-щита"
  pkg nftables >/dev/null 2>&1 || true
  systemctl enable nftables >/dev/null 2>&1 || true
  mkdir -p /etc/nftables.d "$BACKUP_DIR"

  # подключить наш файл в основной конфиг, если ещё не подключён
  if ! grep -q 'nftables.d/node-armor.nft' /etc/nftables.conf 2>/dev/null; then
    echo "include \"$NFT_CONF\"" >> /etc/nftables.conf
  fi

  # собираем порты в nft-формат
  local tcp_set udp_set
  tcp_set=$(echo "$VPN_TCP_PORTS" | tr ' ' ',')
  udp_set=$(echo "$VPN_UDP_PORTS" | tr ' ' ',')

  local trusted_block="" cgnat_block="" cgnat_jump=""
  [[ -n "$TRUSTED_IPS" ]] && trusted_block="elements = { $(echo "$TRUSTED_IPS" | tr ' ' ',') }"
  if [[ "$ENABLE_CGNAT" == "yes" ]]; then
    cgnat_block="elements = { $(echo "$CGNAT_RANGES" | tr ' ' ',') }"
    cgnat_jump='ip saddr @cgnat jump cgnat_chain'
  fi

  cat > "$NFT_CONF" << NFT
#!/usr/sbin/nft -f
# node-armor: единый щит. НЕ редактируй вручную — правь скрипт.

table inet node_armor {
    set trusted { type ipv4_addr; flags interval; $trusted_block }
    set cgnat   { type ipv4_addr; flags interval; $cgnat_block }

    # ── MSS clamp для форвардинга VPN-трафика ────────────────
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }

    # ── мягкие лимиты для CGNAT (мобильные операторы) ─────────
    chain cgnat_chain {
        ct state established,related accept
        tcp dport { $tcp_set } accept
        udp dport { $udp_set } accept
        tcp dport $SSH_PORT accept
        return
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. база
        iif lo accept
        ct state established,related accept
        ct state invalid drop

        # 2. доверенные — без проверок
        ip saddr @trusted accept

        # 3. CGNAT — мягкая ветка (не баним всю подсеть)
        $cgnat_jump

        # 4. SSH (всегда открыт, с защитой от брутфорса per-IP)
        tcp dport $SSH_PORT ct state new \
            meter ssh_bf { ip saddr limit rate over 10/minute } drop
        tcp dport $SSH_PORT accept

        # 5. ICMP (ограниченный ping)
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        ip6 nexthdr icmpv6 accept

        # 6. SYN flood (per-IP)
        tcp flags syn meter syn_flood { ip saddr limit rate over $SYN_RATE } drop

        # 7. conn-flood: >$CONN_LIMIT одновременных с одного IP
        meter conn_flood { ip saddr ct count over $CONN_LIMIT } drop

        # 8. new-connection flood: >$NEWCONN_RATE с одного IP
        ct state new meter newconn_flood { ip saddr limit rate over $NEWCONN_RATE } drop

        # 9. UDP flood (per-IP) для Hysteria/QUIC
        meter udp_flood { ip saddr limit rate over $UDP_RATE } udp dport { $udp_set } accept

        # 10. рабочие порты
        tcp dport { $tcp_set } accept
        udp dport { $udp_set } accept
    }
}
NFT

  # проверка синтаксиса ДО применения
  if ! nft -c -f "$NFT_CONF"; then
    err "Ошибка синтаксиса в nftables-конфиге. Правила НЕ применены."
  fi
  log "Конфиг собран и прошёл проверку синтаксиса"
}

apply_firewall_safe() {
  step "Применение firewall с авто-откатом (защита от lock-out)"
  local backup="$BACKUP_DIR/pre-$(date +%s).nft"
  nft list ruleset > "$backup" 2>/dev/null || true
  info "Бэкап текущих правил: $backup"

  nft -f "$NFT_CONF"
  rm -f /tmp/.armor_ok

  # фоновый откат через 90с, если не подтвердили
  ( sleep 90; [[ -f /tmp/.armor_ok ]] || { nft flush ruleset; nft -f "$backup" 2>/dev/null; } ) &
  local revert_pid=$!

  echo ""
  warn "═══════════════════════════════════════════════════════"
  warn "  ВАЖНО: открой ВТОРОЕ SSH-соединение ПРЯМО СЕЙЧАС"
  warn "  и убедись, что сервер доступен."
  warn "  Если через 90с не подтвердишь — правила откатятся."
  warn "═══════════════════════════════════════════════════════"
  echo ""
  read -r -p "Доступ во втором окне работает? Нажми Enter для подтверждения: "
  touch /tmp/.armor_ok
  kill "$revert_pid" 2>/dev/null || true

  # сохранить как постоянные
  nft list ruleset > /dev/null
  systemctl restart nftables 2>/dev/null || true
  log "Firewall применён и сохранён (автозагрузка через nftables.service)"
}

# ═══════════════════════════════════════════════════════════════
#  3. CROWDSEC + nftables-bouncer + community blocklist
# ═══════════════════════════════════════════════════════════════
setup_crowdsec() {
  step "Установка CrowdSec + nftables-bouncer"
  if ! command -v cscli >/dev/null 2>&1; then
    curl -s https://install.crowdsec.net | sh
    pkg crowdsec
  else
    info "CrowdSec уже установлен"
  fi

  # bouncer именно nftables (чтобы не плодить iptables)
  pkg crowdsec-firewall-bouncer-nftables

  # коллекции под ноду
  cscli collections install crowdsecurity/sshd        --error 2>/dev/null || true
  cscli collections install crowdsecurity/linux       --error 2>/dev/null || true
  cscli collections install crowdsecurity/iptables    --error 2>/dev/null || true

  # подключение к Central API (community blocklist — тысячи preemptive-банов)
  cscli capi register 2>/dev/null || true

  # CGNAT в allowlist, чтобы CrowdSec не банил мобильных
  if [[ "$ENABLE_CGNAT" == "yes" ]]; then
    cscli allowlists create cgnat -d "RU mobile CGNAT" 2>/dev/null || true
    for r in $CGNAT_RANGES; do
      cscli allowlists add cgnat "$r" -d "CGNAT" 2>/dev/null || true
    done
  fi
  for ip in $TRUSTED_IPS; do
    cscli allowlists add cgnat "$ip" -d "trusted" 2>/dev/null || \
    cscli decisions add --ip "$ip" --type allow 2>/dev/null || true
  done

  systemctl restart crowdsec 2>/dev/null || true
  systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
  log "CrowdSec активен. Статус: cscli metrics | Баны: cscli decisions list"
}

# ═══════════════════════════════════════════════════════════════
#  4. (опц.) Оптимизированное ядро
# ═══════════════════════════════════════════════════════════════
setup_kernel() {
  step "Установка оптимизированного ядра (требует reboot)"
  [[ "$(uname -m)" == "x86_64" ]] || { warn "Только x86_64, пропускаю"; return; }
  case "$FAMILY" in
    debian)
      pkg gnupg curl ca-certificates
      local XLEVEL
      XLEVEL=$(awk '/^flags/{if($0~/avx512/){print"x86-64-v4";exit}if($0~/avx2/){print"x86-64-v3";exit}if($0~/avx/){print"x86-64-v2";exit}print"x86-64-v1";exit}' /proc/cpuinfo)
      curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" > /etc/apt/sources.list.d/xanmod-release.list
      apt-get update -qq
      pkg "linux-xanmod-${XLEVEL}"
      log "XanMod ($XLEVEL) установлен. Перезагрузи сервер."
      ;;
    rhel)
      rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null || true
      local M="${VERSION_ID%%.*}"
      dnf install -y "https://www.elrepo.org/elrepo-release-${M}.el${M}.elrepo.noarch.rpm" 2>/dev/null || true
      dnf --enablerepo=elrepo-kernel install -y kernel-ml
      grub2-set-default 0 2>/dev/null || true
      log "kernel-ml установлен. Перезагрузи сервер."
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════
main() {
  require_root
  detect_os
  detect_ssh_port

  echo ""
  info "Будет установлено:"
  [[ "$DO_KERNEL"   == "yes" ]] && echo "   • оптимизированное ядро (reboot)"
  [[ "$DO_SYSCTL"   == "yes" ]] && echo "   • BBR + TCP-тюнинг + conntrack + stealth"
  [[ "$DO_FIREWALL" == "yes" ]] && echo "   • nftables-щит (откроет: SSH/$SSH_PORT, TCP {$VPN_TCP_PORTS}, UDP {$VPN_UDP_PORTS})"
  [[ "$DO_CROWDSEC" == "yes" ]] && echo "   • CrowdSec + nftables-bouncer + community blocklist"
  echo ""
  read -r -p "Продолжить? [y/N]: " ok
  [[ "${ok,,}" == "y" ]] || { info "Отменено"; exit 0; }

  [[ "$DO_KERNEL"   == "yes" ]] && setup_kernel
  [[ "$DO_SYSCTL"   == "yes" ]] && setup_sysctl
  if [[ "$DO_FIREWALL" == "yes" ]]; then
    build_firewall
    apply_firewall_safe
  fi
  [[ "$DO_CROWDSEC" == "yes" ]] && setup_crowdsec

  echo ""
  log "Готово!"
  echo ""
  info "Полезные команды:"
  echo "   nft list table inet node_armor      # правила щита"
  echo "   nft list meters                     # кто упёрся в лимиты"
  echo "   cscli metrics                       # статистика CrowdSec"
  echo "   cscli decisions list                # активные баны"
  echo "   cscli alerts list                   # история детектов"
  [[ "$DO_KERNEL" == "yes" ]] && warn "Не забудь reboot для активации ядра."
}

main "$@"
