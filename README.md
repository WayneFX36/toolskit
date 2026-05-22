<div align="center">

```
╔══════════════════════════════════════════════════════╗
║              NODE-ARMOR  v1.1                          ║
║   Optimizer + nftables Shield + CrowdSec               ║
╚══════════════════════════════════════════════════════╝
```

**Защита и оптимизация серверов и VPN-нод. Одним скриптом.**

[![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu%20%7C%20Rocky%20%7C%20RHEL-orange?style=flat-square&logo=linux&logoColor=white)](https://github.com)

</div>

---

## Что это

Интерактивный bash-скрипт для оптимизации и защиты Linux-серверов и VPN-нод (Reality / VLESS / Hysteria / QUIC / WireGuard). Три слоя защиты, ОС определяется автоматически.

Работает на **Debian/Ubuntu** и **Rocky Linux / AlmaLinux / RHEL**.

---

## ⚠️ ВАЖНО: для кого этот скрипт, а для кого НЕТ

Скрипт собирает собственный **nftables**-firewall с `policy drop`. Это значит:

| Твоя система | firewall-часть | что использовать |
|---|---|---|
| **Чистая нода без firewalld и без Docker** | ✅ можно весь скрипт | весь node-armor |
| **Активен firewalld** (типично для Rocky/RHEL) | ❌ пропускается автоматически | оставь firewalld, бери только sysctl + CrowdSec |
| **Нода/панель в Docker** (Remnawave и т.п.) | ⚠️ спросит подтверждение | управляй портами штатно, бери sysctl + CrowdSec |

Начиная с v1.1 скрипт **сам определяет** активный firewalld и **не трогает** firewall, чтобы не сломать существующую настройку. На таких системах он применит только безопасные части (sysctl-тюнинг) и поставит CrowdSec с подходящим bouncer'ом.

**Если у тебя Rocky/RHEL + firewalld + Remnawave** — firewall у тебя уже работает через `firewall-cmd`, и трогать его этим скриптом не нужно. Используй только sysctl-слой и CrowdSec.

---

## Архитектура: три слоя

| Слой | Зона ответственности | Когда применяется |
|---|---|---|
| **Sysctl** | BBR, TCP-тюнинг, conntrack по RAM, stealth, IP-форвардинг | всегда (безопасно для всех ОС) |
| **nftables-щит** | SYN/UDP flood, conn-flood, CGNAT-вайтлист, MSS clamp | только если НЕ активен firewalld |
| **CrowdSec** | детект из логов, SSH brute, community blocklist | всегда (bouncer под твой firewall) |

---

## Возможности

### ⚡ Оптимизатор (sysctl) — безопасно для всех ОС

| Компонент | Что делает |
|---|---|
| **BBR + fq** | Современный congestion control, снимает потолок по пропускной способности |
| **TCP Fast Open** | Убирает лишний RTT при установке соединения |
| **TCP-буферы** | Расширенные окна под высоконагруженный трафик |
| **Conntrack tier-aware** | Лимиты автоматически под объём RAM |
| **IP-форвардинг** | Включён для работы VPN-ноды |
| **Stealth sysctl** | Анти-fingerprint. SSH-banner скрывается ТОЛЬКО на Debian/Ubuntu (на RHEL директивы нет) |

### 🛡 nftables-щит — только без firewalld

| Компонент | Что делает |
|---|---|
| **SYN flood** | Per-IP rate-limit |
| **UDP flood** | Per-IP лимит, щедро под QUIC/Hysteria |
| **Conn-flood** | Лимит одновременных соединений с IP |
| **New-conn flood** | Лимит новых соединений с IP в минуту |
| **CGNAT-вайтлист** | Мягкая ветка для мобильных операторов |
| **MSS clamp** | Устраняет фрагментацию VPN-трафика |

### 🌐 CrowdSec — для всех ОС

| Компонент | Что делает |
|---|---|
| **Community blocklist** | Тысячи известных атакующих IP блокируются превентивно |
| **Поведенческий детект** | SSH brute, сканеры, аномалии — из логов |
| **Bouncer** | Подбирается под твой firewall (firewalld / nftables) |
| **CGNAT allowlist** | Мобильные операторы не банятся |

---

## Перед запуском — отредактируй конфиг

В начале файла:

```bash
VPN_TCP_PORTS="443 8443"          # твои TCP-порты
VPN_UDP_PORTS="443 8443 51820"    # твои UDP-порты
SSH_PORT="auto"                    # "auto" = определить из текущего соединения
TRUSTED_IPS=""                     # свои ноды / домашний IP
ENABLE_CGNAT="yes"

# Компоненты — что ставить
DO_SYSCTL="yes"                    # безопасно везде
DO_FIREWALL="yes"                  # авто-пропуск при активном firewalld
DO_CROWDSEC="yes"
DO_KERNEL="no"                     # XanMod/kernel-ml, требует reboot
```

**Совет для Rocky+firewalld+Remnawave:** поставь `DO_FIREWALL="no"` явно — тогда скрипт даже не будет проверять firewall, только sysctl + CrowdSec.

---

## 🔒 Защита от lock-out

1. **SSH-порт** определяется автоматически и открывается всегда.
2. **DebianBanner** добавляется только на Debian/Ubuntu, и лишь если `sshd -t` подтверждает валидность конфига — иначе строка откатывается. (В v1.0 это ломало sshd на Rocky — исправлено.)
3. **Авто-откат firewall**: после применения есть **90 секунд** подтвердить доступ во втором SSH-окне; не подтвердил — правила откатываются.
4. **Проверка `nft -c`** до применения.
5. **Бэкап** ruleset в `/var/backups/node-armor/`.

---

## Установка

Скачать скрипт с GitHub:

```bash
curl -fsSL -O https://raw.githubusercontent.com/WayneFX36/toolskit/refs/heads/main/server-toolkit.sh
chmod +x server-toolkit.sh
```

Или через wget:

```bash
wget https://raw.githubusercontent.com/WayneFX36/toolskit/refs/heads/main/server-toolkit.sh
chmod +x server-toolkit.sh
```

> **Не запускай через `curl ... | bash`** — сначала скачай файл, открой и отредактируй блок конфигурации вверху (порты, SSH, компоненты), и только потом запускай. Пайп в bash не даст настроить порты и рискует запереть SSH.

## Запуск

```bash
nano server-toolkit.sh    # отредактируй конфиг вверху (порты, SSH, компоненты)
sudo bash server-toolkit.sh
```

---

## Полезные команды

```bash
# если применялся nftables-щит:
nft list table inet node_armor
nft list meters

# CrowdSec (всегда):
cscli metrics
cscli decisions list
cscli alerts list
cscli capi status

# если firewall у тебя на firewalld:
firewall-cmd --list-all
```

---

## Откат / удаление

Если firewall-часть применилась, а ты используешь firewalld:

```bash
nft delete table inet node_armor 2>/dev/null
sed -i '\#nftables.d/node-armor.nft#d' /etc/nftables.conf
systemctl disable --now nftables 2>/dev/null
systemctl enable --now firewalld
firewall-cmd --reload
```

Убрать sysctl-тюнинг:

```bash
rm -f /etc/sysctl.d/99-node-armor.conf /etc/modprobe.d/nf_conntrack.conf
```

Если sshd не стартует после запуска (актуально для старых версий на RHEL):

```bash
sed -i '/^DebianBanner/d' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```

---

## Поддерживаемые ОС

| Дистрибутив | Версии |
|---|---|
| Debian | 11, 12 |
| Ubuntu | 22.04, 24.04 |
| Rocky Linux | 8, 9 |
| AlmaLinux | 8, 9 |
| RHEL | 8, 9 |

---

## Changelog

**v1.1**
- Исправлен баг: `DebianBanner` ломал sshd на Rocky/RHEL. Теперь добавляется только на Debian/Ubuntu и с проверкой `sshd -t` + авто-откатом.
- Firewall-часть автоматически пропускается при активном firewalld (защита от конфликта).
- Добавлен Docker-детект с подтверждением перед изменением firewall.
- Bouncer CrowdSec подбирается под реальный firewall.

**v1.0**
- Первый релиз: sysctl + nftables-щит + CrowdSec.

---

## Лицензия

MIT
