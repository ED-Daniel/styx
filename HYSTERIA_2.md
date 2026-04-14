# Инструкция: развёртывание Hysteria2 рядом с VLESS+Reality

## Контекст задачи

На сервере (Linux VPS, Ubuntu 22.04/24.04) уже работает XRay с VLESS+Reality на TCP:443 (управляется через 3X-UI или standalone XRay).
Нужно поставить рядом Hysteria2 на UDP:443 — протоколы не конфликтуют, т.к. один использует TCP, другой UDP.

**Важно:** Hysteria2 НЕ совместим с Reality TLS — ему нужен свой TLS-сертификат (Let's Encrypt или встроенный ACME).

---

## Предварительные требования

- Домен (или поддомен), направленный A-записью на IP сервера (например `hy2.example.com`)
- Порт UDP/443 открыт в файрволе
- Порт TCP/80 временно открыт для получения сертификата (если используется certbot/ACME)
- Существующий XRay/VLESS+Reality продолжает работать на TCP:443 — его не трогаем

---

## Шаг 1: Установка Hysteria2

```bash
# Официальный скрипт установки
bash <(curl -fsSL https://get.hy2.sh/)
```

Скрипт установит бинарник в `/usr/local/bin/hysteria` и создаст systemd unit `hysteria-server.service`.

Проверить установку:

```bash
hysteria version
```

---

## Шаг 2: Получение TLS-сертификата

### Вариант A: Встроенный ACME в Hysteria (рекомендуется)

Hysteria сам получит и будет обновлять сертификат. В этом случае в конфиге указываешь секцию `acme` вместо `tls` — см. конфиг ниже.

**Требование:** порт TCP/443 или TCP/80 должен быть доступен для ACME challenge. Если TCP/443 уже занят XRay — используй HTTP challenge на порту 80:

```yaml
acme:
  domains:
    - hy2.example.com
  email: your-email@example.com
  listenHost: 0.0.0.0  # слушать HTTP challenge на порту 80
```

### Вариант B: Отдельный certbot

Если уже есть certbot или предпочитаешь управлять сертификатами вручную:

```bash
# Установить certbot если нет
sudo apt install certbot -y

# Получить сертификат (standalone, временно использует порт 80)
sudo certbot certonly --standalone -d hy2.example.com

# Сертификаты будут в:
# /etc/letsencrypt/live/hy2.example.com/fullchain.pem
# /etc/letsencrypt/live/hy2.example.com/privkey.pem
```

Дать Hysteria доступ к сертификатам:

```bash
sudo setfacl -R -m u:hysteria:rx /etc/letsencrypt/live/
sudo setfacl -R -m u:hysteria:rx /etc/letsencrypt/archive/
```

Или проще — запускать Hysteria от root (через systemd он и так от root работает по умолчанию).

---

## Шаг 3: Создание конфигурации сервера

```bash
sudo mkdir -p /etc/hysteria
sudo nano /etc/hysteria/config.yaml
```

### Конфиг с ACME (Вариант A):

```yaml
# /etc/hysteria/config.yaml

# Hysteria2 слушает на UDP:443
# XRay/VLESS+Reality продолжает работать на TCP:443 — конфликта нет
listen: :443

# Автоматическое получение TLS-сертификата
acme:
  domains:
    - hy2.example.com          # ЗАМЕНИТЬ на свой домен
  email: your-email@example.com # ЗАМЕНИТЬ на свой email

# Аутентификация
auth:
  type: password
  password: YOUR_STRONG_PASSWORD_HERE  # ЗАМЕНИТЬ — сгенерировать: openssl rand -base64 24

# Маскировка — при прямом HTTP-запросе к серверу проксирует реальный сайт
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# Тюнинг QUIC для производительности
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864

# Bandwidth — выставить реальную пропускную способность сервера
# Без этой секции будет использоваться BBR вместо Brutal
# bandwidth:
#   up: 100 mbps
#   down: 100 mbps
```

### Конфиг с certbot (Вариант B):

```yaml
# /etc/hysteria/config.yaml

listen: :443

tls:
  cert: /etc/letsencrypt/live/hy2.example.com/fullchain.pem   # ЗАМЕНИТЬ
  key: /etc/letsencrypt/live/hy2.example.com/privkey.pem       # ЗАМЕНИТЬ

auth:
  type: password
  password: YOUR_STRONG_PASSWORD_HERE  # ЗАМЕНИТЬ

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
```

---

## Шаг 4: Настройка systemd unit

Скрипт установки уже создаёт unit-файл. Проверить/отредактировать:

```bash
sudo systemctl edit hysteria-server.service --full
```

Убедиться что в секции `[Service]` указан путь к конфигу:

```ini
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

---

## Шаг 5: Открыть UDP порт в файрволе

```bash
# UFW
sudo ufw allow 443/udp comment "Hysteria2"
sudo ufw allow 80/tcp comment "ACME HTTP challenge"  # если используешь ACME

# Или iptables напрямую
sudo iptables -A INPUT -p udp --dport 443 -j ACCEPT

# Проверить что TCP:443 по-прежнему открыт для XRay
sudo ufw status
```

---

## Шаг 6: Запуск и проверка

```bash
# Запустить
sudo systemctl start hysteria-server

# Включить автозапуск
sudo systemctl enable hysteria-server

# Проверить статус
sudo systemctl status hysteria-server

# Посмотреть логи
sudo journalctl -u hysteria-server -f

# Убедиться что UDP:443 слушается
ss -ulnp | grep 443

# Убедиться что XRay по-прежнему работает на TCP:443
ss -tlnp | grep 443
```

Должно быть видно:
- Hysteria на UDP:443
- XRay на TCP:443

---

## Шаг 7 (опционально): Port Hopping

Если провайдер блокирует конкретные UDP-порты, можно настроить port hopping — клиент будет прыгать по диапазону портов, а сервер перенаправлять их на 443.

```bash
# nftables — перенаправление диапазона UDP-портов на 443
sudo nft add table inet hysteria_porthopping
sudo nft add chain inet hysteria_porthopping prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
sudo nft add rule inet hysteria_porthopping prerouting iifname "eth0" udp dport 20000-50000 counter redirect to :443

# Открыть диапазон в файрволе
sudo ufw allow 20000:50000/udp comment "Hysteria2 port hopping"
```

Сделать правила nftables постоянными:

```bash
sudo apt install nftables -y
sudo nft list ruleset > /etc/nftables.conf
sudo systemctl enable nftables
```

**Примечание:** port hopping поддерживается только нативным клиентом Hysteria2, НЕ sing-box.

---

## Шаг 8 (опционально): Salamander обфускация

Для российских провайдеров с активной блокировкой QUIC можно включить Salamander. Добавить в серверный конфиг:

```yaml
obfs:
  type: salamander
  salamander:
    password: YOUR_OBFS_PASSWORD_HERE  # ЗАМЕНИТЬ — отдельный пароль от auth
```

**Важно:** при включённом Salamander сервер перестаёт отвечать на стандартные QUIC/HTTP3 запросы. Masquerade не работает. Секцию `masquerade` можно убрать.

Этот же obfs-пароль нужно указать на клиенте.

---

## Шаг 9 (опционально): Админ-панель Blitz

Если нужен веб-интерфейс для управления пользователями Hysteria2:

```bash
bash <(curl https://raw.githubusercontent.com/ReturnFI/Blitz/main/install.sh)
```

После установки управление через команду `hys2`. Панель предоставляет:
- Управление пользователями
- Мониторинг трафика
- Telegram-бот
- Генерацию подписок и ссылок для клиентов

**Альтернативы:** H-UI (github.com/jonssonyan/h-ui), CELERITY Panel (поддерживает и Hysteria2, и VLESS).

---

## Клиентские конфигурации

### URI для быстрого импорта в клиенты

```
hy2://YOUR_STRONG_PASSWORD_HERE@hy2.example.com:443?sni=hy2.example.com#Hysteria2
```

С Salamander:

```
hy2://YOUR_STRONG_PASSWORD_HERE@hy2.example.com:443?sni=hy2.example.com&obfs=salamander&obfs-password=YOUR_OBFS_PASSWORD_HERE#Hysteria2-obfs
```

С port hopping:

```
hy2://YOUR_STRONG_PASSWORD_HERE@hy2.example.com:20000-50000?sni=hy2.example.com#Hysteria2-hop
```

### Нативный клиент (YAML-конфиг)

```yaml
server: hy2.example.com:443  # или :20000-50000 для port hopping

auth: YOUR_STRONG_PASSWORD_HERE

tls:
  sni: hy2.example.com
  insecure: false

# Указать реальную пропускную способность клиента для Brutal
bandwidth:
  up: 20 mbps
  down: 100 mbps

# Раскомментировать для port hopping
# transport:
#   udp:
#     hopInterval: 30s

# Раскомментировать если на сервере включён Salamander
# obfs:
#   type: salamander
#   salamander:
#     password: YOUR_OBFS_PASSWORD_HERE

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
```

### sing-box конфиг (для Hiddify/NekoBox)

```json
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-out",
      "server": "hy2.example.com",
      "server_port": 443,
      "password": "YOUR_STRONG_PASSWORD_HERE",
      "tls": {
        "enabled": true,
        "server_name": "hy2.example.com"
      }
    }
  ]
}
```

С Salamander в sing-box:

```json
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-out",
      "server": "hy2.example.com",
      "server_port": 443,
      "password": "YOUR_STRONG_PASSWORD_HERE",
      "obfs": {
        "type": "salamander",
        "password": "YOUR_OBFS_PASSWORD_HERE"
      },
      "tls": {
        "enabled": true,
        "server_name": "hy2.example.com"
      }
    }
  ]
}
```

---

## Рекомендуемые клиенты

| Платформа     | Клиент                        | Примечание                                |
|---------------|-------------------------------|-------------------------------------------|
| Android       | Hiddify (бесплатно)           | Импорт по hy2:// ссылке                   |
| Android       | NekoBox (бесплатно, GitHub)   | Ядро sing-box, ручная настройка           |
| iOS           | Shadowrocket ($2.99)          | Поддержка hy2:// с версии 2.2.35          |
| iOS           | Hiddify (бесплатно)           | Импорт по hy2:// ссылке                   |
| iOS           | Streisand (бесплатно)         | Поддержка с версии 1.5.6                  |
| Windows       | Hiddify                       | Кроссплатформенный, sing-box              |
| Windows       | NekoBox/NekoRay               | Самый функциональный GUI                  |
| Windows       | v2rayN                        | Поддержка Hysteria2                       |
| macOS         | Hiddify / NekoBox / Stash     |                                           |
| Linux         | Нативный hysteria CLI         | Единственный с port hopping               |
| Linux         | NekoBox/NekoRay               | GUI на Qt                                 |

---

## Проверка работоспособности

```bash
# На сервере — убедиться что оба сервиса работают
sudo systemctl status hysteria-server
sudo systemctl status xray  # или 3x-ui

# Проверить прослушиваемые порты
ss -tulnp | grep 443

# Ожидаемый вывод (примерно):
# udp  UNCONN  0  0  *:443  *:*  users:(("hysteria",...))
# tcp  LISTEN  0  0  *:443  *:*  users:(("xray",...))

# Логи Hysteria
sudo journalctl -u hysteria-server --no-pager | tail -30
```

---

## Итоговая архитектура

```
                          ┌──────────────────────────────┐
                          │        VPS (одна ВМ)         │
                          │                              │
  Клиент ──TCP:443──────► │  XRay (VLESS+Reality)        │
                          │  Управление: 3X-UI           │
                          │                              │
  Клиент ──UDP:443──────► │  Hysteria2 (standalone)      │
                          │  Управление: Blitz / CLI     │
                          │                              │
                          └──────────────────────────────┘
```

Оба протокола работают параллельно на одном IP и порту 443, но на разных транспортах (TCP vs UDP). Для клиента это два разных профиля — можно переключаться в зависимости от ситуации:
- **Hysteria2** — когда нужна скорость и UDP не заблокирован
- **VLESS+Reality** — когда нужна максимальная скрытность или UDP заблокирован

---

## Частые проблемы

1. **Hysteria не стартует, ошибка bind** — проверь что UDP:443 не занят другим процессом: `ss -ulnp | grep 443`
2. **ACME не получает сертификат** — убедись что домен резолвится в IP сервера, порт 80 открыт и не занят
3. **Клиент не подключается** — проверь что UDP:443 открыт в файрволе VPS-провайдера (не только на уровне ОС, но и в веб-панели хостера)
4. **Низкая скорость** — проверь настройку `bandwidth` на клиенте и сервере. Завышенные значения хуже заниженных
5. **Работает, но блокируется провайдером** — попробуй включить Salamander obfuscation или port hopping