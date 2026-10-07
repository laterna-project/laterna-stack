#!/bin/sh
# Checks the stack: every module makes a valid configuration with the base, and the whole stack
# starts and works together, with Laterna started from deploy/compose of its repository and joined
# to the stack's network, as README.md says. The VPN is a WireGuard server of the test
# (test/vpn-server.yaml), used by Gluetun as a "custom" provider: the tunnel, its firewall and the
# clients behind it run for real. Then the services are connected to each other through their
# APIs, as README.md says to do in their pages, and each connection is tried by the service that
# receives it.
#
#   test/test.sh [config|run]...   (both by default)
#
# LATERNA_COMPOSE is the deploy/compose folder to start Laterna from; by default, that of the
# server repository's latest release (its main branch, or LATERNA_REF), cloned. LATERNA_IMAGE
# and LATERNA_VERSION choose another image of Laterna than the one deploy/compose uses.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
project=laterna-stack-test
modules="qbittorrent sabnzbd bazarr lidarr lazylibrarian flaresolverr recyclarr unpackerr"
started=""
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ -n "$started" ]; then
    (cd "$work" && stack logs --tail 40 >&2) || true
  fi
  if [ -f "$work/laterna/compose.yaml" ]; then
    (cd "$work/laterna" && docker compose -p "$project-laterna" down -v >/dev/null 2>&1) || true
  fi
  if [ -f "$work/compose.yaml" ]; then
    (cd "$work" && stack down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  # Some files there belong to the containers' users.
  docker run --rm -v "$work:/work" alpine rm -rf /work/test >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

cp -R "$here/." "$work"
cd "$work"
key() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
cp test/test.env .env
{
  printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)"
  echo "SONARR_API_KEY=$(key)"
  echo "RADARR_API_KEY=$(key)"
  echo "PROWLARR_API_KEY=$(key)"
  echo "LIDARR_API_KEY=$(key)"
  echo "SABNZBD_API_KEY=$(key)"
} >>.env
cp vpn.env.example vpn.env
mkdir -p test/data test/wireguard laterna

env_value() { sed -n "s/^$1=//p" .env | tail -n 1; }

# compose <modules...> -- <docker compose arguments>
compose() {
  files=compose.yaml
  while [ "$1" != "--" ]; do
    case $1 in
    test/*) files="$files:$1.yaml" ;;
    *) files="$files:modules/$1.yaml" ;;
    esac
    shift
  done
  shift
  COMPOSE_FILE=$files docker compose -p "$project" "$@"
}

# stack <docker compose arguments>: the whole stack of the run, with the test VPN.
stack() {
  # shellcheck disable=SC2086
  compose $modules test/vpn-server -- "$@"
}

# retry <seconds> <command...>: runs the command every 2 seconds until it succeeds.
retry() {
  deadline=$(($(date +%s) + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "gave up: $*" >&2
      return 1
    fi
    sleep 2
  done
}

config() {
  echo "config: base"
  compose -- config -q
  for m in modules/*.yaml; do
    m=$(basename "$m" .yaml)
    echo "config: $m"
    compose "$m" -- config -q
  done
  echo "config: everything"
  # shellcheck disable=SC2086
  compose $modules -- config -q
}

# servarr <port> <API version> <method> <path> [JSON]: calls Sonarr, Radarr, Lidarr or Prowlarr,
# which answers 4xx with the reason when it refuses a setting (connections are tried on save).
servarr() {
  case $1 in
  18989) k=SONARR_API_KEY ;; 17878) k=RADARR_API_KEY ;; 18686) k=LIDARR_API_KEY ;; *) k=PROWLARR_API_KEY ;;
  esac
  out=$(curl -sS -w '\n%{http_code}' -X "$3" -H "X-Api-Key: $(env_value $k)" -H 'Content-Type: application/json' \
    ${5:+-d "$5"} "http://127.0.0.1:$1/api/$2$4")
  code=$(echo "$out" | tail -n 1)
  case $code in
  2*) echo "$out" | sed '$d' ;;
  *)
    echo "$3 $4 on :$1 answered $code: $(echo "$out" | sed '$d')" >&2
    return 1
    ;;
  esac
}

# laterna <Service/Method> <JSON>: Laterna's API, as its administrator once set up.
token=""
laterna() {
  curl -fsS -X POST -H 'Content-Type: application/json' ${token:+-H "Authorization: Bearer $token"} \
    -d "$2" "http://127.0.0.1:18096/laterna.v1.$1"
}

# In qBittorrent's network namespace, the one of Gluetun: what goes out goes through the VPN.
in_vpn() { stack exec -T gluetun "$@"; }
qbt_local() { in_vpn wget -qO- "$@"; }

vpn_received() {
  compose test/vpn-server -- exec -T vpn-server wg show wg0 transfer | awk '{s += $2} END {print s + 0}'
}

# laterna_up starts Laterna from deploy/compose, with its external-network module on the stack's
# network and the stack's media as MEDIA_DIR: what README.md describes.
laterna_up() {
  if [ -n "${LATERNA_COMPOSE:-}" ]; then
    cp -R "$LATERNA_COMPOSE/." laterna
  else
    git clone -q --depth 1 --branch "${LATERNA_REF:-main}" https://github.com/laterna-project/laterna laterna-repo
    cp -R laterna-repo/deploy/compose/. laterna
  fi
  {
    echo "COMPOSE_FILE=compose.yaml:modules/external-network.yaml"
    echo "EXTERNAL_NETWORK=laterna-stack-test"
    echo "MEDIA_DIR=$work/test/data/media"
    echo "LATERNA_PORT=18096"
    if [ -n "${LATERNA_IMAGE:-}" ]; then echo "LATERNA_IMAGE=$LATERNA_IMAGE"; fi
    if [ -n "${LATERNA_VERSION:-}" ]; then echo "LATERNA_VERSION=$LATERNA_VERSION"; fi
  } >laterna/.env
  (cd laterna && docker compose -p "$project-laterna" up -d --quiet-pull --wait --wait-timeout 120 >up.log 2>&1) || {
    cat laterna/up.log >&2
    return 1
  }
}

run() {
  echo "run: VPN server"
  started=yes
  compose test/vpn-server -- up -d --quiet-pull vpn-server >/dev/null 2>&1
  retry 60 test -s test/wireguard/peer1/peer1.conf
  peer=test/wireguard/peer1/peer1.conf
  value() { sed -n "s/^$1 *= *//p" "$peer"; }
  cat >vpn.env <<VPN
VPN_SERVICE_PROVIDER=custom
VPN_TYPE=wireguard
WIREGUARD_ENDPOINT_IP=172.30.99.10
WIREGUARD_ENDPOINT_PORT=51820
WIREGUARD_PUBLIC_KEY=$(value PublicKey)
WIREGUARD_PRIVATE_KEY=$(value PrivateKey)
WIREGUARD_PRESHARED_KEY=$(value PresharedKey)
WIREGUARD_ADDRESSES=$(value Address)/32
VPN

  echo "run: the stack, then Laterna from deploy/compose"
  # shellcheck disable=SC2086
  stack up -d --quiet-pull --wait --wait-timeout 300 >up.log 2>&1 || {
    cat up.log >&2
    return 1
  }
  laterna_up

  echo "check: downloads go through the tunnel"
  before=$(vpn_received)
  stack exec -T qbittorrent curl -fsS -o /dev/null https://www.google.com/
  test "$(vpn_received)" -gt "$before"

  echo "check: the forwarded port reaches qBittorrent"
  up=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$project-gluetun-1" |
    sed -n 's/^VPN_PORT_FORWARDING_UP_COMMAND=//p' | sed 's/{{PORT}}/51413/; s/{{VPN_INTERFACE}}/tun0/')
  in_vpn sh -c "$up" >/dev/null 2>&1
  qbt_local http://127.0.0.1:8080/api/v2/app/preferences | jq -e '.listen_port == 51413 and .current_network_interface == "tun0"' >/dev/null

  echo "check: the layout allows hardlinks"
  # shellcheck disable=SC2016
  stack exec -T sonarr sh -c \
    'echo x >/data/torrents/shows/t && ln /data/torrents/shows/t /data/media/shows/t && test "$(stat -c %h /data/media/shows/t)" = 2'

  echo "check: Sonarr and Radarr use qBittorrent and SABnzbd"
  qbt_password=$(key)
  qbt_local --post-data "json={\"web_ui_password\":\"$qbt_password\"}" http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null
  retry 60 servarr 18989 v3 GET /system/status
  retry 60 servarr 17878 v3 GET /system/status
  for arr in 18989:tvCategory:shows 17878:movieCategory:movies; do
    port=${arr%%:*}
    field=$(echo "$arr" | cut -d: -f2)
    folder=${arr##*:}
    servarr "$port" v3 POST /downloadclient "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"gluetun\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"username\",\"value\":\"admin\"},{\"name\":\"password\",\"value\":\"$qbt_password\"},{\"name\":\"$field\",\"value\":\"$folder\"}]}" >/dev/null
    servarr "$port" v3 POST /downloadclient "{\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"name\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"$(env_value SABNZBD_API_KEY)\"},{\"name\":\"$field\",\"value\":\"$folder\"}]}" >/dev/null
    servarr "$port" v3 POST /rootfolder "{\"path\":\"/data/media/$folder\"}" >/dev/null
  done

  echo "check: Prowlarr feeds Sonarr, Radarr and Lidarr, through FlareSolverr when needed"
  retry 60 servarr 19696 v1 GET /system/status
  retry 60 servarr 18686 v1 GET /system/status
  for app in Sonarr:sonarr:8989:SONARR Radarr:radarr:7878:RADARR Lidarr:lidarr:8686:LIDARR; do
    name=$(echo "$app" | cut -d: -f1)
    host=$(echo "$app" | cut -d: -f2)
    port=$(echo "$app" | cut -d: -f3)
    servarr 19696 v1 POST /applications "{\"name\":\"$name\",\"implementation\":\"$name\",\"configContract\":\"${name}Settings\",\"syncLevel\":\"fullSync\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://$host:$port\"},{\"name\":\"apiKey\",\"value\":\"$(env_value "${app##*:}_API_KEY")\"}]}" >/dev/null
  done
  servarr 19696 v1 POST /indexerProxy '{"name":"FlareSolverr","implementation":"FlareSolverr","configContract":"FlareSolverrSettings","tags":[],"fields":[{"name":"host","value":"http://flaresolverr:8191/"},{"name":"requestTimeout","value":60}]}' >/dev/null

  echo "check: Recyclarr syncs the TRaSH profiles"
  stack exec -T recyclarr recyclarr sync >recyclarr.log 2>&1 || {
    cat recyclarr.log >&2
    return 1
  }
  servarr 18989 v3 GET /qualityprofile | jq -e 'map(.name) | index("WEB-1080p")' >/dev/null
  servarr 17878 v3 GET /qualityprofile | jq -e 'map(.name) | index("HD Bluray + WEB")' >/dev/null

  echo "check: Laterna hears from Sonarr and Radarr"
  token=$(laterna AuthService/Setup "{\"username\":\"admin\",\"password\":\"$(key)\",\"device\":{\"name\":\"test.sh\",\"client\":\"test.sh\"}}" | jq -r .token)
  for arr in SONARR:sonarr:8989 RADARR:radarr:7878; do
    kind=${arr%%:*}
    laterna IntegrationService/SetIntegration "{\"kind\":\"INTEGRATION_KIND_$kind\",\"url\":\"http://$(echo "$arr" | cut -d: -f2,3)\",\"apiKey\":\"$(env_value "${kind}_API_KEY")\"}" >/dev/null
    laterna IntegrationService/ConfigureIntegration "{\"kind\":\"INTEGRATION_KIND_$kind\",\"kodiMetadata\":true,\"webhookUrl\":\"http://laterna:8096\"}" |
      jq -e '.integration | .reachable and .kodiMetadata and .webhook' >/dev/null
  done

  echo "check: the other pages answer"
  retry 120 curl -fsS -o /dev/null http://127.0.0.1:16767/
  retry 120 curl -fsS -o /dev/null http://127.0.0.1:15299/
  retry 60 curl -fsS -o /dev/null http://127.0.0.1:18085/
  retry 60 curl -fsS -o /dev/null http://127.0.0.1:18080/
  test "$(docker inspect -f '{{.State.Running}}' "$project-unpackerr-1")" = true

  echo "check: without the VPN, nothing goes out"
  compose test/vpn-server -- stop vpn-server >/dev/null 2>&1
  if stack exec -T qbittorrent curl -fsS -o /dev/null --max-time 15 https://www.google.com/ 2>/dev/null; then
    echo "qBittorrent reached the Internet without the VPN" >&2
    return 1
  fi
}

if [ $# -eq 0 ]; then set -- config run; fi
for step in "$@"; do
  case $step in
  config) config ;;
  run) run ;;
  *)
    echo "unknown step $step (config, run)" >&2
    exit 2
    ;;
  esac
done
echo "stack ok"
