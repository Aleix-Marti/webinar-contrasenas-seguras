#!/usr/bin/env bash
# =============================================================================
#  Demo webinar: "Contraseñas seguras desde cero" — Parte 2: 2FA
#
#  PARTE A: publicamos un dashboard SIN protección (entra cualquiera).
#  PARTE B: ponemos Authelia delante: contraseña + código TOTP para entrar.
#  El dashboard no se modifica: la protección se añade por fuera.
#
#  Requisito: haber ejecutado antes demo-vaultwarden-2.sh (usa su Caddy).
#  INSTANCIA 2: auth2/dash2/vault2.aleixmarti.dev · IP 5.250.188.45
#  Uso:   sudo bash demo-2fa-2.sh
#  Sin pausas:  PAUSAS=no sudo bash demo-2fa-2.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURACIÓN
# ---------------------------------------------------------------------------
DOMINIO_BASE="aleixmarti.dev"            # dominio para la cookie de sesión
AUTH="auth2.${DOMINIO_BASE}"             # portal de login de Authelia
DASH="dash2.${DOMINIO_BASE}"             # dashboard
VAULT="vault2.${DOMINIO_BASE}"           # Vaultwarden (enlace en el dashboard)
MAIL="mail2.${DOMINIO_BASE}"             # bandeja de Mailpit (si está instalada)
COOKIE="authelia_session_2"              # distinto en cada instancia (comparten dominio)
USUARIO="aleix"
NOMBRE="Aleix"
EMAIL="hola@aleixmarti.dev"
DIR="/opt/vaultwarden"
PAUSAS="${PAUSAS:-si}"
AUTHELIA_IMG="authelia/authelia:latest"

# ---------------------------------------------------------------------------
AZUL='\033[1;34m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; MAGENTA='\033[1;35m'; NC='\033[0m'
PASO=0
paso()  { PASO=$((PASO+1)); echo -e "\n${AZUL}══════════ PASO ${PASO}: $* ══════════${NC}"; }
parte() { echo -e "\n${MAGENTA}████████████  $*  ████████████${NC}"; }
info()  { echo -e "${AMARILLO}→ $*${NC}"; }
ok()    { echo -e "${VERDE}✔ $*${NC}"; }
error() { echo -e "${ROJO}✘ $*${NC}"; exit 1; }
pausa() { [[ "$PAUSAS" == "si" ]] && read -rp $'\n▶ Pulsa Enter para continuar... ' || true; }
recargar_caddy() { docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null; }

# ---------------------------------------------------------------------------
paso "Comprobaciones previas"
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Ejecuta el script como root (sudo)."
[[ -f "$DIR/docker-compose.yml" ]] || error "No encuentro ${DIR}. Ejecuta primero demo-vaultwarden-2.sh."
cd "$DIR"
if grep -qE "^(${AUTH}|${DASH}) " Caddyfile; then
  error "La demo 2FA ya está instalada. Usa reset-2fa.sh para empezar de cero."
fi

IP_SERVIDOR=$(curl -4 -s https://ifconfig.me || true)
info "IP pública del servidor: ${IP_SERVIDOR:-desconocida}"
for d in "$DASH" "$AUTH"; do
  ip=$(getent ahostsv4 "$d" | awk 'NR==1{print $1}' || true)
  if [[ -n "$IP_SERVIDOR" && "$ip" == "$IP_SERVIDOR" ]]; then
    ok "$d → $ip"
  else
    echo -e "${ROJO}⚠ $d → ${ip:-sin resolver} (no apunta a este servidor)${NC}"
    read -rp "¿Continuar igualmente? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || exit 1
  fi
done
docker pull -q "$AUTHELIA_IMG" >/dev/null &   # se descarga mientras tanto
pausa

# ═══════════════════════════════════════════════════════════════════════════
parte "PARTE A · UNA WEB SIN PROTECCIÓN"
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
paso "Crear el dashboard"
# ---------------------------------------------------------------------------
info "Una página sencilla, sin ningún login propio."
info "Muestra si la visita ha pasado por Authelia o no."
mkdir -p dashboard
cat > dashboard/index.html <<'EOF'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dashboard</title>
<style>
  :root { --bg:#f4f6f8; --card:#fff; --text:#1d2330; --muted:#5b6475; --accent:#1f6feb; --ok:#1a7f37; --bad:#c62828; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0f1218; --card:#181d26; --text:#e6e9ef; --muted:#9aa3b2; --accent:#4c8dff; --ok:#3fb950; --bad:#ff6b6b; } }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); line-height:1.6; }
  main { max-width:680px; margin:0 auto; padding:48px 16px; }
  .card { background:var(--card); border-radius:14px; padding:32px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  .badge { display:inline-block; padding:4px 12px; border-radius:999px; font-weight:600; font-size:.85rem; }
  .ok  { background:color-mix(in srgb,var(--ok) 15%,transparent);  color:var(--ok); }
  .bad { background:color-mix(in srgb,var(--bad) 15%,transparent); color:var(--bad); }
  h1 { margin:16px 0 8px; font-size:1.7rem; }
  p { margin:0 0 14px; }
  .muted { color:var(--muted); }
  ol { padding-left:20px; margin:0 0 20px; }
  a.btn { display:inline-block; margin-top:8px; padding:10px 18px; border-radius:8px; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; }
</style>
</head>
<body>
<main>
  <div class="card">
  {{- $usuario := .Req.Header.Get "Remote-User" }}
  {{- if $usuario }}
    <span class="badge ok">🔒 Acceso verificado</span>
    <h1>Este dashboard es privado</h1>
    <p>Solo se puede acceder con usuario, contraseña <strong>y</strong> un código de verificación (2FA).</p>
    <p class="muted">Has entrado como <strong>{{ $usuario }}</strong>.</p>
    <p>Para llegar hasta aquí has pasado dos controles:</p>
    <ol>
      <li><strong>Algo que sabes:</strong> tu contraseña.</li>
      <li><strong>Algo que tienes:</strong> el código de 6 dígitos de la app autenticadora.</li>
    </ol>
    <p class="muted">Esta página no tiene login propio. La protege Authelia, que se pone delante y no deja pasar a nadie sin los dos factores.</p>
    <a class="btn" href="https://__AUTH__/logout?rd=https://__DASH__">Cerrar sesión</a>
  {{- else }}
    <span class="badge bad">⚠ Página pública</span>
    <h1>Cualquiera puede ver este dashboard</h1>
    <p>No se ha pedido ninguna contraseña. Basta con conocer la dirección.</p>
    <p class="muted">Paneles de administración, estadísticas, herramientas internas… Muchas webs están así, a la vista de cualquiera que las encuentre.</p>
  {{- end }}
  </div>
</main>
</body>
</html>
EOF
sed -i "s|__AUTH__|${AUTH}|g; s|__DASH__|${DASH}|g" dashboard/index.html
ok "Dashboard creado en ${DIR}/dashboard/index.html"
pausa

# ---------------------------------------------------------------------------
paso "Publicarlo en ${DASH}, sin protección"
# ---------------------------------------------------------------------------
info "docker-compose.override.yml se suma al compose existente: le damos la página a Caddy."
cat > docker-compose.override.yml <<'EOF'
services:
  caddy:
    volumes:
      - ./dashboard:/srv/dashboard:ro
EOF

cat >> Caddyfile <<EOF

${DASH} {
  request_header -Remote-User
  request_header -Remote-Name
  header Cache-Control "no-store"
  root * /srv/dashboard
  templates
  file_server
}
EOF
echo "--- Bloque añadido al Caddyfile ---"
sed -n "/^${DASH} /,/^}/p" Caddyfile

docker compose up -d
info "Esperando al certificado HTTPS de ${DASH}..."
for i in {1..40}; do
  curl -fs -o /dev/null "https://${DASH}" && break
  sleep 3
  [[ $i -eq 40 ]] && { docker compose logs --tail=30 caddy; error "No responde. Revisa el DNS de ${DASH}."; }
done
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' "https://${DASH}")
echo -e "${ROJO}⚠ https://${DASH} → HTTP ${CODIGO}: se ve sin pedir nada.${NC}"
echo
echo "  ▶ Ábrelo en el navegador: https://${DASH}"
echo "    Cualquier persona con la dirección puede verlo."
pausa

# ═══════════════════════════════════════════════════════════════════════════
parte "PARTE B · AÑADIR EL 2FA CON AUTHELIA"
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
paso "Crear el usuario (contraseña con hash Argon2)"
# ---------------------------------------------------------------------------
info "Authelia nunca guarda la contraseña, solo su hash. El primer factor: algo que SABES."
wait   # por si la imagen de Authelia aún se estaba descargando
mkdir -p authelia
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

# Si la demo de Vaultwarden instaló Mailpit, los correos de Authelia van allí;
# si no, se escriben en un fichero.
if grep -q '^  mailpit:' docker-compose.yml; then
  USA_MAILPIT=si
  info "Mailpit detectado: los correos de Authelia se verán en https://${MAIL}"
  NOTIFIER="notifier:
  smtp:
    address: 'smtp://mailpit:1025'
    sender: 'Demo 2FA <auth@${DOMINIO_BASE}>'
    subject: '[Demo 2FA] {title}'
    disable_require_tls: true      # Mailpit, dentro de Docker, no usa TLS"
else
  USA_MAILPIT=no
  NOTIFIER="notifier:
  filesystem:
    filename: /config/notification.txt"
fi

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
  name: '${COOKIE}'
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

# Envío de correos (verificación de identidad al registrar el 2FA)
${NOTIFIER}

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
paso "Arrancar Authelia"
# ---------------------------------------------------------------------------
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
docker compose up -d
docker compose ps authelia
info "Authelia está en marcha, pero el dashboard sigue abierto: aún no hemos puesto el portero."
pausa

# ---------------------------------------------------------------------------
paso "Poner el portero: Caddy pregunta a Authelia"
# ---------------------------------------------------------------------------
info "Dos cambios en el Caddyfile:"
info "  1) el portal de login en ${AUTH}"
info "  2) forward_auth en ${DASH}: antes de servir la página, pregunta a Authelia"
cp Caddyfile /tmp/Caddyfile.antes

# (las líneas request_header se quitan: forward_auth ya fija esas cabeceras)
awk -v dash="${DASH}" '
  /^  request_header -Remote-/ { next }
  { print }
  $0 ~ "^" dash " \\{$" {
    print "  forward_auth authelia:9091 {"
    print "    uri /api/authz/forward-auth"
    print "    copy_headers Remote-User Remote-Groups Remote-Email Remote-Name"
    print "  }"
  }' /tmp/Caddyfile.antes > /tmp/Caddyfile.nuevo

cat >> /tmp/Caddyfile.nuevo <<EOF

${AUTH} {
  reverse_proxy authelia:9091
}
EOF
cat /tmp/Caddyfile.nuevo > Caddyfile      # mismo fichero: Caddy lo tiene montado
rm -f /tmp/Caddyfile.nuevo

echo "--- Cambios en el Caddyfile ---"
diff /tmp/Caddyfile.antes Caddyfile | sed -n 's/^> /+ /p; s/^< /- /p' || true
rm -f /tmp/Caddyfile.antes

recargar_caddy
info "Esperando a Authelia y al certificado HTTPS de ${AUTH}..."
for i in {1..40}; do
  curl -fs -o /dev/null "https://${AUTH}/api/health" && { ok "Authelia responde en https://${AUTH}"; break; }
  sleep 3
  [[ $i -eq 40 ]] && { docker compose logs --tail=30 authelia caddy; error "No responde. Revisa DNS y logs."; }
done
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' "https://${DASH}")
echo -e "${VERDE}✔ https://${DASH} → HTTP ${CODIGO}: ahora redirige al login.${NC}"
echo
echo "  ▶ Recarga https://${DASH} en el navegador: ya no se ve, te lleva a https://${AUTH}"
pausa

# ---------------------------------------------------------------------------
paso "Primer acceso y registro del 2FA (en el navegador)"
# ---------------------------------------------------------------------------
echo "  1. En https://${AUTH}: usuario '${USUARIO}' + contraseña  (algo que SABES)"
echo "  2. 'Registrar dispositivo' → 'Contraseña de un solo uso (TOTP)'"
echo "  3. Authelia pide verificar tu identidad con un código enviado por correo."
if [[ "$USA_MAILPIT" == "si" ]]; then
  echo "     El código llega a la bandeja de pruebas: https://${MAIL}  (usuario: demo)"
else
  read -rp $'\n▶ Cuando lo pida, pulsa Enter para ver el "correo"... '
  echo -e "${AMARILLO}--- notification.txt ---${NC}"
  tail -n 25 "$DIR/authelia/notification.txt" 2>/dev/null || echo "(aún no hay notificaciones; repite en unos segundos: tail $DIR/authelia/notification.txt)"
fi
echo "  4. Escanea el QR con la app autenticadora  (algo que TIENES)"
echo "  5. Introduce el código de 6 dígitos → entras al dashboard, ahora en verde."
pausa

# ---------------------------------------------------------------------------
paso "Pruebas para el público"
# ---------------------------------------------------------------------------
echo "  • 'Cerrar sesión' y volver a entrar: ahora pide SIEMPRE el código."
echo "  • Ventana privada: sin sesión no hay dashboard."
echo "  • Fuerza bruta: 3 contraseñas erróneas → usuario bloqueado 5 minutos."
echo "    Ver en directo:  cd ${DIR} && docker compose logs -f authelia"
echo "  • La página no ha cambiado: la protección se ha puesto por fuera."

echo -e "\n${VERDE}══════════ DEMO 2FA COMPLETADA ══════════${NC}"
echo "  Dashboard:  https://${DASH}"
echo "  Login:      https://${AUTH}"
echo "  Config:     ${DIR}/authelia/configuration.yml"
