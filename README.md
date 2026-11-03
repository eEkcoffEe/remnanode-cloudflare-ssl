# Remnanode Cloudflare SSL

Выпуск сертификата Let's Encrypt через Cloudflare DNS-01 для Remnanode на Ubuntu 24.04, подключение сертификатов к контейнеру и автоматическое продление.

Рабочий файл `issue-ssl-cloudflare.sh` включён без изменений. Документация описывает его текущее поведение.

## Требования

- Ubuntu 24.04 с systemd, права root.
- Уже установленный Docker с командой `docker compose` и работающим Docker daemon.
- Существующий `/opt/remnanode/docker-compose.yml` с сервисом `remnanode`.
- Домен, DNS которого обслуживает Cloudflare.
- Cloudflare **API Token** с разрешением `Zone → DNS → Edit` для нужной зоны. Global API Key для этого скрипта не подходит; Zone ID не требуется.
- Исходящий доступ к репозиториям Ubuntu, Cloudflare API и Let's Encrypt по HTTPS, работающий DNS.

Входящие порты для DNS-01 открывать не нужно: сервер может находиться за NAT. Порты самого Remnanode настраиваются отдельно. При наличии Certbot вне `/usr/bin/certbot` скрипт остановится, чтобы не смешивать способы установки.

## Быстрый запуск из GitHub

В примерах **замените `YOUR_GITHUB_USER` своим логином или организацией**. Репозиторий должен называться `remnanode-cloudflare-ssl`, ветка — `main`. Все команды ниже выполняются от root.

Через клонирование репозитория:

```bash
apt-get update
apt-get install -y git
git clone https://github.com/YOUR_GITHUB_USER/remnanode-cloudflare-ssl.git
cd remnanode-cloudflare-ssl
bash issue-ssl-cloudflare.sh node-kz-01.omnihub.dpdns.org
```

Скрипт запросит API-токен скрытым вводом. Так токен не сохраняется в истории команд.

Для публичного репозитория — скачать файл и запустить одной командой (нужен `curl`):

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/remnanode-cloudflare-ssl/main/issue-ssl-cloudflare.sh -o /root/issue-ssl-cloudflare.sh && bash /root/issue-ssl-cloudflare.sh node-kz-01.omnihub.dpdns.org
```

Приватный репозиторий клонируйте с настроенной авторизацией Git; анонимная raw-ссылка для него не подойдёт.

## Параметры запуска

```text
bash issue-ssl-cloudflare.sh DOMAIN [API_TOKEN] [EMAIL]
```

Привычный запуск с токеном в аргументе:

```bash
bash issue-ssl-cloudflare.sh node-kz-01.omnihub.dpdns.org 'YOUR_CLOUDFLARE_API_TOKEN'
```

С email для учётной записи ACME:

```bash
bash issue-ssl-cloudflare.sh node-kz-01.omnihub.dpdns.org 'YOUR_CLOUDFLARE_API_TOKEN' 'admin@example.com'
```

С email и скрытым вводом токена:

```bash
bash issue-ssl-cloudflare.sh node-kz-01.omnihub.dpdns.org '' 'admin@example.com'
```

Токен в аргументе может попасть в историю shell и быть виден в списке процессов. Не публикуйте реальные токены, ключи сертификатов и SECRET_KEY в репозитории.

Запуск принимает условия Let's Encrypt. Без третьего аргумента скрипт разрешает регистрацию ACME без email. Поддерживается одно обычное DNS-имя за запуск; wildcard и список SAN эта версия не поддерживает.

## Что делает скрипт

1. Проверяет ОС, права, Docker и текущий Compose.
2. Устанавливает Certbot, DNS-плагин Cloudflare и зависимости через apt.
3. Готовит и проверяет новую конфигурацию Compose.
4. Сохраняет API-токен в `/root/.secrets/certbot/cloudflare-DOMAIN.ini` с правами `600`.
5. Выпускает сертификат в `/opt/certbot/certs`, ожидая DNS-проверку 60 секунд.
6. Создаёт и включает отдельный systemd-таймер продления.
7. Сохраняет Compose в `/opt/remnanode/docker-compose.yml.bak.XXXXXX`, затем применяет подготовленный файл.
8. Пересоздаёт только сервис `remnanode`.
9. Добавляет deploy-hook для перезапуска Remnanode после успешного продления сертификата.

В сервис добавляется или заменяется подключение к `/etc/letsencrypt`:

```yaml
    volumes:
      - '/opt/certbot/certs:/etc/letsencrypt:ro'
```

Существующие значения `NODE_PORT`, `SECRET_KEY`, `ulimits` и остальные параметры сохраняются. YAML перезаписывается через PyYAML: отступы, кавычки и оформление могут измениться, комментарии не сохраняются.

## Пересоздание контейнера и данные

Скрипт выполняет:

```bash
docker compose -f /opt/remnanode/docker-compose.yml up -d --no-deps --force-recreate --renew-anon-volumes remnanode
```

Это вызывает короткий перерыв в работе. Записываемый слой старого контейнера сбрасывается, анонимные тома заменяются новыми. Именованные тома и каталоги хоста сохраняются. Это не полная очистка Docker: `docker system prune`, удаление всех томов и очистка каталогов хоста не выполняются. Старые неиспользуемые тома могут остаться на диске.

Повторный запуск не дублирует подключение сертификатов, но снова пересоздаёт контейнер. Для обычного продления повторно запускать весь скрипт не требуется.

## Где находятся сертификаты

Для `node-kz-01.omnihub.dpdns.org`:

| Назначение | На хосте | В контейнере |
| --- | --- | --- |
| Сертификат и цепочка | `/opt/certbot/certs/live/node-kz-01.omnihub.dpdns.org/fullchain.pem` | `/etc/letsencrypt/live/node-kz-01.omnihub.dpdns.org/fullchain.pem` |
| Закрытый ключ | `/opt/certbot/certs/live/node-kz-01.omnihub.dpdns.org/privkey.pem` | `/etc/letsencrypt/live/node-kz-01.omnihub.dpdns.org/privkey.pem` |

В TLS-настройках приложения укажите пути **внутри контейнера**. Сам скрипт подключает каталог, но не редактирует TLS-конфигурацию приложения. Подключается всё дерево Certbot, чтобы ссылки из `live` в `archive` оставались рабочими.

## Автоматическое продление

После успешного завершения скрипта включён таймер `remnanode-certbot-renew.timer`. Он запускает проверку дважды в сутки — от 00:00 и 12:00 по часовому поясу сервера, со случайной задержкой до одного часа. Пропущенный запуск обрабатывается благодаря `Persistent=true`.

Команда службы:

```bash
/usr/bin/certbot renew --config-dir /opt/certbot/certs --quiet
```

Certbot обновляет сертификат, когда наступает срок продления, а не при каждой проверке. После успешного продления этого домена hook перезапускает `remnanode`, что вызывает короткий перерыв в работе. Токен должен оставаться действительным, серверу нужен доступ к API и DNS. Не удаляйте файл токена и дерево `/opt/certbot/certs`.

Проверка таймера:

```bash
systemctl is-active remnanode-certbot-renew.timer
systemctl list-timers --all remnanode-certbot-renew.timer
```

Ожидаемый результат первой команды: `active`. Служба типа `oneshot` между запусками может быть `inactive` — это нормально.

Проверка продления на тестовом сервере Let's Encrypt:

```bash
certbot renew --config-dir /opt/certbot/certs --cert-name node-kz-01.omnihub.dpdns.org --dry-run
```

Обычный `--dry-run` не выполняет deploy-hook, поэтому сам по себе не проверяет перезапуск контейнера.

Журнал автоматического продления:

```bash
journalctl -u remnanode-certbot-renew.service -n 100 --no-pager
```

Ручной запуск проверки по рабочему расписанию без принудительного перевыпуска:

```bash
systemctl start remnanode-certbot-renew.service
```

Основные служебные файлы:

- `/etc/systemd/system/remnanode-certbot-renew.service`
- `/etc/systemd/system/remnanode-certbot-renew.timer`
- `/opt/certbot/certs/renewal-hooks/deploy/50-remnanode-ssl.sh`
- `/var/log/letsencrypt/letsencrypt.log`

Стандартный `certbot.timer` не заменяет созданный таймер: по умолчанию он работает с другим каталогом. Скрипт не отключает существующие задачи Certbot.

## Диагностика

```bash
certbot certificates --config-dir /opt/certbot/certs
docker compose -f /opt/remnanode/docker-compose.yml config --quiet
docker compose -f /opt/remnanode/docker-compose.yml ps remnanode
docker compose -f /opt/remnanode/docker-compose.yml logs --tail 100 remnanode
```

При ошибке Cloudflare проверьте права токена, выбранную зону и то, что домен действительно обслуживается DNS Cloudflare. При сетевых ошибках проверьте исходящий HTTPS и DNS.

Скрипт останавливается при ошибке, но автоматического отката всех предыдущих шагов нет. Если сертификат выпущен, а пересоздание контейнера завершилось ошибкой, сохранённые сертификаты остаются на диске. Проверьте ошибку Docker и состояние сервиса. Deploy-hook создаётся после успешного выполнения команды пересоздания; при остановке на более раннем шаге завершите настройку повторным запуском после устранения причины.

Для восстановления Compose сначала найдите нужную резервную копию:

```bash
ls -lt /opt/remnanode/docker-compose.yml.bak.*
```

Замените `XXXXXX` реальным суффиксом выбранной копии:

```bash
cp /opt/remnanode/docker-compose.yml.bak.XXXXXX /opt/remnanode/docker-compose.yml
docker compose -f /opt/remnanode/docker-compose.yml config --quiet
docker compose -f /opt/remnanode/docker-compose.yml up -d --no-deps --force-recreate remnanode
```

Восстановление Compose не восстанавливает удалённые данные записываемого слоя контейнера.

## Ограничения этой версии

- Скрипт предназначен для одного сервиса `remnanode` в фиксированном каталоге `/opt/remnanode`.
- Hook имеет фиксированное имя и после повторного запуска для другого домена будет отслеживать последний указанный домен. Это не универсальный менеджер нескольких доменов.
- Если ранее сертификат выпускался в `/etc/letsencrypt`, эта версия не переносит его: она использует отдельное хранилище `/opt/certbot/certs`. Старые сертификаты и настройки остаются на месте.
- Наличие запущенного контейнера не подтверждает корректность TLS-настроек приложения; их нужно проверить отдельно.

## Загрузка проекта в GitHub

Создайте пустой репозиторий **remnanode-cloudflare-ssl**, распакуйте архив и перейдите в каталог проекта. Затем выполните с настроенной авторизацией Git:

```bash
git init
git branch -M main
git add README.md issue-ssl-cloudflare.sh .gitignore .gitattributes
git commit -m "Initial release: Cloudflare SSL for Remnanode"
git remote add origin https://github.com/YOUR_GITHUB_USER/remnanode-cloudflare-ssl.git
git push -u origin main
```

До публикации замените `YOUR_GITHUB_USER` в README своим логином. Реальные секреты в проект не включены. Не добавляйте рабочий Compose, сертификаты или резервные копии сервера.
