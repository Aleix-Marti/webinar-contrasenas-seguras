#!/usr/bin/env bash
# Deja el servidor listo para volver a ensayar la demo.
# ATENCIÓN: borra la instalación de Vaultwarden, sus datos y las copias.
set -euo pipefail
DIR="/opt/vaultwarden"

read -rp "Esto borrará ${DIR} por completo (datos y copias). ¿Seguro? [s/N] " r
[[ "$r" =~ ^[sS]$ ]] || exit 1

if [[ -f "$DIR/docker-compose.yml" ]]; then
  (cd "$DIR" && docker compose down -v)
fi
rm -rf "$DIR"
rm -f /etc/cron.d/vaultwarden-backup
echo "Listo. Docker y el cortafuegos se mantienen; las imágenes descargadas también,"
echo "así que en el directo el paso de arranque irá más rápido."
