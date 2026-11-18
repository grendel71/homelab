#!/usr/bin/with-contenv bash
# Sets qBittorrent WebUI preferences from git. Runs as root before qBittorrent starts
# (LinuxServer custom-cont-init.d). Safe to run on every start.
set -eu

CONF="${QB_CONF:-/config/qBittorrent/qBittorrent.conf}"
mkdir -p "$(dirname "$CONF")"
[ -f "$CONF" ] || printf '[Preferences]\n' > "$CONF"
grep -q '^\[Preferences\]' "$CONF" || printf '[Preferences]\n' >> "$CONF"

# set_pref KEY VALUE: remove old KEY lines, then add KEY=VALUE under [Preferences].
# ENVIRON is used so the backslash in KEY is not treated as an escape by awk.
set_pref() {
  K="$1" V="$2" awk '
    index($0, ENVIRON["K"] "=") == 1 { next }
    { print }
    /^\[Preferences\]/ { print ENVIRON["K"] "=" ENVIRON["V"] }
  ' "$CONF" > "$CONF.tmp"
  cat "$CONF.tmp" > "$CONF"
  rm -f "$CONF.tmp"
}

# VueTorrent (installed to /vuetorrent by the DOCKER_MODS mod).
set_pref 'WebUI\AlternativeUIEnabled' 'true'
set_pref 'WebUI\RootFolder' '/vuetorrent'

# Skip qBittorrent's own login for clients in this subnet (Envoy, after SSO).
if [ -n "${QB_AUTH_WHITELIST:-}" ]; then
  set_pref 'WebUI\AuthSubnetWhitelistEnabled' 'true'
  set_pref 'WebUI\AuthSubnetWhitelist' "${QB_AUTH_WHITELIST}"
else
  set_pref 'WebUI\AuthSubnetWhitelistEnabled' 'false'
fi

if [ "$(id -u)" = 0 ]; then
  chown 1000:1000 "$CONF"
fi
echo "[10-webui] preferences set (whitelist: ${QB_AUTH_WHITELIST:-off})"
