#!/bin/sh
# Creates the folders of the layout under /data (DATA_DIR) that do not exist yet, owned by
# PUID:PGID. Existing folders and files are left as they are, except an empty DATA_DIR of root's.
set -eu
# DATA_DIR that Docker created because it did not exist: empty, and root's.
if [ -z "$(ls -A /data)" ] && [ "$(stat -c %u /data)" = 0 ]; then
  chown "$PUID:$PGID" /data
fi
for dir in \
  torrents/movies torrents/shows torrents/music torrents/books \
  usenet/incomplete usenet/complete/movies usenet/complete/shows usenet/complete/music \
  usenet/complete/books media/movies media/shows media/music media/books; do
  path=/data
  for part in $(echo "$dir" | tr / ' '); do
    path=$path/$part
    if [ ! -d "$path" ]; then
      mkdir "$path"
      chown "$PUID:$PGID" "$path"
      echo "created $path"
    fi
  done
done
