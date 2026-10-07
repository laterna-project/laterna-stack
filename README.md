# Laterna stack

The services that bring media to [Laterna](https://github.com/laterna-project/laterna), in Docker
Compose: Sonarr (series), Radarr (movies), Prowlarr (indexers), qBittorrent behind a VPN,
SABnzbd for Usenet, and the modules around them (subtitles, music, books, quality profiles). Every
setting that can be chosen in advance is, so that the services find each other with little
clicking, and a test starts the whole stack, VPN included, on every change.

Laterna itself is a module here. For HTTPS, single sign-on, monitoring and the rest, run it from
[`deploy/compose`](https://github.com/laterna-project/laterna/tree/develop/deploy/compose) of the
server's repository instead, joined to this stack ([below](#with-laterna-from-deploycompose)).

Use it for what you have the right to download: works in the public domain or under a free
license, your own recordings, Linux images. A VPN hides your traffic from your provider; it does
not make a download legal.

- [Contents](#contents)
- [Starting](#starting)
- [Folders](#folders)
- [VPN](#vpn)
- [Connecting the services](#connecting-the-services)
- [With Laterna from deploy/compose](#with-laterna-from-deploycompose)
- [Upgrading](#upgrading)
- [Checking the files](#checking-the-files)

## Contents

`compose.yaml` is the base; modules add to it, listed in `COMPOSE_FILE` in `.env`.

| | Service | Page | |
|---|---|---|---|
| `compose.yaml` | Sonarr, Radarr, Prowlarr, Gluetun (VPN) | :8989, :7878, :9696 | base |
| `modules/laterna.yaml` | Laterna, reading the media of the stack | :8096 | |
| `modules/qbittorrent.yaml` | qBittorrent, only through the VPN | :8080 | torrents |
| `modules/sabnzbd.yaml` | SABnzbd | :8085 | Usenet |
| `modules/flaresolverr.yaml` | FlareSolverr, for indexers behind Cloudflare | | |
| `modules/bazarr.yaml` | Bazarr, subtitles | :6767 | |
| `modules/lidarr.yaml` | Lidarr, music | :8686 | |
| `modules/lazylibrarian.yaml` | LazyLibrarian, books | :5299 | |
| `modules/recyclarr.yaml` | Recyclarr, the TRaSH Guides' quality profiles | | |
| `modules/unpackerr.yaml` | Unpackerr, extracts RAR torrents | | |

Choices made here:

- **qBittorrent** is the only torrent client: Gluetun gives it the port the VPN forwards, it is
  the one the TRaSH Guides document, and every *arr talks to it.
- **SABnzbd** for Usenet: its folders and categories are set for the stack on its first start.
- **LazyLibrarian** for books: Readarr is no longer maintained.
- **No request page** (Overseerr, Jellyseerr): they sign users in through Plex, Jellyfin or Emby,
  not Laterna.

## Starting

Docker with Compose 2.24.4 or later. Linux is the reference. Docker Desktop (Windows, macOS) runs
the stack too, but hardlinks between downloads and media may not work on folders of the Windows or
macOS disk: imports then copy.

```sh
git clone https://github.com/laterna-project/laterna-stack
cd laterna-stack
cp .env.example .env
cp vpn.env.example vpn.env
```

1. In `.env`: `DATA_DIR`, the folder for downloads and media (on a disk with room), and `PUID`,
   `PGID`, the user that owns it (`id -u`, `id -g`).
2. Still in `.env`, an API key for each service (`openssl rand -hex 16` each time):
   `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`, and those of the modules you add
   (`SABNZBD_API_KEY`, `LIDARR_API_KEY`). They are set here rather than in each service's pages,
   so that the others can use them.
3. In `vpn.env`: your VPN ([VPN](#vpn)).
4. `COMPOSE_FILE` lists the modules: Laterna and qBittorrent by default.

```sh
docker compose up -d
```

The first start creates the folders of `DATA_DIR` that are missing, then
[connect the services](#connecting-the-services). Your own changes go in `local.yaml`, last in
`COMPOSE_FILE` (git ignores it), not in the files here.

## Folders

Everything lives in `DATA_DIR`, which every service sees at `/data`. Downloads and media being on
the same mount, an import is a hardlink (instant, no extra space, and the torrent keeps seeding)
or a rename, never a copy. This is the layout of the
[TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/):

```
DATA_DIR
├── torrents/    shows, movies, music, books   qBittorrent, one folder per category
├── usenet/
│   ├── incomplete
│   └── complete/  shows, movies, music, books  SABnzbd, one folder per category
└── media/       shows, movies, music, books   the libraries: Sonarr, Radarr, Lidarr,
                                               LazyLibrarian write there, Laterna reads
```

`DATA_DIR` must be one file system: two disks joined by Docker mounts break hardlinks. For several
disks, pool them first (mergerfs, ZFS, Btrfs, a RAID). In Laterna, create the libraries
`/data/media/shows`, `/data/media/movies`, `/data/media/music` and `/data/media/books`.

## VPN

[Gluetun](https://github.com/qdm12/gluetun) holds the VPN, and qBittorrent shares its network: if
the tunnel drops, Gluetun's firewall cuts qBittorrent off instead of letting it out in the clear.
Sonarr, Radarr and the others do not go through the VPN.

**ProtonVPN** (a paid plan, for P2P servers and port forwarding):

1. At [account.proton.me](https://account.proton.me/u/0/vpn/WireGuard), create a WireGuard
   configuration: platform GNU/Linux, a P2P server, and **NAT-PMP (Port Forwarding)** on.
2. Copy its `PrivateKey` to `WIREGUARD_PRIVATE_KEY` in `vpn.env`. The other lines are already set:
   P2P servers only, port forwarding on, countries to adjust.
3. `docker compose up -d`, then `docker compose logs gluetun`: the public address, then
   `port forwarded is` and the port. Gluetun gives that port to qBittorrent, again each time it
   changes.

**Other providers:** `vpn.env.example` has Private Internet Access (port forwarding too), AirVPN
(a port forwarded in its client area), Mullvad (no port forwarding: fewer peers) and any WireGuard
configuration file (`custom`). Gluetun supports about thirty others:
[its wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

To check what the outside sees:

```sh
docker compose exec gluetun wget -qO- https://ipinfo.io
```

## Connecting the services

The first time, in this order. Addresses are those of the Docker network.

1. **qBittorrent** (http://<this machine>:8080): user `admin`, the temporary password from
   `docker compose logs qbittorrent`. Set your own password (Options, WebUI). Downloads go to
   `/data/torrents`, only through the VPN; leave "Bypass authentication for clients on
   localhost" on: Gluetun uses it to set the port.
2. **SABnzbd** (:8085): add your Usenet provider. Folders, categories and API key are already
   set.
3. **Sonarr** (:8989) and **Radarr** (:7878): Settings, Media Management, root folder
   `/data/media/shows` or `/data/media/movies`. Settings, Download Clients:
   - qBittorrent: host `gluetun`, port `8080`, user `admin` and your password, category
     `shows` (Sonarr) or `movies` (Radarr).
   - SABnzbd: host `sabnzbd`, port `8080`, API key `SABNZBD_API_KEY`, same categories.
4. **Prowlarr** (:9696): Settings, Apps, add Sonarr (`http://sonarr:8989`), Radarr
   (`http://radarr:7878`), Lidarr, LazyLibrarian, with Prowlarr's address `http://prowlarr:9696`
   and their API keys; then add the indexers once, in Prowlarr: it hands them to all. For indexers
   behind Cloudflare, Settings, Indexers: a FlareSolverr proxy at `http://flaresolverr:8191/` with
   a tag, given to those indexers only.
5. **Lidarr** (:8686): root folder `/data/media/music`, the same download clients with category
   `music`. **LazyLibrarian** (:5299): library `/data/media/books`, category `books`.
6. **Bazarr** (:6767): Settings, Sonarr and Radarr, with their addresses and API keys, then the
   languages you want. It writes subtitles next to the videos, where Laterna finds them.
7. **Recyclarr**: `RECYCLARR_PROFILES=english` (original language) or `french` (MULTi.VF: the
   French dub and the original audio), then `docker compose exec recyclarr recyclarr sync`, and
   daily on its own. Pick the profiles it creates for your series and movies.
8. **Laterna**, Administration, Sonarr and Radarr: `http://sonarr:8989` and
   `http://radarr:7878` with their API keys, then let Laterna turn on Kodi metadata (the NFO
   files and images it reads) and install its webhook at `http://laterna:8096`: it hears about
   each import at once.

## With Laterna from deploy/compose

The stack's network is called `laterna-stack`. In `deploy/compose` of the server's repository,
leave `modules/laterna.yaml` out here, and there:

```sh
COMPOSE_FILE=compose.yaml:modules/external-network.yaml:...
EXTERNAL_NETWORK=laterna-stack
MEDIA_DIR=<DATA_DIR>/media
```

Laterna then reaches `http://sonarr:8989` and Sonarr reaches `http://laterna:8096`, as above.
Laterna sees the media at `/media` there, Sonarr at `/data/media` here: it matches them by
itself.

## Upgrading

`docker compose pull && docker compose up -d`. The images follow their latest release, except
Gluetun (v3), Recyclarr (8), Unpackerr (0) and Laterna (`LATERNA_VERSION`). The `diun` module of
`deploy/compose` tells you when one changes. `git pull` brings the latest version of these files.

## Checking the files

[`test/test.sh`](test/test.sh) checks every module, then starts the whole stack with a WireGuard
server of its own as the VPN, and checks:

- qBittorrent's traffic goes through the tunnel, and nothing goes out once the tunnel stops;
- Gluetun's port forwarding command sets qBittorrent's port;
- downloads and media can be hardlinked;
- Sonarr and Radarr accept qBittorrent and SABnzbd, Prowlarr accepts Sonarr, Radarr, Lidarr and
  FlareSolverr, Recyclarr creates the TRaSH profiles, Laterna installs its webhook in Sonarr and
  Radarr.

The CI runs it on each change and every week. A real provider's port forwarding is not part of
it: it takes an account.

```sh
sh test/test.sh
```

## License

[GPL-3.0](LICENSE), like Laterna.
