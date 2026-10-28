# Fisiocloud — scripts de instalación

Scripts de base de datos y arranque de la aplicación (independientes de la infra Docker).

| Archivo | Uso |
|---|---|
| `fisiocloud_init.sql` | Crea BDs, tablas, seeds y catálogos del sistema anterior |
| `fisiocloud_setup.sh` | Configura nginx y arranca los microservicios Python |

Las pruebas E2E viven en el repo/carpeta `test/` (`../test/`).

## Base de datos

```bash
mysql -u root -p < fisiocloud_init.sql
# Docker:
mysql -u root -proot < /app/scripts/fisiocloud_init.sql
```

## Arranque (nginx + Python)

```bash
bash fisiocloud_setup.sh
# Docker (también lo invoca entrypoint.sh):
bash /app/scripts/fisiocloud_setup.sh
```

## Orden recomendado

1. Infraestructura Docker / servidor (MariaDB, Python, nginx instalados).
2. `fisiocloud_init.sql`
3. `fisiocloud_setup.sh`
