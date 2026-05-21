<div align="center">

```
╔══════════════════════════════════════════════════════╗
║              NODE-ARMOR  v1.0                          ║
║   Optimizer + nftables Shield + CrowdSec               ║
╚══════════════════════════════════════════════════════╝
```

**Защита и оптимизация VPN-ноды. Одним скриптом. Всё в nftables.**

[![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu%20%7C%20Rocky%20%7C%20RHEL-orange?style=flat-square&logo=linux&logoColor=white)](https://github.com)
[![Firewall](https://img.shields.io/badge/firewall-nftables-red?style=flat-square)](https://wiki.nftables.org)

</div>

---

## Что это

Интерактивный bash-скрипт для оптимизации и защиты VPN-нод (Reality / VLESS / Hysteria / QUIC / WireGuard). Объединяет три слоя в одну согласованную систему, целиком на **nftables** — поэтому компоненты не конфликтуют между собой, как это бывает при смешивании `iptables` и `nft`.

Работает на **Debian/Ubuntu** и **Rocky Linux / AlmaLinux / RHEL** — ОС определяется автоматически.

---

## Архитектура: три слоя, один движок

| Слой | Зона ответственности | Реализация |
|---|---|---|
| **Sysctl** | BBR, TCP-тюнинг, conntrack по RAM, stealth, IP-форвардинг | `sysctl.d` |
| **nftables-щит** | SYN/UDP flood, conn-flood, new-conn flood, CGNAT-вайтлист, MSS clamp | нативный `nft` |
| **CrowdSec** | детект из логов, SSH brute-force, community blocklist | + `nftables-bouncer` |

Каждый слой делает то, что умеет лучше всего:
- **Объёмные атаки** (flood) гасятся в kernel-space за микросекунды — это nftables.
- **Поведенческий детект** (брутфорс, сканеры) и **превентивные баны** известных атакующих — это CrowdSec с community blocklist.

---

## Возможности

### ⚡ Оптимизатор (sysctl)

| Компонент | Что делает |
|---|---|
| **BBR + fq** | Современный congestion control, снимает потолок по пропускной способности |
| **TCP Fast Open** | Убирает лишний RTT при установке соединения |
| **TCP-буферы** | Расширенные окна под высоконагруженный трафик |
| **Conntrack tier-aware** | Лимиты автоматически под объём RAM (критично — таблица conntrack переполняется при DDoS первой) |
| **IP-форвардинг** | Включён для работы VPN-ноды |
| **Stealth sysctl** | Анти-fingerprint, скрытие SSH-banner |

### 🛡 nftables-щит

| Компонент | Что делает |
|---|---|
| **SYN flood** | Per-IP rate-limit, лишнее — в drop |
| **UDP flood** | Per-IP лимит, настроен щедро под QUIC/Hysteria |
| **Conn-flood** | Лимит одновременных соединений с одного IP |
| **New-conn flood** | Лимит новых соединений с одного IP в минуту |
| **CGNAT-вайтлист** | Мягкая ветка для мобильных операторов — без false-positive |
| **MSS clamp** | В forward-цепочке, устраняет фрагментацию VPN-трафика |
| **SSH brute-force** | Per-IP лимит на новые SSH-сессии |

### 🌐 CrowdSec

| Компонент | Что делает |
|---|---|
| **Community blocklist** | Тысячи известных атакующих IP блокируются превентивно |
| **Поведенческий детект** | SSH brute, сканеры, аномалии — из логов |
| **nftables-bouncer** | Исполняет баны в том же слое, без iptables |
| **CGNAT allowlist** | Мобильные операторы в белом списке — не банятся |

---

## ⚠️ Перед запуском — обязательно

Открой скрипт и отредактируй блок конфигурации вверху файла:

```bash
VPN_TCP_PORTS="443 8443"          # твои TCP-порты
VPN_UDP_PORTS="443 8443 51820"    # твои UDP-порты (Hysteria/QUIC/WG)
SSH_PORT="auto"                    # "auto" определит из текущего соединения
TRUSTED_IPS=""                     # свои ноды / домашний IP / мониторинг
ENABLE_CGNAT="yes"                 # вайтлист мобильных операторов
```

**Почему это важно:** щит работает по принципу `policy drop` — всё, что явно не разрешено, блокируется. Если не указать свои порты, ты закроешь доступ сам себе.

---

## 🔒 Защита от lock-out

Скрипт **не даст запереть себя**:

1. **SSH-порт определяется автоматически** из текущего соединения и открывается всегда.
2. **Авто-откат**: после применения firewall у тебя есть **90 секунд** открыть второе SSH-соединение и подтвердить доступ. Не подтвердил — правила автоматически откатываются к предыдущему состоянию.
3. **Проверка синтаксиса** через `nft -c` до применения — сломанный конфиг не применится.
4. **Бэкап** прошлого ruleset сохраняется в `/var/backups/node-armor/`.

---

## Запуск

```bash
# 1. Отредактируй блок конфигурации вверху файла
nano node-armor.sh

# 2. Запусти
sudo bash node-armor.sh
```

Скрипт покажет, что будет установлено и какие порты откроет, спросит подтверждение, затем применит всё в правильном порядке.

---

## Что с моими портами после запуска?

| | Состояние |
|---|---|
| **SSH** | открыт всегда (авто-определение порта) |
| **Перечисленные VPN-порты** | открыты |
| **Остальное входящее** | закрыто (цель — убрать поверхность атаки) |
| **Исходящий трафик** | не трогается, нода ходит в интернет как обычно |
| **VPN-форвардинг** | сохранён (`ip_forward=1` + MSS clamp) |

---

## Полезные команды

```bash
nft list table inet node_armor     # правила щита
nft list meters                    # кто упёрся в лимиты (flood-детекторы)
cscli metrics                      # статистика CrowdSec
cscli decisions list               # активные баны
cscli alerts list                  # история детектов
cscli capi status                  # статус community blocklist
```

---

## Тонкая настройка лимитов

Если ловишь false-positive (например, мультиплексинг с одного CGNAT-IP), подними в блоке конфигурации:

```bash
CONN_LIMIT="600"                  # одновременных соединений с IP
NEWCONN_RATE="800/minute"         # новых соединений с IP в минуту
SYN_RATE="300/second"             # SYN-пакетов с IP
UDP_RATE="3000/second"            # UDP-пакетов с IP (QUIC)
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

## Важные замечания

- Всё работает через **nftables** — никакого `iptables`, поэтому нет конфликта слоёв.
- Sysctl сохраняется в `/etc/sysctl.d/99-node-armor.conf`.
- Правила firewall: `/etc/nftables.d/node-armor.nft`, подключаются через `/etc/nftables.conf`, персистентны через `nftables.service`.
- Установка ядра (`DO_KERNEL="yes"`) **требует перезагрузки** и по умолчанию отключена.
- CrowdSec ставится официальным установщиком; bouncer — `crowdsec-firewall-bouncer-nftables`.

---

## Чего здесь сознательно нет

- **Port-scan через `xt_recent`** — CrowdSec ловит сканеры умнее и без расхода CPU.
- **traffic-guard на iptables** — чтобы остаться в чистом nftables. Те же preemptive-листы добавляются через `cscli blocklists`.

---

## Лицензия

MIT
