#!/bin/bash
set -e

chmod +x /opt/awg.sh

# 5) Создаём и включаем службу для автозапуска /opt/awg.sh
if [ ! -f /etc/systemd/system/awg-start.service ]; then
  cat <<EOF > /etc/systemd/system/awg-start.service
[Unit]
Description=Автозапуск /opt/awg.sh при старте системы
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/awg.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable awg-start.service
  echo "✔ Служба awg-start.service создана и включена"
else
  echo "✔ Служба awg-start.service уже существует"
fi

# 1) Включаем ip_forward, если ещё не включён
if ! grep -q '^net.ipv4.ip_forward = 1$' /etc/sysctl.d/00-amnezia.conf 2>/dev/null; then
  echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/00-amnezia.conf
  sysctl -p /etc/sysctl.d/00-amnezia.conf
  echo "✔ ip_forward настроен"
else
  echo "✔ ip_forward уже включён"
fi

# 2) Добавляем APT-источники только если в файле нет строки "Types: deb deb-src"
if ! grep -q '^Types: deb deb-src$' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
  mkdir -p /etc/apt/sources.list.d
  cat <<EOF > /etc/apt/sources.list.d/ubuntu.sources
Types: deb deb-src
URIs: http://de.archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  echo "✔ Источники APT записаны"
  apt update -y && apt upgrade -y
  echo "🔁 Перезагрузка для применения новых источников"
  reboot
else
  echo "✔ Источники APT уже присутствуют"
fi

# 3) Создаём WireGuard-конфиг, если ещё нет
if [ ! -f /opt/awg/wg0.conf ]; then
  mkdir -p /opt/awg
  cat <<EOF > /opt/awg/wg0.conf
[Interface]
PrivateKey = ADoqs+L9vZXOhj69a+9jhNTVjwSYyoJjkdvuL7BTeGo=
Address = 10.8.1.1/24
ListenPort = 56789
Jc = 7
Jmin = 50
Jmax = 1000
S1 = 68
S2 = 149
H1 = 1106457265
H2 = 249455488
H3 = 1209847463
H4 = 1646644382

[Peer]
PresharedKey = q6vQ8gZBjvmv7kJS0o1cWS8TB33j9zDQkE4259lSc+s=
PublicKey = 1p9eqMmN0aD4cF8shhLWWCSF1AUVAO5QZCEwwzzpVBo=
AllowedIPs = 10.8.1.2/32
EOF
  echo "✔ /opt/awg/wg0.conf создан"
else
  echo "✔ /opt/awg/wg0.conf уже существует"
fi

# 4) Устанавливаем amneziawg и настраиваем, игнорируя ошибки сборки DKMS
if ! command -v awg-quick &>/dev/null; then
  echo "🔹 Устанавливаем AmneziaWG (ошибки сборки DKMS будут проигнорированы)..."
  add-apt-repository -y ppa:amnezia/ppa      || true
  apt update -y                              || true
  apt install -y amneziawg                   || true

  echo "🔹 Поднимаем интерфейс WireGuard..."
  awg-quick up /opt/awg/wg0.conf             || true

  echo "🔹 Настраиваем nftables..."
  nft add table ip filter
  nft add chain ip filter input { type filter hook input priority 0 \; }
  nft add table ip nat
  nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
  nft add rule ip filter input udp dport 56789 iif ens3 accept
  nft add rule ip nat postrouting iif wg0 oif ens3 masquerade

  nft list ruleset > /etc/nftables.conf
  systemctl enable nftables
  systemctl restart nftables
else
  echo "✔ awg-quick уже установлен"
fi
