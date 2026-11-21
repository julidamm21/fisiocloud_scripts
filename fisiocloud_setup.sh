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
export INFO_MEDICA_URL="${INFO_MEDICA_URL:-http://127.0.0.1:8103}"
# Alias BC: agenda y catálogos viven en info_medica (:8103)
export AGENDAMIENTO_URL="${AGENDAMIENTO_URL:-${INFO_MEDICA_URL}}"
export PARAMETRIZACION_URL="${PARAMETRIZACION_URL:-${INFO_MEDICA_URL}}"
export SUSCRIPCION_URL="${SUSCRIPCION_URL:-http://127.0.0.1:8103/__/suscripcion}"
export TRATAMIENTO_CASA_URL="${TRATAMIENTO_CASA_URL:-http://127.0.0.1:8103/__/tratamiento-casa}"
export SOPORTE_URL="${SOPORTE_URL:-http://127.0.0.1:8103/__/soporte}"
export PROCESOS_AUTOMATICOS_URL="${PROCESOS_AUTOMATICOS_URL:-http://127.0.0.1:8103/__/procesos-automaticos}"
export ASISTENTE_VOZ_URL="${ASISTENTE_VOZ_URL:-http://127.0.0.1:8103/__/asistente-voz}"
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
# Suscripción + casa + soporte + procesos + voz viven en info_medica (:8103)
upstream svc_info_medica { server 127.0.0.1:8103; }

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
    location /svc/info-medica/ {
        proxy_pass http://svc_info_medica/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    # Alias BC: agenda + catálogos → info_medica
    location /svc/agendamiento/ {
        proxy_pass http://svc_info_medica/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/parametrizacion/ {
        proxy_pass http://svc_info_medica/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    # Satélites embebidos en info_medica (prefijo /__/…)
    location /svc/suscripcion/ {
        proxy_pass http://svc_info_medica/__/suscripcion/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    # Imágenes de ejercicios: disco compartido (no pasan por Gunicorn)
    location /svc/tratamiento-casa/media/ {
        alias ${APP_ROOT}/media/;
        expires 7d;
        add_header Cache-Control "public";
        access_log off;
    }
    location /svc/tratamiento-casa/ {
        proxy_pass http://svc_info_medica/__/tratamiento-casa/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/soporte/ {
        proxy_pass http://svc_info_medica/__/soporte/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/procesos-automaticos/ {
        proxy_pass http://svc_info_medica/__/procesos-automaticos/;
        include /etc/nginx/fisiocloud_proxy_params.conf;
    }
    location /svc/asistente-voz/ {
        proxy_pass http://svc_info_medica/__/asistente-voz/;
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
fix_satellite_app_labels() {
  # Tras renombrar AppConfig.label (core → suscripcion/soporte/…), alinear django_migrations
  local user="${DB_USER:-root}"
  local pass="${DB_PASSWORD:-root}"
  local host="${DB_HOST:-127.0.0.1}"
  local port="${DB_PORT:-3306}"
  mysql_cmd() { mysql -h"$host" -P"$port" -u"$user" -p"$pass" "$@" 2>/dev/null; }
  echo "Alineando app labels de satélites embebidos..."
  mysql_cmd fisiocloud_suscripcion -e "UPDATE django_migrations SET app='suscripcion' WHERE app='core'; UPDATE django_content_type SET app_label='suscripcion' WHERE app_label='core';" || true
  mysql_cmd fisiocloud_tratamiento_casa -e "UPDATE django_migrations SET app='tratamiento_casa' WHERE app='core'; UPDATE django_content_type SET app_label='tratamiento_casa' WHERE app_label='core';" || true
  mysql_cmd fisiocloud_soporte -e "UPDATE django_migrations SET app='soporte' WHERE app='core'; UPDATE django_content_type SET app_label='soporte' WHERE app_label='core';" || true
  mysql_cmd fisiocloud_procesos_automaticos -e "UPDATE django_migrations SET app='procesos_automaticos' WHERE app='core'; UPDATE django_content_type SET app_label='procesos_automaticos' WHERE app_label='core';" || true
  mysql_cmd fisiocloud_asistente_voz -e "UPDATE django_migrations SET app='asistente_voz' WHERE app='core'; UPDATE django_content_type SET app_label='asistente_voz' WHERE app_label='core';" || true
}

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
    if [ "$name" = "info_medica" ]; then
      fix_satellite_app_labels
      # Solo migrar cada app en su BD (evita contaminar satélites con tablas de core)
      python3 manage.py migrate core admin auth contenttypes sessions --database=default --noinput || true
      python3 manage.py migrate suscripcion --database=suscripcion --noinput || true
      python3 manage.py migrate tratamiento_casa --database=tratamiento_casa --noinput || true
      python3 manage.py migrate soporte --database=soporte --noinput || true
      python3 manage.py migrate procesos_automaticos --database=procesos_automaticos --noinput || true
      python3 manage.py migrate asistente_voz --database=asistente_voz --noinput || true
    else
      python3 manage.py migrate --noinput || true
    fi
    python3 manage.py runserver "0.0.0.0:${port}"
  ) &
  PIDS+=($!)
  sleep 1
}

echo "=== Fisiocloud setup (nginx + Python) APP_ROOT=${APP_ROOT} ==="
setup_nginx

# Solo seguridad (puerto propio) + info_medica (host de satélites) + frontend
start_svc backend_seguridad 8101 seguridad
start_svc backend_info_medica 8103 info_medica
start_svc frontend_fisiocloud 8000 frontend

echo "Entrada: http://0.0.0.0:80  (host Docker: http://127.0.0.1:8089)"
echo "Procesos: 8101 seguridad | 8103 info_medica(+satélites) | 8000 frontend"
echo "vía nginx: /svc/<servicio>/  (satélites → :8103/__/…)"
wait
