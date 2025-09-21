#!/usr/bin/env bash
set -euo pipefail

# deploy_spa_with_certs.sh
# Usage: ./deploy_spa_with_certs.sh <GIT_REPO> [DOMAIN]

GIT_REPO="$1"
APP_NAME=$(basename -s .git $GIT_REPO)
EMAIL="romuald.djeteje@idem.africa"

FRONT_DOMAIN_ARG="${2:-}"
DEFAULT_FRONT_DOM="${APP_NAME}.idem.africa"
FRONT_DOMAIN="${FRONT_DOMAIN_ARG:-$DEFAULT_FRONT_DOM}"

APP_BASE="/opt/vps-deployment/apps"
NGINX_DIR="/opt/vps-deployment/nginx-certbot"
NGINX_DATA_DIR="$NGINX_DIR/data"
CONF_DIR="$NGINX_DATA_DIR/nginx"
TMP_DIR="/tmp/${APP_NAME}_deploy"
TMP_INIT_BASE="$NGINX_DIR/init-letsencrypt.sh"

echo "=== Déploiement SPA conteneurisé: $APP_NAME ==="
echo "Repo: $GIT_REPO"
echo "Domaine: $FRONT_DOMAIN"
echo

mkdir -p "$APP_BASE" "$TMP_DIR"

APP_DIR="$APP_BASE/$APP_NAME"

# 1) Clone / update repo
if [ ! -d "$APP_DIR/.git" ]; then
  echo "[1/5] Clonage du repo..."
  rm -rf "$APP_DIR"
  git clone "$GIT_REPO" "$APP_DIR"
else
  echo "[1/5] Repo déjà présent, pull..."
  (cd "$APP_DIR" && git pull --rebase || true)
fi

cd "$APP_DIR"

# 2) Recherche du service SPA
SPA_SERVICE=$(yq e '.services | keys | .[]' docker-compose.yml | grep -i "$APP_NAME" | head -n1 || true)

if [ -z "$SPA_SERVICE" ]; then
  echo "[ERROR] Aucun service trouvé contenant '$APP_NAME' dans docker-compose.yml"
  exit 1
fi

SPA_CONTAINER=$(yq e ".services.$SPA_SERVICE.container_name" docker-compose.yml)
SPA_PORT=$(yq e ".services.$SPA_SERVICE.ports[0]" docker-compose.yml | cut -d: -f1)

echo "[2/5] Service trouvé: $SPA_SERVICE"
echo "Container: $SPA_CONTAINER"
echo "Port: $SPA_PORT"

# 3) Génération certificat
run_init_for_domain() {
  local domain="$1"
  local email="$2"
  local tmp_init="$TMP_DIR/init-letsencrypt-${domain}.sh"
  cp "$TMP_INIT_BASE" "$tmp_init"
  sed -i -E "s/^domains=.*/domains=($domain)/" "$tmp_init"
  sed -i -E "s/^email=.*/email=\"$email\"/" "$tmp_init"
  chmod +x "$tmp_init"
  (cd "$NGINX_DIR" && "$tmp_init")
}
run_init_for_domain "$FRONT_DOMAIN" "$EMAIL"

# 4) Création conf Nginx
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/${APP_NAME}_spa_${FRONT_DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name $FRONT_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name $FRONT_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$FRONT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FRONT_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://$SPA_CONTAINER:$SPA_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 5) Restart Nginx
echo "[5/5] Reload nginx..."
cd "$NGINX_DIR"
docker-compose exec nginx nginx -s reload || docker-compose restart nginx || true

echo "=== Déploiement SPA terminé: https://$FRONT_DOMAIN ==="
