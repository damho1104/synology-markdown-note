# Synology Markdown Note Web Installation

**English** | [한국어](SELF-HOSTING_KO.md)

Run on a server with Docker and Docker Compose v2 installed. The Synology NAS must have Note Station installed. The web container uses the `ghcr.io/damho1104/synology-md-note-web:latest` image published to GHCR through GitHub Actions. No local source build is required.

## Quick installation

```sh
# 1. Create an installation directory
mkdir -p ~/synology-md-note-web && cd ~/synology-md-note-web

# 2. Download Compose and the configuration file
wget https://raw.githubusercontent.com/damho1104/synology-markdown-note/main/web/docker-compose.yaml
wget -O .env https://raw.githubusercontent.com/damho1104/synology-markdown-note/main/web/.env.example

# 3. Start the service
# If your NAS is on a private network, first change NAS_ALLOW_PRIVATE to true in .env.
# To connect directly from another PC, change WEB_BIND_ADDRESS to 0.0.0.0.
docker compose up -d

# 4. Check the initial setup code used to configure the NAS address in the web interface
# Skip this step if you have already specified NAS_URL in .env.
docker compose exec web cat /data/setup-code
```

On the same PC, open `http://localhost:8787`; on another PC, open `http://<server-address>:8787`. Enter the NAS address and initial setup code on the initial setup screen, then log in with your NAS account. The encryption key and initial setup code are generated automatically, so you do not need to generate secrets yourself.

**By default, only connections from the local PC are allowed.** To connect from another PC, set `WEB_BIND_ADDRESS=0.0.0.0` in `.env` or connect an HTTPS reverse proxy. Enter your NAS account password and OTP on the web login screen, not in `.env`.

## Common configuration examples

If your NAS is at `192.168.1.20` on a private network and you also want to access the web app from another PC, configure `.env` as follows.

```dotenv
NAS_URL=http://192.168.1.20:5000
NAS_ALLOW_PRIVATE=true
WEB_BIND_ADDRESS=0.0.0.0
WEB_PORT=8787
```

Example of an HTTPS NAS using a publicly trusted certificate:

```dotenv
NAS_URL=https://nas.example.com:5001
NAS_ALLOW_PRIVATE=false
```

If the NAS address resolves to a private IP, `NAS_ALLOW_PRIVATE=true` is required even with HTTPS. An HTTP NAS connection does not encrypt account information or note transfers. HTTP/HTTPS for access to the web app and HTTP/HTTPS for connections from the web server to the NAS are separate.

After changing environment variables, run again:

```sh
docker compose up -d
```

## Required and optional settings

**All environment variables have defaults and can be omitted.** You must enter the NAS address either through `NAS_URL` in `.env` or during initial web setup. Detailed comments are in [docker-compose.yaml](docker-compose.yaml) and [.env.example](.env.example).

| Setting | Requirement | Default / when to change |
| --- | --- | --- |
| `WEB_IMAGE` | Optional | `ghcr.io/damho1104/synology-md-note-web:latest`. Change to pin a specific published version |
| `NAS_URL` | Optional | Configure the NAS address in the web interface if unspecified |
| `NAS_ALLOW_PRIVATE` | Conditional | Defaults to `false`. Requires `true` for a private-network address or HTTP NAS |
| `WEB_BIND_ADDRESS` | Optional | `127.0.0.1`. Change to `0.0.0.0` or another suitable address for direct access from another PC |
| `WEB_PORT` | Optional | `8787` |
| `WEB_DATA_PATH` | Optional | The `synonote-web-data` named volume. Specify an absolute path to use a host folder |
| `NAS_CA_FILE` | Optional | Omit for normal installations. Use the configuration below only for an HTTPS NAS requiring a private CA |
| `WEB_PUBLIC_ORIGIN` | Optional, advanced | Empty by default. Specify the exact origin when the proxy cannot preserve the browser's Host |
| `WEB_COOKIE_SECURE` | Optional, advanced | `auto`. No change needed for normal installations |

## Optional: Store data in a Synology folder

This step is unnecessary when using the default named volume. To mount a NAS folder directly, prepare a **new dedicated folder**.

```sh
sudo mkdir -p /volume1/docker/synology-md-note-web/data
sudo chown 10001:10001 /volume1/docker/synology-md-note-web/data
sudo chmod 700 /volume1/docker/synology-md-note-web/data
```

`.env`:

```dotenv
WEB_DATA_PATH=/volume1/docker/synology-md-note-web/data
```

The container runs as UID/GID `10001:10001`. Do not change permissions on an existing folder used by another service. In Container Manager, use the folder containing the downloaded files as the project path.

## Optional: HTTPS reverse proxy

Set the proxy target to `http://<web-server-address>:8787` and preserve the Host and port used by the browser. A proxy on the same host can use `http://127.0.0.1:8787`. In a separate container, `127.0.0.1` refers to that container itself.

Example inside an Nginx HTTPS server block:

```nginx
client_max_body_size 20m;
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $http_host;
}
```

Configure the domain and TLS certificate on the proxy. Normal setups handle cookies and origin automatically and need no additional settings. Only if Host cannot be preserved, set `WEB_PUBLIC_ORIGIN=https://notes.example.com` in `.env`. Serve the app at `/` on a dedicated domain.

## Optional: Private CA certificate

**Not required for a publicly trusted certificate or an HTTP NAS.** Configure this only for an HTTPS NAS that requires trusting a private CA. No separate Compose file is used.

1. Save the trusted CA PEM to `certs/nas-ca.pem` in the installation directory. Do not include a private key.
2. Uncomment the optional CA mount under `volumes` in `docker-compose.yaml`. If your host path differs, also update `source`.
3. Add the following line to `.env`.

```dotenv
NAS_CA_FILE=/etc/synonote/nas-ca.pem
```

The CA file is mounted read-only. If the file is missing, the mount fails instead of automatically creating a directory, and UID 10001 must be able to read the file. The NAS address must also match the certificate hostname. There is no option to disable certificate verification.

## Updating

Confirm that any note being edited has finished saving, back up `/data`, and then run the following commands. They fetch the default `latest` image or the image tag specified in `.env`.

```sh
cd ~/synology-md-note-web
docker compose pull web
docker compose up -d
docker compose ps
```

If Compose or environment variables have changed, compare the files and apply the changes according to the deployment guide. Do not unconditionally overwrite your existing `.env` with the new example; retain the NAS address, port, data path, and optional CA settings. Refresh the browser too, after confirming that saving has completed.

## Backup and troubleshooting

Stop the web service and back up **all** of `/data`. Keep the database, `master.key`, and SQLite `-wal`/`-shm` files together.

```sh
docker compose stop web
mkdir -p ./backups
chmod 700 ./backups
backup_dir="./backups/data-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$backup_dir"
docker compose cp web:/data/. "$backup_dir/"
docker compose start web
```

To restore, stop the service, copy the entire backup into a new dedicated folder, set UID/GID to `10001:10001`, directory permissions to 0700, and database/key file permissions to 0600, then mount it using `WEB_DATA_PATH`. Do not overwrite a running database. Original notes reside on the NAS, so a separate Note Station backup is also required. **Do not use `docker compose down -v` for updates, as it deletes the data.**

```sh
docker compose logs --tail=100 web
docker compose config --quiet
curl --fail http://127.0.0.1:8787/api/ready
```

Adjust addresses and ports to match your installation. `/api/ready` indicates that the web server is ready; it does not indicate successful NAS login or writes. If private-network connections are rejected, check `NAS_ALLOW_PRIVATE`; if you are returned to the login screen after logging in, check browser cookies and the proxy Host setting; for permission errors, check `/data` ownership.

See the [web README](README.md) for features and supported scope.

> Deployment administrators: The installation commands above become usable after the files are publicly available on GitHub `main` and the GHCR image is published by Actions. The GHCR package must also allow public reads. Writing this document alone does not complete publication or public-access configuration.
