#!/bin/sh
# First start of SABnzbd (modules/sabnzbd.yaml): its settings for this stack, written only if it
# has none yet. Downloads go to /data/usenet/complete/<category>, with the categories shows, movies,
# music and books, and the API key is the one of .env. Usenet servers are added in its pages.
set -eu
ini=/config/sabnzbd.ini
if [ ! -s "$ini" ]; then
  cat >"$ini" <<INI
[misc]
api_key = $SABNZBD_API_KEY
download_dir = /data/usenet/incomplete
complete_dir = /data/usenet/complete
host_whitelist = sabnzbd,
[categories]
[[shows]]
name = shows
dir = shows
[[movies]]
name = movies
dir = movies
[[music]]
name = music
dir = music
[[books]]
name = books
dir = books
INI
  chown "$PUID:$PGID" "$ini"
  echo "wrote $ini"
fi
