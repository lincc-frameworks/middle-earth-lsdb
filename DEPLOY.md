# Deploying the LSDB websites to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure.

One container serves two sites: **data.lsdb.io** (the catalog browser and the
HATS catalogs under `/hats/`) and **lsdb.io** (the project's landing page).
The VM provides a reverse proxy that handles TLS termination and routes
traffic for both names to the container on port 8080.

```bash
git clone <this repo> /root/middle-earth-lsdb
cd /root/middle-earth-lsdb
sudo ./init.sh
podman compose up -d --build
```

Then verify:

```bash
curl -s http://localhost:8080/VERSION
# the commit of data.lsdb.io that is deployed (DATA_SITE_REF in the Dockerfile)

curl -s -H 'Host: lsdb.io' http://localhost:8080/VERSION
# the commit of lsdb.io that is deployed (MAIN_SITE_REF); a different value
# from the line above shows Apache is telling the two sites apart

curl -s http://localhost:8080/ | grep -o '<title>.*</title>'
# <title>LSDB</title>

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/hats/
# 200 (a directory listing of the catalogs)

curl -s http://localhost:9110/metrics | grep -E 'load1 |filesystem_size|source_success'
# service_vm_load1 ..., one filesystem_size line per local disk filesystem,
# and service_vm_monitor_source_success{source="..."} 1 for all five sources
```

Then register the VM with the gadget monitor; see "Monitoring" below.

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: reads the service account from `/root/VM.set` and checks it exists on the VM, installs podman + podman-compose, enables `podman-restart.service`, checks the catalog storage is mounted and readable, writes `.env`. Idempotent; safe to re-run. |
| `Dockerfile` | Two stages. The first downloads pinned commits of [astronomy-commons/data.lsdb.io](https://github.com/astronomy-commons/data.lsdb.io) and [astronomy-commons/lsdb.io](https://github.com/astronomy-commons/lsdb.io), and builds the former with Node (`npm ci && npm run build`); the latter is plain files. The second is Apache httpd 2.4 with the results in `/srv/data.lsdb.io` and `/srv/lsdb.io`. |
| `compose.yaml` | Two services: `app` (Apache on port 8080, with the catalogs bind-mounted read-only) and `monitoring` (the VM's CPU, memory and disks on port 9110). |
| `apache/httpd.conf` | Two Apache virtual hosts on plain HTTP port 8080, chosen by `Host` header. `data.lsdb.io` (the default): the website, and the catalogs from `/srv/hats` as `/hats/` with directory listings. `lsdb.io`: the landing page. |
| `monitoring/` | Service VM monitor, copied unchanged from [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor). Its image and compose settings (`monitoring/compose.yaml`, pulled into `compose.yaml` with `extends`). See `monitoring/README.md`. |
| `dev-startup.sh` | Local development helper for macOS: runs `docker compose` as your own uid/gid with an empty local catalog directory, since a laptop has neither `VM.set` nor the storage. |
| `SECRETS.md` | Why the service has no secrets, the NFS ownership model, and what to do if it ever gets one. |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  VM reverse  ──►  │  app container: apache (port 8080)        │
  proxy :8080      │    Host: data.lsdb.io                     │
                   │      /        → website (in the image)    │
                   │      /hats/*  → /srv/hats (read-only) ────┼──► /service/hats-catalogs
                   │    Host: lsdb.io                          │     (NFS, on the VM)
                   │      /        → website (in the image)    │
                   └──────────────────────────────────────────┘

  gadget monitor   ┌──────────────────────────────────────────┐
  (polls every ──► │  monitoring container (port 9110)         │
  minute) :9110    │    /metrics → this VM's CPU, memory,      │
                   │               disks, load (VM's / at      │
                   │               /host, read-only)           │
                   └──────────────────────────────────────────┘
```

## Updating the websites

The sites' source is not in this repo. The image takes each from one pinned
commit, named in the `Dockerfile`:

| Site | Source | Pinned by |
|---|---|---|
| data.lsdb.io | `astronomy-commons/data.lsdb.io` | `DATA_SITE_REF` |
| lsdb.io | `astronomy-commons/lsdb.io` | `MAIN_SITE_REF` |

After a change is merged in a site's repo:

1. Set its ref in the `Dockerfile` to the new commit and commit that here.
2. On the VM: `git pull && podman compose up -d --build`.
3. `/VERSION` on that site should print the new commit (see the checks at
   the top).

For data.lsdb.io this replaces the legacy `npm run build` + `rsync` to epyc +
`scripts/post-deploy.sh`. To go back, set the ref back and rebuild.

## Two sites, one container

The VM's reverse proxy sends everything to port 8080, so Apache tells the
sites apart by the `Host` header. **The proxy must pass the original `Host`
through** (`data.lsdb.io`, `lsdb.io`, `www.lsdb.io`); if it rewrites it,
every request gets the default site, data.lsdb.io. The default also answers
for the VM's own name and for `localhost`, which is why the checks above
need `-H 'Host: lsdb.io'` to reach the other one.

To add a third site, add a fetch step and a `COPY` in the `Dockerfile` and a
`<VirtualHost>` in `apache/httpd.conf`. A second repo on this VM would
compete for ports 8080 and 9110.

## The catalogs: `/hats/`

`https://data.lsdb.io/hats/<name>/...` is what LSDB clients read, and the
largest part of what this service serves. The data is not in the image or the
repo. It lives on the shire storage server, in `hats/catalogs`
(`/astro/store/shire/hats/catalogs` as seen from arnor), which IT mounts on
the VM at `/service/hats-catalogs`. `init.sh` names that mount point
(`HATS_DIR`, at the top of the script) and `compose.yaml` bind-mounts it
read-only at `/srv/hats`.

- **Adding a catalog** means putting it in `hats/catalogs` on shire (from
  arnor, for example), readable by the service account (see `SECRETS.md`).
  It is served at once; nothing is restarted. To give it a description in the listing, add an `AddDescription`
  line to `apache/httpd.conf` and rebuild.
- **Entries should be real directories, or symlinks that stay inside
  `HATS_DIR`.** The container sees only that directory, so a symlink to
  anywhere else (as on the legacy host, where they pointed into
  `/epyc/data3`) is dangling inside it.
- **`.htaccess` files are not read** (`AllowOverride None`). All Apache
  configuration is in `apache/httpd.conf`.

## Design choices

**One container, one process.** Both sites are static files, so the container
runs Apache and nothing else. There is no application process to
reverse-proxy to and no `start.sh`.

**The sites are built inside the image.** Nobody builds on a laptop and copies
files to the server. What is deployed is exactly one commit of each site,
recorded in the repo and visible at `/VERSION`.

**Containers for everything.** The only things `init.sh` does on the host are
check the service account, install podman, and check the storage mount. The
service account, SSH, SELinux and the NFS mount are provisioned by IT.

**Nothing is written.** The container keeps no state. Apache's access and
error logs go to the container's stdout/stderr: `podman logs lsdb-app`.

**Service account with fixed uid/gid.** The service account name, uid, and gid
come from IT's `/root/VM.set` on the VM, and flow through `.env` into the
Dockerfile and compose.yaml with no fallback defaults. Nothing about the
account is committed to the repo. Apache runs as that uid, which is the one
that can read the catalogs on the NFS share (`root_squash`; see `SECRETS.md`).

**Port 8080, localhost only.** The container listens on port 8080 and the
compose file binds it to `127.0.0.1:8080`, with ordinary port mapping (no
host networking). The VM's reverse proxy handles TLS termination and routes
external traffic to this port. The one exception is the monitoring
container's port 9110 (see "Monitoring").

**Monitoring is part of every service.** Each service VM runs the same
small monitor container, so the gadget monitor can graph its CPU, memory,
disks and load. It is copied into the repo rather than written per service.

## Service identity: `/root/VM.set`

IT leaves `/root/VM.set` on every VM when it provisions it. It is in tcsh
syntax and names the VM and its service account:

```
set VM=myservice
set VMUSER=astro-myservice
set VMUID=NNNNNNN
set VMGID=NNNNNNNNNN
set VMGECOS="My Service Management User"
```

`init.sh` reads `VMUSER`, `VMUID` and `VMGID` from it. It parses the file and
never runs it, and ignores lines of any other form. It exits if the file is
missing, if any of the three is missing or malformed, or if the account does
not exist on the VM with exactly that uid and primary gid. If `VM` doesn't
match the VM's short hostname, it warns, because the file may have been
copied from another VM. `VMGECOS` is not used.

There is no copy of these values in the repo. If `VM.set` is missing or wrong,
ask PACS via help-astro@uw.edu rather than writing your own.

## Per-host configuration: `.env`

`init.sh` writes the account to `.env` as `SVC_USER`, `SVC_UID` and
`SVC_GID`, along with the host's own FQDN (`SVC_FQDN`), which compose.yaml
uses as the Apache `ServerName` and container hostname, and the catalog
directory (`HATS_DIR`). Podman compose reads `.env` automatically:

```
# Written by init.sh on every run; don't edit.
SVC_USER=astro-myservice
SVC_UID=NNNNNNN
SVC_GID=NNNNNNNNNN
SVC_FQDN=myservice.astro.washington.edu
HATS_DIR=/service/hats-catalogs
```

The Dockerfile and compose.yaml consume these values with no hardcoded
defaults, so running `podman compose` without a populated `.env` fails on the
missing variables. `.env` is gitignored and derived: `init.sh` rewrites it on
every run. Re-run `init.sh` rather than editing it, and never copy it between
hosts.

## VM infrastructure context

DiRAC VMs run Rocky 10 and use podman (not Docker) as the container runtime.
Key things to know:

- **podman-compose** is the compose frontend. It reads the same `compose.yaml`
  format as `docker compose`. Install it from EPEL; `init.sh` handles this.
- **podman-restart.service** must be enabled for `restart: unless-stopped` to
  survive a VM reboot. `init.sh` enables it.
- **The VM's reverse proxy** handles TLS termination and firewall rules.
  The container listens on `127.0.0.1:8080` and does not need to manage TLS or
  open ports itself.
- **Service accounts** exist because the NFS share uses `root_squash`. The
  container process must run as a uid that can read the share. IT creates
  this account on the VM and names it in `/root/VM.set`; `init.sh` checks the
  two agree and exits if they do not.
- **The build needs the network**: Docker Hub for the base images, GitHub for
  the sites' source, and the npm registry for data.lsdb.io's dependencies.

## Rollout to another VM

The procedure above is the whole deployment. On a new VM, confirm:

- `/root/VM.set` exists and names a service account that exists on the VM
  (IT provisions both).
- The VM has network access to Docker Hub, GitHub and the npm registry.
- `/service/hats-catalogs` is mounted and holds the catalogs, readable by
  the service account. `init.sh` warns if not; the app container will not
  start if the directory does not exist.
- For production: the VM is listed in the gadget monitor's
  `config/service_vms.toml` (see "Monitoring").

## Monitoring

The `monitoring` container is the gadget monitor's **service VM monitor**. It
serves the VM's CPU, memory, disk and load figures as Prometheus text on
`http://<vm fqdn>:9110/metrics`. The gadget monitor
([middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor))
polls that every minute and graphs it on its **Service VMs** dashboard.
`monitoring/README.md` lists the metrics and explains each compose setting.

**Keep `monitoring/` identical to the gadget monitor's copy.** Do not edit it
here. To update it, copy the folder over again from the gadget monitor's
repo. The only per-service lines are in `compose.yaml`: `container_name` and
`labels`.

**Port 9110 is reachable from anywhere.** Unlike 8080, it is published
on every interface and does not go through the VM's reverse proxy or TLS,
because the gadget monitor connects to it directly. Podman DNATs the port, so
firewalld does not need to open it. Anyone who can reach the VM can read
these figures. They are resource numbers only, which was judged acceptable.
`monitoring/README.md` explains how to restrict who can read them.

Only the VM's local disks are reported. The catalog storage is NFS, which the
monitor skips on purpose, so its free space does not appear on the dashboard.

### Registering the VM with the gadget monitor

Deploying the container is not enough on its own. The gadget monitor only
polls VMs listed in its `config/service_vms.toml`. Once the service is
running on its production VM:

1. **Check the endpoint from another machine**, using the production VM's
   own FQDN (what `hostname -f` prints on it, which is also `SVC_FQDN` in
   its `.env`):

   ```bash
   curl -s http://<vm fqdn>:9110/metrics | grep source_success
   ```

   Every `source` should report `1`. If it can't connect, the gadget monitor
   can't either. Fix that first.

2. **Open a pull request** against
   [dirac-institute/middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor).
   It should add one entry to `config/service_vms.toml`:

   ```toml
   [[service_vm]]
   name = "lsdb"               # becomes the `service_vm` label on the dashboard
   address = "<vm fqdn>"       # the production VM's FQDN, as in step 1
   ```

   - `name` should stay stable: renaming it later starts new series and
     breaks the VM's history on the dashboard. It must not match any existing
     `name` in the file.
   - `address` must be the production VM, never a dev or test box.
   - In the PR description, give this repo and paste the step 1 `curl`
     output, so the reviewer knows the endpoint answers.

3. **After it merges and the gadget monitor is redeployed**, the VM
   appears on the **Service VMs** dashboard within a minute or two.

A VM that is retired or renamed needs another PR to remove or change its
entry. Otherwise the dashboard shows it as down.

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does. The NFS mount must also come back at boot;
that is IT's `/etc/fstab` entry, not something this repo manages.
