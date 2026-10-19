#!/usr/bin/env bash
# =============================================================================
#  Demo webinar: "Contraseñas seguras desde cero"
#  Instalación de Vaultwarden (gestor compatible con Bitwarden) en un
#  servidor Ubuntu de IONOS Cloud, con HTTPS automático (Caddy) y 2FA.
#  INSTANCIA 2: vault2.aleixmarti.dev · IP 5.250.188.45
#
#  Uso:   sudo bash demo-vaultwarden.sh
#  El script se detiene entre pasos para poder explicarlos en directo.
#  Para ejecutarlo sin pausas:  PAUSAS=no sudo bash demo-vaultwarden.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURACIÓN — rellenar antes de la demo
# ---------------------------------------------------------------------------
DOMINIO="vault2.aleixmarti.dev"        # subdominio con registro DNS A hacia este servidor
EMAIL="hola@aleixmarti.dev"           # para el certificado de Let's Encrypt
MAIL="mail2.aleixmarti.dev"   # bandeja de correo de pruebas (Mailpit)
DIR="/opt/vaultwarden"                # carpeta de instalación
PAUSAS="${PAUSAS:-si}"

# ---------------------------------------------------------------------------
# Utilidades de presentación
# ---------------------------------------------------------------------------
AZUL='\033[1;34m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; NC='\033[0m'
PASO=0
paso()  { PASO=$((PASO+1)); echo -e "\n${AZUL}══════════ PASO ${PASO}: $* ══════════${NC}"; }
info()  { echo -e "${AMARILLO}→ $*${NC}"; }
ok()    { echo -e "${VERDE}✔ $*${NC}"; }
error() { echo -e "${ROJO}✘ $*${NC}"; exit 1; }
pausa() { [[ "$PAUSAS" == "si" ]] && read -rp $'\n▶ Pulsa Enter para continuar... ' || true; }

# ---------------------------------------------------------------------------
paso "Comprobaciones previas"
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Ejecuta el script como root (sudo)."
[[ "$DOMINIO" != *ejemplo.com ]] || error "Edita la variable DOMINIO antes de empezar."

IP_SERVIDOR=$(curl -4 -s https://ifconfig.me || true)
info "IP pública del servidor: ${IP_SERVIDOR:-desconocida}"
for d in "$DOMINIO" "$MAIL"; do
  IP_DNS=$(getent ahostsv4 "$d" | awk 'NR==1{print $1}' || true)
  if [[ -n "$IP_SERVIDOR" && "$IP_SERVIDOR" == "$IP_DNS" ]]; then
    ok "$d → $IP_DNS"
  else
    echo -e "${ROJO}⚠ $d → ${IP_DNS:-sin resolver} (no apunta a este servidor). Caddy no podrá obtener su certificado.${NC}"
    read -rp "¿Continuar igualmente? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || exit 1
  fi
done
pausa

# ---------------------------------------------------------------------------
paso "Actualizar el sistema"
# ---------------------------------------------------------------------------
info "Un servidor sin parches es la primera puerta de entrada."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "Sistema actualizado."
pausa

# ---------------------------------------------------------------------------
paso "Instalar Docker y herramientas"
# ---------------------------------------------------------------------------
info "Docker: el gestor corre aislado en contenedores."
info "argon2: para guardar el token de administración como hash, no en claro."
info "sqlite3: para hacer copias de seguridad consistentes de la base de datos."
apt-get install -y -qq docker.io docker-compose-v2 argon2 sqlite3 curl
systemctl enable --now docker >/dev/null
docker --version
docker compose version
ok "Docker instalado."
pausa

# ---------------------------------------------------------------------------
paso "Cortafuegos: solo SSH, HTTP y HTTPS"
# ---------------------------------------------------------------------------
info "Principio de mínima exposición: cerramos todo lo que no hace falta."
ufw allow OpenSSH >/dev/null      # primero SSH, para no quedarnos fuera
ufw allow 80/tcp  >/dev/null      # necesario para validar el certificado
ufw allow 443/tcp >/dev/null      # HTTPS
ufw --force enable >/dev/null
ufw status verbose
ok "Cortafuegos activo."
pausa

# ---------------------------------------------------------------------------
paso "Generar el token de administración (Argon2)"
# ---------------------------------------------------------------------------
info "El panel /admin se protege con un token. Guardamos solo su hash."
mkdir -p "$DIR"
cd "$DIR"
read -rsp "Contraseña para el panel /admin (no se mostrará): " ADMIN_PASS; echo
[[ ${#ADMIN_PASS} -ge 12 ]] || error "Usa al menos 12 caracteres (mejor una frase de paso)."
ADMIN_HASH=$(echo -n "$ADMIN_PASS" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4)
unset ADMIN_PASS

# Comillas simples: el hash contiene '$' y no debe interpretarse
cat > .env <<EOF
DOMAIN='https://${DOMINIO}'
SIGNUPS_ALLOWED='true'
ADMIN_TOKEN='${ADMIN_HASH}'
SMTP_HOST='mailpit'
SMTP_PORT='1025'
SMTP_SECURITY='off'
SMTP_FROM='vault@${MAIL#*.}'
SMTP_FROM_NAME='Vaultwarden Demo'
EOF
chmod 600 .env
ok "Token generado. Mira: en el fichero solo hay un hash, no la contraseña."
grep ADMIN_TOKEN .env | cut -c1-60; echo "..."
pausa

# ---------------------------------------------------------------------------
paso "Bandeja de correo de pruebas (Mailpit)"
# ---------------------------------------------------------------------------
info "Mailpit hace de servidor de correo: atrapa los correos y los muestra en una web."
info "Nada sale a internet: ideal para pruebas y para ver los correos en directo."
info "La web de Mailpit se protege con usuario y contraseña (hash bcrypt en el Caddyfile)."
read -rsp "Contraseña para ver la bandeja en https://${MAIL} (usuario: demo): " MAIL_PASS; echo
[[ ${#MAIL_PASS} -ge 12 ]] || error "Usa al menos 12 caracteres (mejor una frase de paso)."
docker pull -q caddy:2 >/dev/null
MAIL_HASH=$(docker run --rm caddy:2 caddy hash-password --plaintext "$MAIL_PASS")
unset MAIL_PASS
[[ "$MAIL_HASH" == \$2* ]] || error "No se ha podido generar el hash."
ok "Hash generado."
pausa

# ---------------------------------------------------------------------------
paso "Configuración de los contenedores"
# ---------------------------------------------------------------------------
info "Tres servicios: Vaultwarden (el gestor), Caddy (HTTPS automático) y Mailpit (correo de pruebas)."
cat > docker-compose.yml <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./vw-data:/data

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config

  mailpit:
    image: axllent/mailpit:latest
    container_name: mailpit
    restart: unless-stopped
EOF

cat > Caddyfile <<EOF
{
  email ${EMAIL}
}

${DOMINIO} {
  encode zstd gzip
  reverse_proxy vaultwarden:80
}

${MAIL} {
  basic_auth {
    demo ${MAIL_HASH}
  }
  reverse_proxy mailpit:8025
}
EOF
echo "--- docker-compose.yml ---"; cat docker-compose.yml
echo "--- Caddyfile ---";          cat Caddyfile
pausa

# ---------------------------------------------------------------------------
paso "Arrancar el servicio"
# ---------------------------------------------------------------------------
docker compose pull -q
docker compose up -d
info "Esperando a que Caddy obtenga el certificado HTTPS..."
for i in {1..30}; do
  if curl -fs "https://${DOMINIO}/alive" >/dev/null 2>&1; then
    ok "Vaultwarden responde en https://${DOMINIO}"; break
  fi
  sleep 3
  [[ $i -eq 30 ]] && { docker compose logs --tail=30 caddy; error "No responde. Revisa el DNS y los puertos 80/443."; }
done
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' "https://${MAIL}" || true)
info "Bandeja de correo sin contraseña → HTTP ${CODIGO} (401 = pide usuario y contraseña)"
docker compose ps
pausa

# ---------------------------------------------------------------------------
paso "Crear la cuenta (en el navegador)"
# ---------------------------------------------------------------------------
echo "  1. Abre https://${DOMINIO}"
echo "  2. 'Crear cuenta' → usa una FRASE DE PASO larga como contraseña maestra."
echo "  3. Inicia sesión y guarda tu primera contraseña."
echo "  4. Ajustes → Seguridad → Inicio de sesión en dos pasos → App autenticadora."
echo "     Escanea el QR y GUARDA EL CÓDIGO DE RECUPERACIÓN."
echo "  5. Instala la extensión de Bitwarden → Autoalojado → https://${DOMINIO}"
echo "  6. Correos (verificación, nuevo dispositivo…): https://${MAIL}  (usuario: demo)"
echo "     Prueba: https://${DOMINIO}/admin → SMTP Email Settings → Send test email"
read -rp $'\n▶ Cuando hayas creado la cuenta, pulsa Enter para cerrar los registros... '

# ---------------------------------------------------------------------------
paso "Cerrar el registro público"
# ---------------------------------------------------------------------------
info "Si el servidor es nuestro, nadie más debe poder abrir una cuenta."
sed -i "s/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED='false'/" .env
docker compose up -d
ok "Registro desactivado. Se pueden invitar usuarios desde https://${DOMINIO}/admin"
pausa

# ---------------------------------------------------------------------------
paso "Copias de seguridad"
# ---------------------------------------------------------------------------
info "Autoalojar = la responsabilidad de las copias también es nuestra."
cat > "$DIR/backup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FECHA=\$(date +%Y%m%d-%H%M)
DEST="${DIR}/backups"
mkdir -p "\$DEST"
# Copia consistente de la base de datos aunque el servicio esté en marcha
sqlite3 "${DIR}/vw-data/db.sqlite3" ".backup '\$DEST/db-\$FECHA.sqlite3'"
# Claves, adjuntos y configuración
tar -czf "\$DEST/vw-data-\$FECHA.tar.gz" -C "${DIR}" --exclude='db.sqlite3*' vw-data
# Conservar 14 días
find "\$DEST" -type f -mtime +14 -delete
echo "Copia creada en \$DEST (\$FECHA)"
EOF
chmod 700 "$DIR/backup.sh"
"$DIR/backup.sh"
echo "15 3 * * * root ${DIR}/backup.sh >/dev/null 2>&1" > /etc/cron.d/vaultwarden-backup
ok "Copia diaria programada a las 03:15."
info "Recuerda: una copia que solo está en el mismo servidor no es una copia. Sácala fuera (p. ej. a IONOS S3 Object Storage)."
ls -lh "$DIR/backups"

# ---------------------------------------------------------------------------
echo -e "\n${VERDE}══════════ DEMO COMPLETADA ══════════${NC}"
echo "  Gestor:          https://${DOMINIO}"
echo "  Administración:  https://${DOMINIO}/admin"
echo "  Correo pruebas:  https://${MAIL}  (usuario: demo)"
echo "  Ficheros:        ${DIR}"
echo "  Logs:            cd ${DIR} && docker compose logs -f"
