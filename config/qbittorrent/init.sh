#!/bin/sh
# First start of qBittorrent (modules/qbittorrent.yaml): its settings for this stack, written only
# if it has none yet. Downloads go to /data/torrents, only through the VPN's interface, Gluetun,
# on the same host, may set the forwarded port without a password, and the page answers on any
# port QBITTORRENT_PORT publishes (qBittorrent refuses a Host header with another port).
set -eu
conf=/config/qBittorrent/qBittorrent.conf
if [ ! -s "$conf" ]; then
  mkdir -p /config/qBittorrent
  cp /defaults/qBittorrent.conf "$conf"
  chown -R "$PUID:$PGID" /config/qBittorrent
  echo "wrote $conf"
fi
