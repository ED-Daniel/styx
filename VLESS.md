# Инструкция для Claude Code: VPN Monitoring Stack

## Контекст проекта

Мне нужно развернуть персональный VPN-сервис на базе XRay (VLESS + Reality) с полноценным мониторингом, логированием и алертингом. Всё должно работать в Docker Compose на одном VPS (Ubuntu 22.04/24.04, минимум 2GB RAM).

## Что нужно создать

Создай проект со следующей структурой и файлами:

```
vpn-stack/
├── docker-compose.yml
├── .env                          # переменные окружения (порты, домены, пароли, Telegram bot token/chat_id)
├── xray/
│   └── config.json               # конфиг XRay с VLESS + Reality + логированием в JSON
├── prometheus/
│   ├── prometheus.yml             # конфиг Prometheus: scrape targets (node-exporter, blackbox-exporter, xray metrics)
│   └── alerts.yml                 # правила алертов:
│                                  #   - xray порт недоступен (probe_success == 0, 2 мин)
│                                  #   - нет интернета через прокси (HTTP probe через xray фейлит)
│                                  #   - высокая нагрузка CPU/RAM (>85%, 5 мин)
│                                  #   - диск заполнен (>90%)
├── blackbox-exporter/
│   └── config.yml                 # модули проверок:
│                                  #   - tcp_xray: TCP probe на порт XRay
│                                  #   - http_via_proxy: HTTP GET http://cp.cloudflare.com через SOCKS/HTTP прокси XRay
├── alertmanager/
│   └── alertmanager.yml           # отправка алертов в Telegram (через webhook с bot token и chat_id из .env)
├── loki/
│   └── loki-config.yml            # конфиг Loki для хранения логов (retention 30 дней, filesystem storage)
├── promtail/
│   └── promtail-config.yml        # сбор логов из Docker контейнеров, парсинг JSON логов XRay,
│                                  #   добавление лейблов: container_name, service
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasources.yml    # автоматическое подключение Prometheus и Loki как datasources
│       └── dashboards/
│           ├── dashboards.yml     # провижининг дашбордов из файлов
│           ├── xray-overview.json # дашборд: статус XRay, результаты healthcheck проб,
│           │                      #   активные подключения, трафик, последние ошибки из логов
│           └── system.json        # дашборд: CPU, RAM, диск, сеть (на базе node-exporter)
└── scripts/
    ├── setup.sh                   # скрипт первоначальной настройки:
    │                              #   - генерация UUID для VLESS
    │                              #   - генерация ключей Reality (xray x25519)
    │                              #   - создание .env из .env.example с подстановкой сгенерированных значений
    │                              #   - создание docker network
    └── add-client.sh              # скрипт добавления нового клиента:
                                   #   - генерация UUID
                                   #   - вывод ready-to-use VLESS URI для импорта в клиент
```

## Технические требования

### XRay
- Протокол: VLESS + Reality (xtls-rprx-vision)
- Reality dest: www.google.com:443 (или другой популярный сайт)
- Логирование: уровень warning, формат JSON (для парсинга в Loki)
- Включить XRay metrics API на внутреннем порту (например, 10085) для сбора статистики Prometheus
- Включить stats и policy в конфиге для подсчёта трафика по пользователям

### Мониторинг (Prometheus)
- Scrape interval: 15s
- Targets: node-exporter:9100, blackbox-exporter:9115, xray metrics (если доступны)
- Алерты подключить через rule_files

### Healthcheck (Blackbox Exporter)
- TCP probe: проверка что XRay слушает на нужном порту
- HTTP probe via proxy: настроить модуль который делает HTTP запрос через XRay SOCKS прокси (нужен inbound socks в xray конфиге на внутреннем порту, например 10808) к http://cp.cloudflare.com — это проверяет что трафик реально ходит через VPN в интернет

### Логи (Loki + Promtail)
- Promtail собирает логи всех контейнеров через Docker socket
- JSON логи XRay парсятся (pipeline_stages с json)
- Retention: 30 дней

### Дашборды (Grafana)
- Порт: 3000
- Автоматический provisioning datasources и дашбордов при первом запуске
- Дашборд "XRay Overview":
  - Панель статуса: UP/DOWN на основе blackbox probes (stat panel, зелёный/красный)
  - График healthcheck latency по пробам
  - Лог-панель: последние логи XRay из Loki с фильтрацией по уровню (warning/error)
  - Трафик по пользователям (если метрики доступны)
- Дашборд "System":
  - CPU usage, RAM usage, Disk usage, Network I/O (стандартные node-exporter метрики)

### Алертинг (Alertmanager → Telegram)
- Telegram bot token и chat_id берутся из переменных окружения
- Шаблон сообщения: эмодзи статуса + название алерта + описание + severity
- Алерты:
  - XRayDown: TCP probe fails > 2 мин (critical)
  - NoInternetViaProxy: HTTP probe через прокси fails > 3 мин (critical)
  - HighCPU: CPU > 85% > 5 мин (warning)
  - HighMemory: RAM > 85% > 5 мин (warning)
  - DiskSpaceLow: disk usage > 90% (critical)

### Docker Compose
- Все сервисы в одной docker network (monitoring)
- Volumes для персистентности данных Prometheus, Grafana, Loki
- Restart policy: unless-stopped для всех сервисов
- Healthcheck директивы в compose для каждого сервиса
- XRay порт (443) — единственный порт наружу помимо Grafana (3000)
- Все остальные сервисы доступны только внутри docker network
- Использовать переменные из .env файла

### Скрипты
- setup.sh: должен проверять наличие docker и docker compose, генерировать UUID (`xray uuid`), генерировать Reality ключи (`xray x25519`), создавать .env, подставлять значения в конфиги
- add-client.sh: генерирует новый UUID, выводит VLESS URI в формате `vless://UUID@SERVER:PORT?type=tcp&security=reality&fp=chrome&pbk=PUBLIC_KEY&sni=SNI&sid=SHORT_ID&flow=xtls-rprx-vision#CLIENT_NAME`

## Важные замечания
- Не используй 3X-UI или Marzban — нужен чистый XRay-core для контроля и обучения
- Все пароли, токены и ключи должны быть в .env, нигде не захардкожены
- Добавь .env.example с описанием всех переменных
- Добавь README.md с описанием стека, инструкцией по запуску и описанием дашбордов
- Конфиги должны быть рабочими "из коробки" после запуска setup.sh и docker compose up -d