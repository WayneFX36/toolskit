<div align="center">

```
╔══════════════════════════════════════════════════════╗
║          SERVER TOOLKIT  v2.0                        ║
║          Optimizer + Protection                      ║
╚══════════════════════════════════════════════════════╝
```

**Выжми максимум из сервера. Одним скриптом.**

[![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu%20%7C%20Rocky%20%7C%20RHEL-orange?style=flat-square&logo=linux&logoColor=white)](https://github.com)

</div>

---

## Что это

Интерактивный bash-скрипт для быстрой оптимизации и защиты Linux-серверов. Устанавливает современное ядро, настраивает сеть на максимум и поднимает kernel-space защиту — без лишних зависимостей и ручной возни с конфигами.

Работает на **Debian/Ubuntu** и **Rocky Linux / AlmaLinux / RHEL / CentOS Stream** — ОС определяется автоматически.

---

## Возможности

### ⚡ Оптимизатор

| Компонент | Что делает |
|---|---|
| **XanMod / kernel-ml** | Свежее ядро с патчами под нагрузку *(XanMod на Debian/Ubuntu, kernel-ml через ELRepo на Rocky/RHEL)* |
| **BBRv3 + fq** | Современный алгоритм управления перегрузкой, снимает потолок по пропускной способности |
| **TCP Fast Open** | Убирает лишний RTT при установке соединения |
| **MSS Clamp** | Устраняет фрагментацию через PMTU discovery |
| **Conntrack tier-aware** | Автоматически выбирает лимиты под объём RAM сервера |

### 🛡 Защита

| Компонент | Что делает |
|---|---|
| **DDoS-фильтр** | SYN/UDP flood защита + ipset blacklist с авто-баном. Работает в kernel-space — в ~20x быстрее Fail2Ban |
| **Port scan protection** | Детект Xmas/NULL/FIN сканов через `xt_recent`, без userspace демонов |
| **Скрытность ноды** | Анти-fingerprinting sysctl, скрытие SSH banner, защита от РКН-детекта |

---

## Запуск

```bash
chmod +x server-toolkit.sh
sudo bash server-toolkit.sh
```

Появится интерактивное меню. Выбираешь нужные пункты — скрипт делает остальное.

**Или без меню, передав номер напрямую:**

```bash
sudo bash server-toolkit.sh 5    # весь оптимизатор (без ядра)
sudo bash server-toolkit.sh 10   # вся защита
sudo bash server-toolkit.sh 11   # всё сразу (без ядра)
sudo bash server-toolkit.sh 12   # всё сразу + новое ядро
```

---

## Меню

```
  ОПТИМИЗАТОР
  [1]  Ядро: XanMod (Debian/Ubuntu) / kernel-ml (Rocky/RHEL)
  [2]  BBRv3 + TCP sysctl
  [3]  MSS Clamp
  [4]  Conntrack (tier-aware по RAM)
  [5]  Весь оптимизатор (2+3+4, без ядра)
  [6]  Весь оптимизатор + новое ядро

  ЗАЩИТА
  [7]  DDoS-фильтр
  [8]  Защита от сканеров портов
  [9]  Скрытность ноды (анти-РКН)
  [10] Вся защита (7+8+9)

  КОМБО
  [11] Всё сразу (оптимизатор + защита, без ядра)
  [12] Всё сразу + новое ядро
```

---

## Поддерживаемые ОС

| Дистрибутив | Версии |
|---|---|
| Debian | 10, 11, 12 |
| Ubuntu | 20.04, 22.04, 24.04 |
| Rocky Linux | 8, 9 |
| AlmaLinux | 8, 9 |
| RHEL | 8, 9 |
| CentOS Stream | 8, 9 |

---

## Важные замечания

- После установки нового ядра (`[1]`, `[6]`, `[12]`) — **нужна перезагрузка**
- На Rocky/RHEL скрипт автоматически отключает `firewalld` и переходит на `iptables`
- Все sysctl сохраняются в `/etc/sysctl.d/99-server-toolkit.conf`
- Правила iptables персистентны: `/etc/iptables/rules.v4` (Debian) или `/etc/sysconfig/iptables` (RHEL)

---

## Лицензия

MIT
