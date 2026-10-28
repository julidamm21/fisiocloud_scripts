#!/usr/bin/env bash
# =============================================================================
# Fisiocloud — script ÚNICO de configuración y arranque de la aplicación
# Incluye: variables de entorno, nginx (conf embebida) y procesos Python.
#
# Prerrequisitos:
#   - Infra Docker / servidor con Python, nginx, MariaDB
#   - BD instalada:  mysql … < scripts/fisiocloud_init.sql
#
# Uso:
#   bash /app/scripts/fisiocloud_setup.sh          # dentro del contenedor
#   bash app/scripts/fisiocloud_setup.sh           # desde el repo
# =============================================================================
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="${APP_ROOT}${PYTHONPATH:+:$PYTHONPATH}"
export DJANGO_DEBUG="${DJANGO_DEBUG:-1}"

# --- Entorno de la aplicación (microservicios) ---
export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-3306}"
export DB_USER="${DB_USER:-root}"
export DB_PASSWORD="${DB_PASSWORD:-root}"
export JWT_SECRET="${JWT_SECRET:-fisiocloud-dev-secret-change-me}"
export SEGURIDAD_URL="${SEGURIDAD_URL:-http://127.0.0.1:8101}"
export SUSCRIPCION_URL="${SUSCRIPCION_URL:-http://127.0.0.1:8102}"
export INFO_MEDICA_URL="${INFO_MEDICA_URL:-http://127.0.0.1:8103}"
export AGENDAMIENTO_URL="${AGENDAMIENTO_URL:-http://127.0.0.1:8104}"
export PARAMETRIZACION_URL="${PARAMETRIZACION_URL:-http://127.0.0.1:8105}"
export TRATAMIENTO_CASA_URL="${TRATAMIENTO_CASA_URL:-http://127.0.0.1:8106}"
export SOPORTE_URL="${SOPORTE_URL:-http://127.0.0.1:8107}"
export PROCESOS_AUTOMATICOS_URL="${PROCESOS_AUTOMATICOS_URL:-http://127.0.0.1:8108}"
export ASISTENTE_VOZ_URL="${ASISTENTE_VOZ_URL:-http://127.0.0.1:8109}"
export FRONTEND_URL="${FRONTEND_URL:-http://127.0.0.1:8089}"

PIDS=()
cleanup() {
  echo "Deteniendo servicios Python..."
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# nginx: parámetros de proxy + site Fisiocloud
# -----------------------------------------------------------------------------
setup_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    echo "AVISO: nginx no está instalado; se omiten APIs vía /svc/"
    return 0
  fi

  cat > /etc/nginx/fisiocloud_proxy_params.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Authorization $http_authorization;
proxy_set_header Connection "";
proxy_read_timeout 120s;
proxy_connect_timeout 10s;
client_max_body_size 200M;
EOF

  cat > /etc/nginx/sites-available/fisiocloud.conf <<EOF
# Entrada única Fisiocloud (generado por fisiocloud_setup.sh)
upstream fisiocloud_frontend { server 127.0.0.1:8000; }
upstream svc_seguridad { server 127.0.0.1:8101; }
upstream svc_suscripcion { server 127.0.0.1:8102; }
upstream svc_info_medica { server 127.0.0.1:8103; }
upstream svc_agendamiento { server 127.0.0.1:8104; }
upstream svc_parametrizacion { server 127.0.0.1:8105; }
upstream svc_tratamiento_casa { server 127.0.0.1:8106; }
upstream svc_soporte { server 127.0.0.1:8107; }
upstream svc_procesos_automaticos { server 127.0.0.1:8108; }
upstream svc_asistente_voz { server 127.0.0.1:8109; }

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 200M;

    location ^~ /landing/ {
        root ${APP_ROOT};
        index index.html;
        try_files \$uri \$uri/ /landing/index.html;
    }
    location = /landing { return 301 /landing/; }

    location / {
        proxy_pass http://fisiocloud_frontend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }

    location /svc/seguridad/ {
        proxy_pass http://svc_seguridad/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/suscripcion/ {
        proxy_pass http://svc_suscripcion/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/info-medica/ {
        proxy_pass http://svc_info_medica/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/agendamiento/ {
        proxy_pass http://svc_agendamiento/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/parametrizacion/ {
        proxy_pass http://svc_parametrizacion/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/tratamiento-casa/ {
        proxy_pass http://svc_tratamiento_casa/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/soporte/ {
        proxy_pass http://svc_soporte/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/procesos-automaticos/ {
        proxy_pass http://svc_procesos_automaticos/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/asistente-voz/ {
        proxy_pass http://svc_asistente_voz/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }

    location = /nginx-health {
        access_log off;
        return 200 "ok\\n";
        add_header Content-Type text/plain;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  ln -sfn /etc/nginx/sites-available/fisiocloud.conf /etc/nginx/sites-enabled/fisiocloud.conf
  nginx -t
  if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload
  else
    nginx
  fi
  echo "nginx listo en :80"
}

# -----------------------------------------------------------------------------
# Procesos Python (Django runserver por microservicio)
# -----------------------------------------------------------------------------
start_svc() {
  local dir="$1"
  local port="$2"
  local name="$3"
  if [ ! -f "${APP_ROOT}/${dir}/manage.py" ]; then
    echo "AVISO: falta ${dir}/manage.py — se omite ${name}"
    return 0
  fi
  echo "Iniciando ${name} en :${port}"
  (
    cd "${APP_ROOT}/${dir}"
    # Esquema ya viene de fisiocloud_init.sql
    python3 manage.py migrate --noinput --fake 2>/dev/null \
      || python3 manage.py migrate --noinput || true
    python3 manage.py runserver "0.0.0.0:${port}"
  ) &
  PIDS+=($!)
  sleep 1
}

echo "=== Fisiocloud setup (nginx + Python) APP_ROOT=${APP_ROOT} ==="
setup_nginx

start_svc backend_seguridad 8101 seguridad
start_svc backend_suscripcion 8102 suscripcion
start_svc backend_info_medica 8103 info_medica
start_svc backend_agendamiento 8104 agendamiento
start_svc backend_parametrizacion 8105 parametrizacion
start_svc backend_tratamiento_casa 8106 tratamiento_casa
start_svc backend_soporte 8107 soporte
start_svc backend_procesos_automaticos 8108 procesos_automaticos
start_svc backend_asistente_voz 8109 asistente_voz
start_svc frontend_fisiocloud 8000 frontend

echo "Entrada: http://0.0.0.0:80  (host Docker: http://127.0.0.1:8089)"
echo "APIs internas: 8101-8109 | vía nginx: /svc/<servicio>/"
wait
