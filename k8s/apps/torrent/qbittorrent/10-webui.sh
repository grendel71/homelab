#!/usr/bin/with-contenv bash
# Sets qBittorrent WebUI preferences from git. Runs as root before qBittorrent starts
# (LinuxServer custom-cont-init.d). Safe to run on every start.
# qBittorrent 5.x keeps web UI settings in the [WebUI] section with plain key names.
set -eu

CONF="${QB_CONF:-/config/qBittorrent/qBittorrent.conf}"
mkdir -p "$(dirname "$CONF")"
[ -f "$CONF" ] || : > "$CONF"

# set_pref SECTION KEY VALUE: set KEY=VALUE inside [SECTION]. Old KEY lines in that
# section are removed. If [SECTION] does not exist it is added at the end of the file.
# ENVIRON is used so a backslash in a key or value is not treated as an escape by awk.
set_pref() {
  S="[$1]" K="$2" V="$3" awk '
    BEGIN { insec = 0; seen = 0 }
    /^\[.*\]$/ { insec = ($0 == ENVIRON["S"]) }
    insec && index($0, ENVIRON["K"] "=") == 1 { next }
    { print }
    /^\[.*\]$/ && insec { print ENVIRON["K"] "=" ENVIRON["V"]; seen = 1 }
    END { if (!seen) { print ""; print ENVIRON["S"]; print ENVIRON["K"] "=" ENVIRON["V"] } }
  ' "$CONF" > "$CONF.tmp"
  cat "$CONF.tmp" > "$CONF"
  rm -f "$CONF.tmp"
}

# del_pref SECTION KEY: remove KEY from [SECTION] if present.
del_pref() {
  S="[$1]" K="$2" awk '
    /^\[.*\]$/ { insec = ($0 == ENVIRON["S"]) }
    insec && index($0, ENVIRON["K"] "=") == 1 { next }
    { print }
  ' "$CONF" > "$CONF.tmp"
  cat "$CONF.tmp" > "$CONF"
  rm -f "$CONF.tmp"
}

# Remove keys written by an earlier version of this script (old 4.x layout, wrong section).
for k in 'WebUI\AlternativeUIEnabled' 'WebUI\RootFolder' 'WebUI\AuthSubnetWhitelistEnabled' 'WebUI\AuthSubnetWhitelist'; do
  del_pref Preferences "$k"
done

# VueTorrent (installed to /vuetorrent by the DOCKER_MODS mod).
set_pref WebUI AlternativeUIEnabled true
set_pref WebUI RootFolder /vuetorrent

# Skip qBittorrent's own login for clients in this subnet (Envoy, after SSO).
if [ -n "${QB_AUTH_WHITELIST:-}" ]; then
  set_pref WebUI AuthSubnetWhitelistEnabled true
  set_pref WebUI AuthSubnetWhitelist "${QB_AUTH_WHITELIST}"
else
  set_pref WebUI AuthSubnetWhitelistEnabled false
fi

if [ "$(id -u)" = 0 ]; then
  chown 1000:1000 "$CONF"
fi
echo "[10-webui] preferences set (whitelist: ${QB_AUTH_WHITELIST:-off})"
