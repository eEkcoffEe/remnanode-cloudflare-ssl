# Remnanode Cloudflare SSL

Скрипт выпускает сертификат Let’s Encrypt через Cloudflare, подключает его к контейнеру Remnanode и пересоздаёт ноду для применения изменений. Настраивает автоматическое продление сертификата и перезапуск ноды после обновления.

## Что делает скрипт

1. Проверяет Ubuntu 24.04, права root, Docker Compose и конфигурацию Remnanode.
2. Устанавливает Certbot, плагин Cloudflare и необходимые зависимости.
3. Сохраняет API-токен в `/root/.secrets/certbot/cloudflare-ДОМЕН.ini` с доступом только для root.
4. Выпускает сертификат через DNS-проверку Cloudflare в `/opt/certbot/certs`. Открывать входящие порты для выпуска не требуется.
5. Создаёт резервную копию `/opt/remnanode/docker-compose.yml` и добавляет в сервис `remnanode` подключение сертификатов только для чтения:

   ```yaml
   volumes:
     - '/opt/certbot/certs:/etc/letsencrypt:ro'
   ```

6. Пересоздаёт контейнер Remnanode: сбрасывает его записываемый слой и заменяет анонимные тома новыми. Значения `NODE_PORT`, `SECRET_KEY`, `ulimits`, именованные тома и каталоги хоста сохраняются.
7. Включает проверку продления дважды в сутки. После успешного обновления сертификата автоматически перезапускает Remnanode.

Пересоздание и перезапуск ноды вызывают короткий перерыв в работе. Скрипт подключает файлы сертификата, а пути к ним в TLS-настройках приложения нужно указать самостоятельно.

## Команды запуска

Нужны Ubuntu 24.04 с systemd, Docker Compose, curl и существующий сервис `remnanode` в `/opt/remnanode/docker-compose.yml`. Домен должен обслуживаться DNS Cloudflare, API-токену требуется право `Zone → DNS → Edit` для его зоны. Zone ID не нужен.

Выполнять от **root в Bash**. Замените домен своим при необходимости.

**Со скрытым вводом API-токена:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eEkcoffEe/remnanode-cloudflare-ssl/refs/heads/main/issue-ssl-cloudflare.sh) node-kz-01.omnihub.dpdns.org
```

**С API-токеном в команде:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eEkcoffEe/remnanode-cloudflare-ssl/refs/heads/main/issue-ssl-cloudflare.sh) node-kz-01.omnihub.dpdns.org 'ТВОЙ_API_TOKEN'
```

**С API-токеном и email:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eEkcoffEe/remnanode-cloudflare-ssl/refs/heads/main/issue-ssl-cloudflare.sh) node-kz-01.omnihub.dpdns.org 'ТВОЙ_API_TOKEN' 'admin@example.com'
```

Токен в команде может сохраняться в истории shell. Запуск принимает условия Let’s Encrypt.

## Где скрипт создаёт сертификат на сервере

Сертификат с цепочкой:

```text
/opt/certbot/certs/live/node-kz-01.omnihub.dpdns.org/fullchain.pem
```

Закрытый ключ:

```text
/opt/certbot/certs/live/node-kz-01.omnihub.dpdns.org/privkey.pem
```

## Пути сертификата внутри контейнера

Эти пути нужно указать в TLS-настройках Remnanode.

Сертификат с цепочкой:

```text
/etc/letsencrypt/live/node-kz-01.omnihub.dpdns.org/fullchain.pem
```

Закрытый ключ:

```text
/etc/letsencrypt/live/node-kz-01.omnihub.dpdns.org/privkey.pem
```

Для другого домена его имя в путях меняется соответственно. Не удаляйте каталог `/opt/certbot/certs` и файл API-токена: они нужны для автоматического продления.

## Проверка автоматического продления

Расписание проверок:

```bash
systemctl list-timers --all remnanode-certbot-renew.timer
```

Тест продления:

```bash
certbot renew --config-dir /opt/certbot/certs --cert-name node-kz-01.omnihub.dpdns.org --dry-run
```
