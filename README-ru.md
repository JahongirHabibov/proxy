# Traefik Reverse Proxy

Reverse Proxy на базе Docker с использованием Traefik v3. Маршрутизирует несколько доменов к отдельным контейнерам на одном сервере. SSL выдаётся и обновляется автоматически через Let's Encrypt.

## Возможности

- Автоматический HTTPS через Let's Encrypt (бесплатно, автообновление)
- Редирект HTTP → HTTPS (301 Permanent)
- Редирект www → без www (301 Permanent)
- Dashboard Traefik с BasicAuth
- Docker socket proxy (защита — Traefik не имеет прямого доступа к сокету)
- Глобальные заголовки безопасности (HSTS, защита от XSS и др.)
- Все чувствительные данные управляются через `.env`

## Требования

- Docker + Docker Compose v2
- DNS: A-запись для каждого домена (и `www.*`), указывающая на IP сервера
- `apache2-utils` для генерации паролей: `sudo apt install apache2-utils`

## Установка

### 1. Клонирование и конфигурация

```bash
git clone <repo-url>
cd proxy
make setup       # создаёт .env из .env.example и traefik/acme.json с правами chmod 600
```

### 2. Редактирование `.env`

```dotenv
ACME_EMAIL=your@email.com
TRAEFIK_DOMAIN=proxy.yourdomain.com
DASHBOARD_USERS=admin:$$apr1$$...
NETWORK_NAME=proxy-network
```

Генерация значения `DASHBOARD_USERS`:

```bash
make gen-password
# Введите имя пользователя и пароль → скопируйте вывод в .env
```

### 3. Запуск прокси

```bash
make up
```

Traefik запущен. Dashboard доступен по адресу `https://<TRAEFIK_DOMAIN>` после настройки DNS.

## Добавление сайта

Каждый сайт — отдельный проект. Скопируйте labels из `docs/app-example/docker-compose.yml` в `docker-compose.yml` вашего приложения.

**Что заменить:**

| Placeholder | Замените на |
|-------------|-------------|
| `example.com` | ваш домен (например, `mysite.de`) |
| `myapp` | уникальное короткое имя (например, `mysite`) |
| `3000` | внутренний порт контейнера |

**Требование по DNS:** Оба домена `example.com` и `www.example.com` должны иметь A-запись, указывающую на IP сервера, прежде чем запускать приложение — Let's Encrypt должен достучаться до домена для выдачи сертификата.

Затем запустите приложение:

```bash
docker compose up -d
```

Traefik автоматически обнаружит контейнер и сразу выпустит SSL-сертификат.

## Сайты клиентов (один стек, много хостов)

Стек клиентских сайтов KASSIO (`retail-website-template`) не использует labels:
одно развёртывание обслуживает всех клиентов, поэтому хосты неизвестны на старте.
Вместо этого он пишет **по одному файлу роутера на сайт** в Docker-волюм, общий с
этим проектом:

```
website api  ──пишет──→  волюм traefik-dynamic  ──читает──→  file provider Traefik
  (uid 10001, rw)          site-<slug>.yml                    директория /config
```

`make setup` создаёт волюм, назначает владельцем uid api сайтов и копирует туда
`dynamic.yml` этого проекта. В работающем контейнере `dynamic.yml` монтируется
**поверх** волюма, поэтому правки по-прежнему применяются на горячую; копия внутри
волюма — резерв на случай запуска без этого монтирования (иначе Traefik прочитал
бы пустой файл и потерял все middlewares, включая `security-headers@file`).

Волюм смонтирован на запись по одной технической причине: runc не может создать
точку монтирования для вложенного `dynamic.yml` внутри read-only монтирования.
Traefik в него не пишет.

Действий на каждого клиента нет — маршруты создаёт и удаляет CLI самого стека
сайтов (`make sites CMD="create laden"`, `… CMD="reconcile"` в том репозитории).
Маршруты — производное состояние: если волюм потерян, `reconcile` восстановит все
файлы из базы сайтов.

## Структура проекта

```
proxy/
├── traefik/
│   ├── traefik.yml          # Статическая конфигурация (entrypoints, providers, API)
│   ├── config/
│   │   └── dynamic.yml      # Глобальные middlewares (www-redirect, security-headers)
│   └── acme.json            # Сертификаты Let's Encrypt — никогда не коммитить
├── docker-compose.yml
├── .env                     # Секреты — никогда не коммитить
├── .env.example             # Шаблон для .env
├── .gitignore
├── Makefile
└── docs/
    └── app-example/
        └── docker-compose.yml  # Шаблон для проектов приложений
```

## Команды Makefile

| Команда | Действие |
|---------|----------|
| `make setup` | Создать `.env` из шаблона, инициализировать `acme.json`, создать волюм `traefik-dynamic` |
| `make sync-config` | Скопировать `dynamic.yml` в волюм (резервная копия; входит в `setup`/`up`) |
| `make up` | Запустить прокси в фоне |
| `make down` | Остановить прокси |
| `make logs` | Логи Traefik в реальном времени |
| `make restart` | Перезапустить контейнер Traefik |
| `make gen-password` | Сгенерировать BasicAuth хэш для `DASHBOARD_USERS` |

## Безопасность

- `traefik/acme.json` содержит приватные ключи Let's Encrypt — хранить только на сервере
- `.env` содержит секреты — никогда не коммитить
- Traefik подключается к Docker через socket-proxy, а не напрямую через `/var/run/docker.sock`
- Dashboard защищён BasicAuth через HTTPS
