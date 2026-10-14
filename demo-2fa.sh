#!/usr/bin/env bash
# =============================================================================
#  Demo webinar: "Contraseñas seguras desde cero" — Parte 2: 2FA
#  Authelia (servidor de autenticación) protege un dashboard que NO tiene
#  login propio: contraseña + código TOTP antes de poder entrar.
#
#  Requisito: haber ejecutado antes demo-vaultwarden.sh (usa su Caddy).
#  Uso:   sudo bash demo-2fa.sh
#  Sin pausas:  PAUSAS=no sudo bash demo-2fa.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURACIÓN
# ---------------------------------------------------------------------------
DOMINIO_BASE="aleixmarti.dev"            # dominio para la cookie de sesión
AUTH="auth.${DOMINIO_BASE}"              # portal de login de Authelia
DASH="dash.${DOMINIO_BASE}"              # dashboard protegido
VAULT="vault.${DOMINIO_BASE}"            # Vaultwarden (enlace en el dashboard)
USUARIO="aleix"
NOMBRE="Aleix"
EMAIL="hola@aleixmarti.dev"
DIR="/opt/vaultwarden"
PAUSAS="${PAUSAS:-si}"
AUTHELIA_IMG="authelia/authelia:latest"

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
[[ -f "$DIR/docker-compose.yml" ]] || error "No encuentro ${DIR}. Ejecuta primero demo-vaultwarden.sh."
grep -q "^${AUTH} " "$DIR/Caddyfile" && error "Authelia ya está configurado. Usa reset-demo.sh para empezar de cero."

IP_SERVIDOR=$(curl -4 -s https://ifconfig.me || true)
info "IP pública del servidor: ${IP_SERVIDOR:-desconocida}"
for d in "$AUTH" "$DASH"; do
  ip=$(getent ahostsv4 "$d" | awk 'NR==1{print $1}' || true)
  if [[ -n "$IP_SERVIDOR" && "$ip" == "$IP_SERVIDOR" ]]; then
    ok "$d → $ip"
  else
    echo -e "${ROJO}⚠ $d → ${ip:-sin resolver} (no apunta a este servidor)${NC}"
    read -rp "¿Continuar igualmente? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || exit 1
  fi
done
pausa

# ---------------------------------------------------------------------------
paso "Crear el usuario (contraseña con hash Argon2)"
# ---------------------------------------------------------------------------
info "Authelia nunca guarda la contraseña, solo su hash. El primer factor: algo que SABES."
cd "$DIR"
mkdir -p authelia dashboard
docker pull -q "$AUTHELIA_IMG" >/dev/null
read -rsp "Contraseña para el usuario '${USUARIO}' (no se mostrará): " PASS; echo
[[ ${#PASS} -ge 12 ]] || error "Usa al menos 12 caracteres (mejor una frase de paso)."
HASH=$(docker run --rm "$AUTHELIA_IMG" authelia crypto hash generate argon2 --password "$PASS" | awk '/Digest:/{print $2}')
unset PASS
[[ "$HASH" == \$argon2id* ]] || error "No se ha podido generar el hash."

cat > authelia/users_database.yml <<EOF
users:
  ${USUARIO}:
    disabled: false
    displayname: "${NOMBRE}"
    password: "${HASH}"
    email: "${EMAIL}"
    groups:
      - admins
EOF
chmod 600 authelia/users_database.yml
ok "Usuario creado. Así queda guardado:"
cat authelia/users_database.yml
pausa

# ---------------------------------------------------------------------------
paso "Configurar Authelia"
# ---------------------------------------------------------------------------
info "Secretos aleatorios para firmar sesiones y cifrar la base de datos (donde irán los secretos TOTP)."
info "Regla clave: para entrar en ${DASH} hace falta 'two_factor'."
cat > authelia/configuration.yml <<EOF
server:
  address: 'tcp://:9091/'

log:
  level: info

theme: auto

totp:
  issuer: '${DOMINIO_BASE}'      # nombre que aparecerá en la app autenticadora

authentication_backend:
  password_reset:
    disable: true
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2

access_control:
  default_policy: deny
  rules:
    - domain: '${DASH}'
      policy: two_factor

session:
  secret: '$(openssl rand -hex 32)'
  expiration: 1h
  inactivity: 10m
  cookies:
    - domain: '${DOMINIO_BASE}'
      authelia_url: 'https://${AUTH}'
      default_redirection_url: 'https://${DASH}'

# Protección contra fuerza bruta: 3 fallos en 2 min = bloqueo de 5 min
regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  encryption_key: '$(openssl rand -hex 32)'
  local:
    path: /config/db.sqlite3

# Para la demo, los "correos" se escriben en un fichero en lugar de enviarse
notifier:
  filesystem:
    filename: /config/notification.txt

ntp:
  disable_failure: true
EOF
chmod 600 authelia/configuration.yml

docker run --rm -v "$DIR/authelia:/config" "$AUTHELIA_IMG" \
  authelia validate-config --config /config/configuration.yml
ok "Configuración válida."
grep -A4 '^access_control' authelia/configuration.yml
pausa

# ---------------------------------------------------------------------------
paso "Crear el dashboard (sin login propio)"
# ---------------------------------------------------------------------------
info "Una página sencilla. No sabe nada de contraseñas: la protección la pone Authelia."
cat > dashboard/index.html <<EOF
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Panel privado</title>
<style>
  :root { --bg:#f4f6f8; --card:#fff; --text:#1d2330; --muted:#5b6475; --accent:#1f6feb; --ok:#1a7f37; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0f1218; --card:#181d26; --text:#e6e9ef; --muted:#9aa3b2; --accent:#4c8dff; --ok:#3fb950; } }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }
  main { max-width:760px; margin:0 auto; padding:40px 16px; }
  h1 { margin:0 0 4px; font-size:1.8rem; }
  .sub { color:var(--muted); margin:0 0 28px; }
  .badge { display:inline-block; padding:4px 10px; border-radius:999px; background:color-mix(in srgb,var(--ok) 15%,transparent); color:var(--ok); font-weight:600; font-size:.85rem; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:16px; margin-top:24px; }
  .card { background:var(--card); border-radius:12px; padding:18px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  .card h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); margin:0 0 8px; }
  .card p { margin:0; font-size:1.05rem; word-break:break-word; }
  a { color:var(--accent); }
  .actions { margin-top:28px; display:flex; gap:12px; flex-wrap:wrap; }
  .btn { padding:10px 16px; border-radius:8px; text-decoration:none; font-weight:600; background:var(--accent); color:#fff; }
  .btn.sec { background:transparent; color:var(--accent); border:1px solid var(--accent); }
</style>
</head>
<body>
<main>
  <span class="badge">✔ Contraseña + 2FA verificados</span>
  <h1>Hola, {{.Req.Header.Get "Remote-Name"}}</h1>
  <p class="sub">Has entrado en una zona protegida por Authelia.</p>

  <div class="grid">
    <div class="card"><h2>Usuario</h2><p>{{.Req.Header.Get "Remote-User"}}</p></div>
    <div class="card"><h2>Grupos</h2><p>{{.Req.Header.Get "Remote-Groups"}}</p></div>
    <div class="card"><h2>Correo</h2><p>{{.Req.Header.Get "Remote-Email"}}</p></div>
    <div class="card"><h2>Hora del servidor</h2><p>{{now | date "02/01/2006 15:04:05"}}</p></div>
  </div>

  <div class="actions">
    <a class="btn" href="https://${VAULT}">Abrir Vaultwarden</a>
    <a class="btn sec" href="https://${AUTH}/settings">Mis dispositivos 2FA</a>
    <a class="btn sec" href="https://${AUTH}/logout?rd=https://${DASH}">Cerrar sesión</a>
  </div>
</main>
</body>
</html>
EOF
ok "Dashboard creado en ${DIR}/dashboard/index.html"
pausa

# ---------------------------------------------------------------------------
paso "Conectar las piezas: Docker + Caddy"
# ---------------------------------------------------------------------------
info "docker-compose.override.yml se suma al compose existente sin tocarlo."
cat > docker-compose.override.yml <<'EOF'
services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped
    volumes:
      - ./authelia:/config

  caddy:
    volumes:
      - ./dashboard:/srv/dashboard:ro
EOF

info "Caddy pregunta a Authelia ANTES de servir el dashboard (forward_auth)."
cat >> Caddyfile <<EOF

${AUTH} {
  reverse_proxy authelia:9091
}

${DASH} {
  forward_auth authelia:9091 {
    uri /api/authz/forward-auth
    copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
  }
  header Cache-Control "no-store"
  root * /srv/dashboard
  templates
  file_server
}
EOF
echo "--- docker-compose.override.yml ---"; cat docker-compose.override.yml
echo "--- Caddyfile (bloques nuevos) ---";  sed -n "/^${AUTH} /,\$p" Caddyfile
pausa

# ---------------------------------------------------------------------------
paso "Arrancar"
# ---------------------------------------------------------------------------
docker compose up -d
info "Esperando a Authelia y a los certificados HTTPS..."
for i in {1..40}; do
  if curl -fs "https://${AUTH}/api/health" >/dev/null 2>&1; then
    ok "Authelia responde en https://${AUTH}"; break
  fi
  sleep 3
  [[ $i -eq 40 ]] && { docker compose logs --tail=30 authelia caddy; error "No responde. Revisa DNS y logs."; }
done
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' "https://${DASH}")
info "Petición SIN sesión a https://${DASH} → HTTP ${CODIGO} (redirige al login)"
docker compose ps
pausa

# ---------------------------------------------------------------------------
paso "Primer acceso y registro del 2FA (en el navegador)"
# ---------------------------------------------------------------------------
echo "  1. Abre https://${DASH} → te envía a https://${AUTH}"
echo "  2. Usuario '${USUARIO}' + contraseña  (primer factor: algo que SABES)"
echo "  3. 'Registrar dispositivo' → 'Contraseña de un solo uso (TOTP)'"
echo "  4. Authelia pide verificar tu identidad con un código enviado por 'correo'."
read -rp $'\n▶ Cuando lo pida, pulsa Enter para ver el "correo"... '
echo -e "${AMARILLO}--- notification.txt ---${NC}"
tail -n 25 "$DIR/authelia/notification.txt" 2>/dev/null || echo "(aún no hay notificaciones; repite en unos segundos: tail $DIR/authelia/notification.txt)"
echo
echo "  5. Escanea el QR con la app autenticadora  (segundo factor: algo que TIENES)"
echo "  6. Introduce el código de 6 dígitos → entras al dashboard."
pausa

# ---------------------------------------------------------------------------
paso "Pruebas para el público"
# ---------------------------------------------------------------------------
echo "  • 'Cerrar sesión' y volver a entrar: ahora pide SIEMPRE el código."
echo "  • Ventana privada: sin sesión no hay dashboard."
echo "  • Fuerza bruta: 3 contraseñas erróneas → usuario bloqueado 5 minutos."
echo "    Ver en directo:  cd ${DIR} && docker compose logs -f authelia"
echo "  • Lo que se ha robado no basta: con la contraseña sola NO se entra."

echo -e "\n${VERDE}══════════ DEMO 2FA COMPLETADA ══════════${NC}"
echo "  Dashboard:  https://${DASH}"
echo "  Login:      https://${AUTH}"
echo "  Config:     ${DIR}/authelia/configuration.yml"
