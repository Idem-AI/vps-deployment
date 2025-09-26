#!/usr/bin/env bash
set -euo pipefail

# deploy_app_with_certs.sh
# Usage:
# ./deploy_app_with_certs.sh  <GIT_REPO> [DOMAIN] 
# Examples:
# ./deploy_app_with_certs.sh  https://git.example.com/myapp.git larc.cm
# ./deploy_app_with_certs.sh  https://git.example.com/myapp.git  larc.cm 
GIT_REPO="$1"
APP_NAME=$(basename -s .git $GIT_REPO)
EMAIL="romuald.djeteje@idem.africa"            # optional
FRONT_DOMAIN_ARG="${2:-}"
BACK_DOMAIN_ARG="api.${FRONT_DOMAIN_ARG}"   

# Config (modifiable)
APP_BASE="/opt/vps-deployment/apps"                      # où on clone les apps
NGINX_DIR="/opt/vps-deployment/nginx-certbot"            # repo nginx-certbot existant
NGINX_DATA_DIR="$NGINX_DIR/data"
CONF_DIR="$NGINX_DATA_DIR/nginx"          # dossier cible pour les .conf (adaptable)
TMP_DIR="/tmp/${APP_NAME}_deploy"
TMP_INIT_BASE="$NGINX_DIR/init-letsencrypt.sh"  # template d'origine dans le repo
DEFAULT_FRONT_DOM="${APP_NAME}.idem.africa"
DEFAULT_BACK_DOM="api.${APP_NAME}.idem.africa"

FRONT_DOMAIN="${FRONT_DOMAIN_ARG:-$DEFAULT_FRONT_DOM}"
BACK_DOMAIN="${FRONT_DOMAIN_ARG:-$DEFAULT_BACK_DOM}"



# Fallback ports
DEFAULT_FRONT_PORT=3000
DEFAULT_BACK_PORT=8000

echo "=== Déploiement: $APP_NAME ==="
echo "Repo: $GIT_REPO"
echo "Email: ${EMAIL:-(none)}"
echo "Frontend domain: $FRONT_DOMAIN"
echo "Backend domain:  $BACK_DOMAIN"
echo "NGINX Dir: $NGINX_DIR"
echo

mkdir -p "$APP_BASE" "$TMP_DIR"

APP_DIR="$APP_BASE/$APP_NAME"

# 1) Cloner / update app
if [ ! -d "$APP_DIR/.git" ]; then
  echo "[1/6] Clonage du repo dans $APP_DIR..."
  rm -rf "$APP_DIR"
  git clone "$GIT_REPO" "$APP_DIR"
else
  echo "[1/6] Repo déjà présent, pull..."
  (cd "$APP_DIR" && git pull --rebase || true)
fi

# 2) Lancer docker-compose de l'app
echo "[2/6] Lancement docker-compose de l'application..."


echo "Gestion des variables d'environnements..."

echo "copie du .env dans le repertoire de deploiement..."

# Vérifier si le .env existe dans APP_BASE
if [ ! -f "$APP_BASE/.env" ]; then
  echo "Aucun .env trouvé dans $APP_BASE, création d'un fichier vide..."
  touch "$APP_BASE/.env"
fi

# S'assurer que le répertoire docker existe
mkdir -p "$APP_DIR/"

# Déplacer le .env
mv "$APP_BASE/.env" "$APP_DIR/"


COMPOSE_FILE="$APP_DIR/docker/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

# Ajouter API_URL dans le .env
echo "API_URL=https://$BACK_DOMAIN" >> "$ENV_FILE"
echo "  -> Ajout API_URL=https://$BACK_DOMAIN dans .env"

# Récupérer tous les services et leur ajouter env_file

echo "[+] Ajout de env_file: .env dans tous les services de $COMPOSE_FILE"

# Extraire les services (indentés sous services:)
services=$(awk '/^services:/ {in_services=1; next} in_services && /^[^[:space:]]/ {exit} in_services && /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {print $1}' "$COMPOSE_FILE" | sed 's/://')

for svc in $services; do
  echo "  -> Service: $svc"
  # Vérifier si déjà présent
  if grep -A5 "^[[:space:]]{2}$svc:" "$COMPOSE_FILE" | grep -q "env_file:"; then
    echo "     (déjà présent, ignoré)"
  else
    # Ajouter env_file après la ligne du service
    sed -i "/^[[:space:]]\{2\}$svc:/a\ \ \ \ env_file:\n\ \ \ \ \ \ - .env" "$COMPOSE_FILE"
    echo "     (ajouté)"
  fi
done

echo "[✓] Terminé"

cd "$APP_DIR/docker"

#docker-compose down || true
docker-compose up -d --remove-orphans

# helper: find first service name in compose file or running compose containers that contains a word
find_service_by_keyword() {
  local keyword="$1"
  # prefer docker-compose service names
  svc=$(docker-compose config --services 2>/dev/null | grep -i "$keyword" | head -n1 || true)
  if [ -n "$svc" ]; then
    echo "$svc"
    return 0
  fi
  # fallback: search running containers names for the keyword
  cnt=$(docker ps --format '{{.Names}}' | grep -i "$keyword" | head -n1 || true)
  if [ -n "$cnt" ]; then
    echo "$cnt"
    return 0
  fi
  echo "container/service not found for keyword '$keyword'"
  return 0
}

# helper: given a docker-compose service name (or container name), get container ID
get_container_id_for_service() {
  local svc="$1"
  # try docker-compose ps -q <service>
  cid=$(docker-compose ps -q "$svc" 2>/dev/null || true)
  if [ -n "$cid" ]; then
    echo "$cid"
    return 0
  fi
  # else try docker ps by name match
  cid=$(docker ps --filter "name=$svc" --format '{{.ID}}' | head -n1 || true)
  echo "${cid:-}"
}

# helper: get container name (trim leading /)
get_container_name() {
  local cid="$1"
  docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#\/##'
}

# helper: get internal port used by container (first key in NetworkSettings.Ports or Config.ExposedPorts)
get_internal_port() {
  local cid="$1"
  # try NetworkSettings.Ports keys (they contain "8000/tcp")
  ports_keys=$(docker inspect --format '{{range $p,$v := .NetworkSettings.Ports}}{{printf "%s " $p}}{{end}}' "$cid" 2>/dev/null || true)
  if [ -n "$ports_keys" ]; then
    first_key=$(echo "$ports_keys" | awk '{print $1}')
    echo "${first_key%%/*}"
    return 0
  fi
  # try Config.ExposedPorts
  exposed=$(docker inspect --format '{{range $p,$v := .Config.ExposedPorts}}{{printf "%s " $p}}{{end}}' "$cid" 2>/dev/null || true)
  if [ -n "$exposed" ]; then
    first_key=$(echo "$exposed" | awk '{print $1}')
    echo "${first_key%%/*}"
    return 0
  fi
  # nothing found
  echo ""
  return 1
}

# 3) Detecter les services frontend & backend
echo "[3/6] Détection services frontend & backend dans le docker-compose..."
FRONT_SVC=$(find_service_by_keyword "frontend")
BACK_SVC=$(find_service_by_keyword "backend")

if [ -z "$FRONT_SVC" ]; then
  echo "  ! Aucun service contenant 'frontend' trouvé. On tentera de detecter un service $APP_NAME ."
  FRONT_SVC=""
else
  echo "  -> frontend service detected: $FRONT_SVC"
fi

if [ -z "$BACK_SVC" ]; then
  echo "  ! Aucun service contenant 'backend' trouvé. On tentera de detecter un service ${APP_NAME}-api ."
  BACK_SVC=""
else
  echo "  -> backend service detected: $BACK_SVC"
fi

if [ -z "$FRONT_SVC" ]; then
  FRONT_SVC=$(find_service_by_keyword "$APP_NAME")
fi
if [ -z "$BACK_SVC" ]; then
  BACK_SVC=$(find_service_by_keyword "${APP_NAME}-api")
fi


if [ -z "$FRONT_SVC" ]; then
  echo "  ! Aucun service contenant 'frontend' trouvé. On tentera de detecter un container 'front' ou on utilisera fallback."
  FRONT_SVC=""
else
  echo "  -> frontend service detected: $FRONT_SVC"
fi

if [ -z "$BACK_SVC" ]; then
  echo "  ! Aucun service contenant 'backend' trouvé. On tentera de detecter un container 'back' ou on utilisera fallback."
  BACK_SVC=""
else
  echo "  -> backend service detected: $BACK_SVC"
fi

# try to use the container names if services not found
if [ -z "$FRONT_SVC" ]; then
  FRONT_SVC=$(docker ps --format '{{.Names}}' | grep -i 'front' | head -n1 || true)
fi
if [ -z "$BACK_SVC" ]; then
  BACK_SVC=$(docker ps --format '{{.Names}}' | grep -i 'back' | head -n1 || true)
fi

# get container ids
FRONT_CID=""
BACK_CID=""
if [ -n "$FRONT_SVC" ]; then FRONT_CID=$(get_container_id_for_service "$FRONT_SVC" || true); fi
if [ -n "$BACK_SVC" ]; then BACK_CID=$(get_container_id_for_service "$BACK_SVC" || true); fi

# if still empty try to find by image or by exposing common ports on docker ps
if [ -z "$FRONT_CID" ]; then
  # search for containers exposing common front ports
  FRONT_CID=$(docker ps --format '{{.ID}} {{.Ports}}' | grep -E '3000|8080|80' | awk '{print $1}' | head -n1 || true)
fi
if [ -z "$BACK_CID" ]; then
  BACK_CID=$(docker ps --format '{{.ID}} {{.Ports}}' | grep -E '8000|5000|3000' | awk '{print $1}' | head -n1 || true)
fi

# derive container names and internal ports
if [ -n "$FRONT_CID" ]; then
  FRONT_CONTAINER_NAME=$(get_container_name "$FRONT_CID")
  FRONT_INTERNAL_PORT=$(get_internal_port "$FRONT_CID" || true)
  if [ -z "$FRONT_INTERNAL_PORT" ]; then FRONT_INTERNAL_PORT=$DEFAULT_FRONT_PORT; fi
  echo "  frontend container: $FRONT_CONTAINER_NAME (internal port: $FRONT_INTERNAL_PORT)"
else
  echo "  ! frontend container introuvable — utilisation d'un target par défaut (frontend:$DEFAULT_FRONT_PORT)"
  FRONT_CONTAINER_NAME="frontend"
  FRONT_INTERNAL_PORT=$DEFAULT_FRONT_PORT
fi

if [ -n "$BACK_CID" ]; then
  BACK_CONTAINER_NAME=$(get_container_name "$BACK_CID")
  BACK_INTERNAL_PORT=$(get_internal_port "$BACK_CID" || true)
  if [ -z "$BACK_INTERNAL_PORT" ]; then BACK_INTERNAL_PORT=$DEFAULT_BACK_PORT; fi
  echo "  backend container:  $BACK_CONTAINER_NAME (internal port: $BACK_INTERNAL_PORT)"
else
  echo "  ! backend container introuvable — utilisation d'un target par défaut (backend:$DEFAULT_BACK_PORT)"
  BACK_CONTAINER_NAME="backend"
  BACK_INTERNAL_PORT=$DEFAULT_BACK_PORT
fi

# 4) Vérifier repo nginx-certbot et démarrer nginx
if [ ! -d "$NGINX_DIR" ]; then
  echo "[ERROR] Le dépôt nginx-certbot n'existe pas en $NGINX_DIR. Ce script s'appuie sur ce dépôt (cas A)."
  exit 1
fi

echo "[4/6] Préparation nginx-certbot..."
cd "$NGINX_DIR"
# démarrer nginx (service nommé 'nginx' dans le repo)

docker-compose up -d nginx || docker-compose up -d || true
echo "debut detection du service.."
# détecter le réseau du container nginx pour y connecter les app containers
NGINX_CID=$(docker-compose ps -q nginx 2>/dev/null || docker ps --filter "ancestor=nginx" --format '{{.ID}}' | head -n1 || true)
echo "detection service terminer..."

if [ -n "$NGINX_CID" ]; then
  NETWORK_NAME=$(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$NGINX_CID" | awk '{print $1}')
  if [ -z "$NETWORK_NAME" ]; then NETWORK_NAME="proxy_net"; fi
else
  NETWORK_NAME="proxy_net"
fi
echo "  nginx network: $NETWORK_NAME"

# ensure network exists
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME"

# connect app containers to nginx network
connect_to_network_if_needed() {
  local cid="$1"
  local net="$2"
  if [ -z "$cid" ]; then return; fi
  already=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$cid" | grep -o "$net" || true)
  if [ -z "$already" ]; then
    echo "  -> Connecting container $cid to network $net"
    docker network connect "$net" "$cid" >/dev/null 2>&1 || true
  fi
}
connect_to_network_if_needed "$FRONT_CID" "$NETWORK_NAME"
connect_to_network_if_needed "$BACK_CID" "$NETWORK_NAME"

# 5) Générer certificats distincts via copie du init-letsencrypt.sh
# template must exist
if [ ! -f "$TMP_INIT_BASE" ]; then
  echo "[ERROR] Template init-letsencrypt.sh introuvable dans $TMP_INIT_BASE. Vérifie le repo nginx-certbot."
  exit 1
fi

run_init_for_domain() {
  local domain="$1"
  local email="$2"
  local tmp_init="$TMP_DIR/init-letsencrypt-${domain}.sh"
  cp "$TMP_INIT_BASE" "$tmp_init"
  # compose domains array; single domain only here
  # Attempt to replace a line like: domains=(example.org www.example.org)
  sed -i -E "s/^domains=.*/domains=($domain)/" "$tmp_init" || true
  # replace email if present line email=""
  if [ -n "$email" ]; then
    sed -i -E "s/^email=.*/email=\"$email\"/" "$tmp_init" || true
  # else
  #  sed -i -E "s/^email=.*/email=\"\"/" "$tmp_init" || true
  fi
  chmod +x "$tmp_init"
  echo "  -> Requesting certificate for $domain ..."
  # run it from nginx dir so docker-compose there is used
  (cd "$NGINX_DIR" && "$tmp_init")
}



# 5) Générer les fichiers .conf nginx (un par service/domain) dans $CONF_DIR

mkdir -p "$CONF_DIR"

generate_conf_file() {
  local domain="$1"
  local container_target="$2"  # container:port
  local out="$3"

  cat > "$out" <<EOF
server {
    listen 80;
    server_name $domain;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $domain;
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://$container_target;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  echo "  -> wrote $out (proxy -> $container_target)"
}

# compose target strings
FRONT_TARGET="${FRONT_CONTAINER_NAME}:${FRONT_INTERNAL_PORT}"
BACK_TARGET="${BACK_CONTAINER_NAME}:${BACK_INTERNAL_PORT}"

echo "[5/6] Création des fichiers nginx .conf pour frontend & Génération des certificats Let's Encrypt..."

generate_conf_file "$FRONT_DOMAIN" "$FRONT_TARGET" "$CONF_DIR/${APP_NAME}_frontend_${FRONT_DOMAIN}.conf"
run_init_for_domain "$FRONT_DOMAIN" "$EMAIL"

echo "[6/6] Création des fichiers nginx .conf pour backend & Génération des certificats Let's Encrypt..."

generate_conf_file "$BACK_DOMAIN"  "$BACK_TARGET"  "$CONF_DIR/${APP_NAME}_backend_${BACK_DOMAIN}.conf"
run_init_for_domain "$BACK_DOMAIN" "$EMAIL"


# reload nginx
echo "Reloading nginx to apply new confs..."
cd "$NGINX_DIR"
docker-compose exec nginx nginx -s reload || docker-compose restart nginx || true

echo
echo "=== Déploiement terminé pour $APP_NAME ==="
echo "Frontend is exposed at: https://$FRONT_DOMAIN -> $FRONT_TARGET"
echo "Backend  is exposed at: https://$BACK_DOMAIN  -> $BACK_TARGET"
echo
echo "Note: Assure-toi que les enregistrements DNS (A/AAAA) pour $FRONT_DOMAIN et $BACK_DOMAIN pointent vers l'IP du VPS avant d'exécuter ce script."
