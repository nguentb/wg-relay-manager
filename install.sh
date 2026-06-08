#!/bin/bash
set -e

APP_DIR="/opt/wg-relay-manager"
BIN="/usr/local/bin/wg-relay"

WEB_PORT="${WEB_PORT:-8090}"
WEB_PASSWORD="${WEB_PASSWORD:-admin123}"
CLIENT_SUBNET="${CLIENT_SUBNET:-10.8.0.0/24}"
EXIT_IF="${EXIT_IF:-wg-exit}"
ROUTE_TABLE="${ROUTE_TABLE:-200}"

apt update
apt install -y wireguard-tools python3 python3-flask iptables curl

mkdir -p "$APP_DIR"

cat > "$APP_DIR/config" <<CONFIGEOF
WEB_PORT="$WEB_PORT"
WEB_PASSWORD="$WEB_PASSWORD"
CLIENT_SUBNET="$CLIENT_SUBNET"
EXIT_IF="$EXIT_IF"
ROUTE_TABLE="$ROUTE_TABLE"
APP_DIR="$APP_DIR"
CONFIGEOF

cat > "$BIN" <<'CLIEOF'
#!/bin/bash
set -e

CONFIG_FILE="/opt/wg-relay-manager/config"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

APP_DIR="${APP_DIR:-/opt/wg-relay-manager}"
EXIT_IF="${EXIT_IF:-wg-exit}"
CLIENT_SUBNET="${CLIENT_SUBNET:-10.8.0.0/24}"
ROUTE_TABLE="${ROUTE_TABLE:-200}"

LOCAL_CONF="$APP_DIR/$EXIT_IF.conf"
WG_CONF="/etc/wireguard/$EXIT_IF.conf"
ROUTE_FLAG="$APP_DIR/route.enabled"

ensure_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg-relay.conf
}

install_conf() {
  if [ ! -f "$LOCAL_CONF" ]; then
    echo "Exit config not found: $LOCAL_CONF"
    exit 1
  fi

  cp "$LOCAL_CONF" "$WG_CONF"
  chmod 600 "$WG_CONF"
}

tunnel_up() {
  install_conf
  wg-quick down "$EXIT_IF" 2>/dev/null || true
  wg-quick up "$EXIT_IF"
  echo "Tunnel started: $EXIT_IF"
}

tunnel_down() {
  wg-quick down "$EXIT_IF" 2>/dev/null || true
  echo "Tunnel stopped: $EXIT_IF"
}

route_off() {
  while ip rule del from "$CLIENT_SUBNET" table "$ROUTE_TABLE" 2>/dev/null; do :; done
  ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

  while iptables -t nat -D POSTROUTING -s "$CLIENT_SUBNET" -o "$EXIT_IF" -j MASQUERADE 2>/dev/null; do :; done

  rm -f "$ROUTE_FLAG"
  echo "Route disabled"
}

route_on() {
  ensure_forward

  ip link show "$EXIT_IF" >/dev/null 2>&1 || tunnel_up

  route_off >/dev/null 2>&1 || true

  ip route add default dev "$EXIT_IF" table "$ROUTE_TABLE"
  ip rule add from "$CLIENT_SUBNET" table "$ROUTE_TABLE"
  iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -o "$EXIT_IF" -j MASQUERADE

  touch "$ROUTE_FLAG"
  echo "Route enabled"
}

restart_tunnel() {
  tunnel_down
  tunnel_up
  if [ -f "$ROUTE_FLAG" ]; then
    route_on
  fi
}

restore() {
  if [ -f "$ROUTE_FLAG" ]; then
    tunnel_up || true
    route_on || true
  fi
}

status() {
  echo "=== Config ==="
  echo "Exit interface: $EXIT_IF"
  echo "Client subnet: $CLIENT_SUBNET"
  echo "Route table: $ROUTE_TABLE"
  echo

  echo "=== Tunnel ==="
  if ip link show "$EXIT_IF" >/dev/null 2>&1; then
    echo "Tunnel: UP"
    wg show "$EXIT_IF" 2>/dev/null || true
  else
    echo "Tunnel: DOWN"
  fi

  echo
  echo "=== Route ==="
  if ip rule show | grep -q "from $CLIENT_SUBNET lookup $ROUTE_TABLE"; then
    echo "Route: ENABLED"
  else
    echo "Route: DISABLED"
  fi

  echo
  echo "=== Route table $ROUTE_TABLE ==="
  ip route show table "$ROUTE_TABLE" 2>/dev/null || true

  echo
  echo "=== NAT ==="
  iptables -t nat -S POSTROUTING | grep "$EXIT_IF" || true
}

uninstall_self() {
  echo "Removing WG Relay Manager..."

  route_off 2>/dev/null || true
  tunnel_down 2>/dev/null || true

  systemctl disable --now wg-relay-web.service 2>/dev/null || true
  systemctl disable --now wg-relay-restore.service 2>/dev/null || true

  rm -f /etc/systemd/system/wg-relay-web.service
  rm -f /etc/systemd/system/wg-relay-restore.service

  systemctl daemon-reload

  rm -f "$WG_CONF"
  rm -f /etc/sysctl.d/99-wg-relay.conf
  rm -f /usr/local/bin/wg-relay
  rm -rf "$APP_DIR"

  echo "WG Relay Manager removed"
}

case "$1" in
  tunnel-up) tunnel_up ;;
  tunnel-down) tunnel_down ;;
  restart) restart_tunnel ;;
  route-on) route_on ;;
  route-off) route_off ;;
  restore) restore ;;
  status) status ;;
  uninstall) uninstall_self ;;
  *)
    echo "Usage:"
    echo "  wg-relay tunnel-up"
    echo "  wg-relay tunnel-down"
    echo "  wg-relay restart"
    echo "  wg-relay route-on"
    echo "  wg-relay route-off"
    echo "  wg-relay status"
    echo "  wg-relay uninstall"
    exit 1
    ;;
esac
CLIEOF

chmod +x "$BIN"

cat > "$APP_DIR/app.py" <<'PYEOF'
from flask import Flask, request, redirect, render_template_string
import subprocess
import os

CONFIG = {}
with open("/opt/wg-relay-manager/config") as f:
    for line in f:
        if "=" in line:
            k, v = line.strip().split("=", 1)
            CONFIG[k] = v.strip('"')

WEB_PASSWORD = CONFIG.get("WEB_PASSWORD", "admin123")
WEB_PORT = int(CONFIG.get("WEB_PORT", "8090"))
APP_DIR = CONFIG.get("APP_DIR", "/opt/wg-relay-manager")
EXIT_IF = CONFIG.get("EXIT_IF", "wg-exit")
CLIENT_SUBNET = CONFIG.get("CLIENT_SUBNET", "10.8.0.0/24")

app = Flask(__name__)

def run(cmd):
    r = subprocess.run(cmd, shell=True, text=True, capture_output=True)
    return (r.stdout + r.stderr).strip()

def auth_ok():
    return request.args.get("key") == WEB_PASSWORD or request.form.get("key") == WEB_PASSWORD

LOGIN = """
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{background:#0f172a;color:white;font-family:Arial;margin:0}
.box{max-width:360px;margin:90px auto;background:#111827;padding:24px;border-radius:18px}
input,button{width:100%;padding:13px;border:0;border-radius:12px;box-sizing:border-box;margin-top:10px}
button{background:#22c55e;color:white;font-weight:bold}
</style>
</head>
<body>
<form class="box" method="get">
<h2>WG Relay Login</h2>
<input name="key" placeholder="Password">
<button>Login</button>
</form>
</body>
</html>
"""

HTML = """
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WG Relay Manager</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#0f172a;color:#e5e7eb;font-family:Arial}
.header{background:#111827;padding:18px 22px;border-bottom:1px solid #1f2937}
.container{max-width:980px;margin:auto;padding:22px}
.card{background:#111827;border-radius:18px;padding:18px;margin-bottom:16px;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.row{display:flex;gap:10px;flex-wrap:wrap}
button{border:0;border-radius:12px;padding:12px 16px;font-weight:bold;cursor:pointer;color:white}
.green{background:#22c55e}.red{background:#ef4444}.blue{background:#2563eb}.gray{background:#374151}
input[type=file]{background:#020617;padding:12px;border-radius:12px;width:100%;margin:10px 0;color:white}
pre{background:#020617;padding:14px;border-radius:12px;overflow:auto;white-space:pre-wrap}
.badge{display:inline-block;padding:6px 10px;border-radius:999px;background:#020617;color:#94a3b8;margin-top:6px}
.footer{text-align:center;color:#64748b;margin-top:22px}
</style>
</head>
<body>
<div class="header"><h2>WG Relay Manager</h2></div>
<div class="container">

<div class="card">
<h3>Exit Tunnel Config</h3>
<div class="badge">Interface: {{ exit_if }}</div>
<div class="badge">Client subnet: {{ client_subnet }}</div>
<form method="post" action="/upload?key={{ key }}" enctype="multipart/form-data">
<input type="file" name="config" required>
<button class="blue">Upload wg-exit.conf</button>
</form>
</div>

<div class="card">
<h3>Tunnel Control</h3>
<div class="row">
<form method="post" action="/action/tunnel-up?key={{ key }}"><button class="green">Start Tunnel</button></form>
<form method="post" action="/action/tunnel-down?key={{ key }}"><button class="red">Stop Tunnel</button></form>
<form method="post" action="/action/restart?key={{ key }}"><button class="blue">Restart Tunnel</button></form>
</div>
</div>

<div class="card">
<h3>Route Control</h3>
<p>Enable route = all WireGuard Easy clients in the subnet will exit through the remote node.</p>
<div class="row">
<form method="post" action="/action/route-on?key={{ key }}"><button class="green">Enable Route</button></form>
<form method="post" action="/action/route-off?key={{ key }}"><button class="red">Disable Route</button></form>
</div>
</div>

<div class="card">
<h3>Status</h3>
<form method="get" action="/">
<input type="hidden" name="key" value="{{ key }}">
<button class="gray">Refresh</button>
</form>
<pre>{{ status }}</pre>
</div>

<div class="card">
<h3>Danger Zone</h3>
<form method="post" action="/action/uninstall?key={{ key }}" onsubmit="return confirm('Uninstall WG Relay Manager?')">
<button class="red">Uninstall</button>
</form>
</div>

<div class="footer">Powered by Đại An VPN</div>
</div>
</body>
</html>
"""

@app.before_request
def auth():
    if not auth_ok():
        return LOGIN

@app.route("/")
def index():
    status = run("wg-relay status")
    return render_template_string(
        HTML,
        key=WEB_PASSWORD,
        status=status,
        exit_if=EXIT_IF,
        client_subnet=CLIENT_SUBNET
    )

@app.route("/upload", methods=["POST"])
def upload():
    f = request.files.get("config")
    if not f:
        return "No file", 400
    path = os.path.join(APP_DIR, f"{EXIT_IF}.conf")
    f.save(path)
    os.chmod(path, 0o600)
    return redirect("/?key=" + WEB_PASSWORD)

@app.route("/action/<action>", methods=["POST"])
def action(action):
    allowed = {
        "tunnel-up",
        "tunnel-down",
        "restart",
        "route-on",
        "route-off",
        "uninstall"
    }
    if action not in allowed:
        return "Invalid action", 400
    run(f"wg-relay {action}")
    if action == "uninstall":
        return "Uninstalled"
    return redirect("/?key=" + WEB_PASSWORD)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=WEB_PORT)
PYEOF

cat > /etc/systemd/system/wg-relay-web.service <<EOF
[Unit]
Description=WG Relay Manager Web UI
After=network.target

[Service]
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wg-relay-restore.service <<EOF
[Unit]
Description=Restore WG Relay Route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN restore

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wg-relay-web.service
systemctl enable wg-relay-restore.service

echo
echo "Installed WG Relay Manager"
echo
echo "Web UI:"
echo "  http://SERVER_IP:$WEB_PORT"
echo
echo "Password:"
echo "  $WEB_PASSWORD"
echo
echo "CLI:"
echo "  wg-relay status"
echo "  wg-relay tunnel-up"
echo "  wg-relay tunnel-down"
echo "  wg-relay route-on"
echo "  wg-relay route-off"
echo "  wg-relay uninstall"
