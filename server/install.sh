#!/usr/bin/env bash
# Установка и обновление сервера для сериалов.
# curl -fsSL https://raw.githubusercontent.com/cpok66/series-app/main/server/install.sh | bash
set -euo pipefail
trap 'echo "!!! Ошибка на строке $LINENO: $BASH_COMMAND"' ERR

DIR=/opt/series
REPO=https://github.com/cpok66/series-app.git

[[ $EUID -eq 0 ]] || { echo "Запусти от root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "==> Ставлю git и Docker"
apt-get update -y >/dev/null
apt-get install -y git curl openssl >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  apt-get install -y docker.io >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 \
    || apt-get install -y docker-compose-plugin >/dev/null 2>&1 \
    || curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "Не удалось установить docker compose"; exit 1; }
systemctl enable --now docker >/dev/null 2>&1 || true

echo "==> Скачиваю код"
if [[ -d $DIR/.git ]]; then
  git -C "$DIR" pull -q
else
  git clone -q "$REPO" "$DIR"
fi
cd "$DIR/server"

if [[ ! -f .env ]]; then
  IP=$(curl -4 -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')
  PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
  TMDB=""
  if [[ -r /dev/tty ]]; then
    read -rp "Ключ TMDB для постеров (Enter, чтобы пропустить): " TMDB </dev/tty || TMDB=""
  fi
  cat > .env <<EOF
APP_PASSWORD=$PASS
TMDB_KEY=$TMDB
DOMAIN=${IP//./-}.sslip.io
EOF
  chmod 600 .env
fi
mkdir -p data

echo "==> Собираю и запускаю (первый раз пару минут)"
docker compose up -d --build >/dev/null 2>&1 || docker compose up -d --build

set -a; source .env; set +a
echo
echo "================ ГОТОВО ================"
echo "Адрес для браузера и приложения:"
echo "  https://$DOMAIN:8443"
echo "Пароль: $APP_PASSWORD"
echo
echo "Сертификат выпускается в течение минуты после первого запуска."
echo "Показать данные снова: cat $DIR/server/.env"
echo "Добавить ключ TMDB позже: nano $DIR/server/.env, затем"
echo "  cd $DIR/server && docker compose up -d"
