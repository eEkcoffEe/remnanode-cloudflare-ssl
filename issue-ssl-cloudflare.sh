#!/usr/bin/env bash
# Ubuntu 24.04: Let's Encrypt certificate using Cloudflare DNS-01.
# Usage: sudo bash issue-ssl-cloudflare.sh DOMAIN [API_TOKEN] [EMAIL]
# Without API_TOKEN, a hidden prompt is used. Requires a Cloudflare API Token,
# with Zone / DNS / Edit scoped to the domain's authoritative Cloudflare zone.
# Running this script accepts the Let's Encrypt subscriber agreement.
# Mounts certificates into remnanode and recreates that service (brief outage).
# Container writable-layer data is discarded; anonymous volumes are renewed.
# Bind mounts and named volumes are preserved. No global Docker cleanup.
set +x
set -Eeuo pipefail
umask 077
trap 'printf "Ошибка на строке %s. Исправьте причину и повторите запуск.\n" "$LINENO" >&2' ERR

die() { printf '%s\n' "$*" >&2; exit 1; }
if [[ $# -lt 1 || $# -gt 3 ]]; then
  die 'Запуск: sudo bash issue-ssl-cloudflare.sh DOMAIN [API_TOKEN] [EMAIL]'
fi
[[ $EUID -eq 0 ]] || die 'Запустите от root или через sudo bash ssl.sh ...'
domain=${1,,}
token=${2-}
email=${3-}
set --
[[ ${#domain} -le 253 && "$domain" == *.* ]] || die 'Укажите полное DNS-имя, без https://, порта и пути.'
IFS='.' read -r -a labels <<< "$domain"
[[ "$domain" != *. ]] || die 'Укажите домен без завершающей точки.'
for label in "${labels[@]}"; do
  [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Некорректное DNS-имя. Для IDN используйте punycode.'
done
[[ ! "$domain" =~ ^[0-9.]+$ ]] || die 'Нужно DNS-имя, а не IP-адрес.'
[[ -f /etc/os-release ]] || die 'Не удалось определить ОС.'
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || die 'Этот скрипт рассчитан на Ubuntu 24.04.'
[[ -d /run/systemd/system ]] || die 'Для автоматического продления требуется systemd.'
compose=/opt/remnanode/docker-compose.yml
[[ -f "$compose" && ! -L "$compose" ]] || die "Не найден обычный файл $compose"
command -v docker >/dev/null || die 'Docker не установлен.'
docker compose version >/dev/null
docker info >/dev/null
docker compose -f "$compose" config --quiet
if [[ -z "$token" ]]; then
  read -r -s -p 'Cloudflare API Token: ' token
  printf '\n'
fi
[[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Токен пуст или содержит недопустимые символы.'

# Avoid mixing a snap/pip installation with Ubuntu packages.
if command -v certbot >/dev/null 2>&1; then
  [[ "$(command -v certbot)" == /usr/bin/certbot ]] || die 'Найден Certbot вне /usr/bin. Сначала согласуйте способ установки; скрипт ничего не заменил.'
fi
printf 'Установка Certbot и Cloudflare DNS-плагина...\n'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare ca-certificates python3-yaml

# Prepare and validate the edit before requesting a certificate or stopping anything.
candidate=$(mktemp /opt/remnanode/.compose-ssl.XXXXXX.yml)
tmp=''
trap 'rm -f -- "${tmp:-}" "${candidate:-}"' EXIT
python3 - "$compose" "$candidate" <<'PY'
import sys, yaml
source, target = sys.argv[1:]
with open(source) as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict) or not isinstance(data.get('services'), dict):
    sys.exit('Некорректный Compose: нет services.')
service = data['services'].get('remnanode')
if not isinstance(service, dict):
    sys.exit('Сервис remnanode не найден.')
volumes = service.setdefault('volumes', [])
if not isinstance(volumes, list):
    sys.exit('Неожиданный формат volumes.')
mount = '/opt/certbot/certs:/etc/letsencrypt:ro'
found = False
for i, v in enumerate(volumes):
    dest = v.get('target') if isinstance(v, dict) else v.split(':')[1] if isinstance(v, str) and ':' in v else v
    if dest == '/etc/letsencrypt':
        if found:
            sys.exit('Несколько подключений /etc/letsencrypt: исправьте вручную.')
        volumes[i] = mount
        found = True
if not found:
    volumes.append(mount)
with open(target, 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True)
PY
docker compose --project-directory /opt/remnanode -f "$candidate" config --quiet

creds_dir=/root/.secrets/certbot
install -d -m 700 "$creds_dir"
creds="$creds_dir/cloudflare-$domain.ini"
tmp=$(mktemp "$creds_dir/.cloudflare.XXXXXX")
printf 'dns_cloudflare_api_token = %s\n' "$token" > "$tmp"
unset token
chmod 600 "$tmp"
mv -f -- "$tmp" "$creds"

account_args=(--register-unsafely-without-email)
if [[ -n "$email" ]]; then
  account_args=(--email "$email")
fi
printf 'Выпуск сертификата для %s (с принятием условий Let\047s Encrypt)...\n' "$domain"
install -d -m 700 /opt/certbot/certs
/usr/bin/certbot certonly \
  --config-dir /opt/certbot/certs \
  --non-interactive --agree-tos "${account_args[@]}" \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$creds" \
  --dns-cloudflare-propagation-seconds 60 \
  --cert-name "$domain" -d "$domain" --keep-until-expiring

# Dedicated timer: the standard Certbot timer uses /etc/letsencrypt.
cat > /etc/systemd/system/remnanode-certbot-renew.service <<'UNIT'
[Unit]
Description=Renew certificates in /opt/certbot/certs
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --config-dir /opt/certbot/certs --quiet
UNIT
cat > /etc/systemd/system/remnanode-certbot-renew.timer <<'UNIT'
[Unit]
Description=Check Remnanode certificates twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT
chmod 644 /etc/systemd/system/remnanode-certbot-renew.{service,timer}
systemctl daemon-reload
systemctl enable --now remnanode-certbot-renew.timer
systemctl is-active --quiet remnanode-certbot-renew.timer

backup=$(mktemp /opt/remnanode/docker-compose.yml.bak.XXXXXX)
cp -- "$compose" "$backup"
chmod 600 "$backup" "$candidate"
mv -f -- "$candidate" "$compose"
printf 'Резервная копия Compose: %s\n' "$backup"
printf 'Пересоздание remnanode: данные внутри старого контейнера будут сброшены...\n'
docker compose -f "$compose" up -d --no-deps --force-recreate --renew-anon-volumes remnanode
docker compose -f "$compose" ps remnanode

# Renewal must reload the certificate in the consuming process.
install -d -m 755 /opt/certbot/certs/renewal-hooks/deploy
hook=/opt/certbot/certs/renewal-hooks/deploy/50-remnanode-ssl.sh
hook_tmp=$(mktemp /opt/certbot/certs/renewal-hooks/deploy/.remnanode.XXXXXX)
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf '[[ "${RENEWED_LINEAGE:-}" == %q ]] || exit 0\n' "/opt/certbot/certs/live/$domain"
  printf '%q compose -f /opt/remnanode/docker-compose.yml restart remnanode\n' "$(command -v docker)"
} > "$hook_tmp"
chmod 700 "$hook_tmp"
mv -f -- "$hook_tmp" "$hook"
printf '\nСертификат выпущен или уже действителен. Таймер продления активен.\n'
printf 'Сертификат на хосте: /opt/certbot/certs/live/%s/fullchain.pem\n' "$domain"
printf 'Закрытый ключ на хосте: /opt/certbot/certs/live/%s/privkey.pem\n' "$domain"
printf 'Внутри контейнера: /etc/letsencrypt/live/%s/\n' "$domain"
printf 'Не удаляйте файл токена: %s\n' "$creds"
printf 'Проверка продления: certbot renew --config-dir /opt/certbot/certs --cert-name %s --dry-run\n' "$domain"
printf 'Каталог сертификатов подключён в remnanode только для чтения.\n'
printf 'После продления этого сертификата remnanode будет автоматически перезапущен.\n'
printf 'Пути сертификата и ключа нужно указать в TLS-настройках приложения.\n'
