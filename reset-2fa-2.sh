#!/usr/bin/env bash
# =============================================================================
#  Reset de la parte 2FA de la demo (Authelia + dashboard).
#  Deja Vaultwarden y Caddy funcionando tal cual, para volver a ensayar
#  demo-2fa.sh sin repetir la instalación de Vaultwarden.
#  Sirve para las dos instancias (auth./dash. y auth2./dash2.).
#
#  Uso:   sudo bash reset-2fa.sh
#  ATENCIÓN: borra el usuario, la configuración y los dispositivos 2FA
#  registrados en Authelia.
# =============================================================================
set -euo pipefail

DIR="/opt/vaultwarden"
VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; NC='\033[0m'
info()  { echo -e "${AMARILLO}→ $*${NC}"; }
ok()    { echo -e "${VERDE}✔ $*${NC}"; }
error() { echo -e "${ROJO}✘ $*${NC}"; exit 1; }

[[ $EUID -eq 0 ]] || error "Ejecuta el script como root (sudo)."
[[ -f "$DIR/docker-compose.yml" ]] || error "No encuentro ${DIR}. No hay nada que resetear."
cd "$DIR"

# Línea donde empiezan los bloques que añadió demo-2fa.sh (dash./auth. o dash2./auth2.)
LINEA_AUTH=$(grep -n -m1 -E '^(auth|dash)[0-9]*\.[^ ]+ \{' Caddyfile | cut -d: -f1 || true)

if [[ -z "$LINEA_AUTH" && ! -f docker-compose.override.yml && ! -d authelia ]]; then
  ok "No hay rastro de Authelia: la parte 2FA ya está limpia."
  exit 0
fi

echo "Se borrará:"
echo "  - El contenedor de Authelia"
echo "  - ${DIR}/authelia (usuario, configuración y dispositivos 2FA)"
echo "  - ${DIR}/dashboard (se guarda una copia del index.html en /root)"
echo "  - ${DIR}/docker-compose.override.yml"
echo "  - Los bloques de dash y auth del Caddyfile"
echo "Vaultwarden y sus datos NO se tocan."
read -rp "¿Continuar? [s/N] " r
[[ "$r" =~ ^[sS]$ ]] || exit 1

# 1. Parar y eliminar Authelia (mientras el override todavía existe)
if [[ -f docker-compose.override.yml ]]; then
  info "Parando Authelia..."
  docker compose stop authelia >/dev/null 2>&1 || true
  docker compose rm -f authelia >/dev/null 2>&1 || true
fi

# 2. Copia de seguridad del dashboard, por si se personalizó
if [[ -f dashboard/index.html ]]; then
  COPIA="/root/dashboard-index-$(date +%Y%m%d-%H%M%S).html"
  cp dashboard/index.html "$COPIA"
  info "Copia del dashboard guardada en ${COPIA}"
fi

# 3. Borrar ficheros de la parte 2FA
rm -rf authelia dashboard docker-compose.override.yml
ok "Ficheros de Authelia y del dashboard eliminados."

# 4. Quitar del Caddyfile los bloques añadidos (sin cambiar el fichero de sitio,
#    porque Caddy lo tiene montado directamente)
if [[ -n "$LINEA_AUTH" ]]; then
  head -n $((LINEA_AUTH - 1)) Caddyfile | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > /tmp/Caddyfile.reset
  cat /tmp/Caddyfile.reset > Caddyfile
  rm -f /tmp/Caddyfile.reset
  ok "Caddyfile restaurado:"
  cat Caddyfile
fi

# 5. Recrear Caddy sin el dashboard y eliminar contenedores huérfanos
info "Reiniciando Caddy..."
docker compose up -d --remove-orphans
docker compose ps

echo -e "\n${VERDE}══════════ PARTE 2FA RESETEADA ══════════${NC}"
echo "  Vaultwarden sigue funcionando."
echo "  Ya puedes volver a ejecutar demo-2fa.sh."
echo "  Recuerda borrar la entrada antigua en la app autenticadora del móvil."
