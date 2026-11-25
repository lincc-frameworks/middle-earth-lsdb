# Deploying the LSDB websites to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure.

One Apache container serves two sites: **data.lsdb.io** (the catalog browser
and the HATS catalogs under `/hats/`) and **lsdb.io** (the project's landing
page). A small router container in front of it lets a new version be
deployed without dropping a request. The VM provides a reverse proxy that
handles TLS termination and routes traffic for both names to the router on
port 8080.

```bash
git clone <this repo> /root/middle-earth-lsdb
cd /root/middle-earth-lsdb
sudo ./init.sh
./deploy.sh
```

From then on the VM deploys by itself: a timer checks every minute
whether a site's `production` branch has moved (see "Updating the websites").

Then verify:

```bash
curl -s http://localhost:8080/VERSION
# the commit of data.lsdb.io that is deployed

curl -s -H 'Host: lsdb.io' http://localhost:8080/VERSION
# the commit of lsdb.io that is deployed; a different value
# from the line above shows Apache is telling the two sites apart

curl -s http://localhost:8080/ | grep -o '<title>.*</title>'
# <title>LSDB</title>

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/hats/
# 200 (a directory listing of the published catalogs)

curl -s http://localhost:9110/metrics | grep -E 'load1 |filesystem_size|source_success'
# service_vm_load1 ..., one filesystem_size line per local disk filesystem,
# and service_vm_monitor_source_success{source="..."} 1 for all five sources
```

Then register the VM with the gadget monitor; see "Monitoring" below.

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: reads the service account from `/root/VM.set` and checks it exists on the VM, installs podman + podman-compose, enables `podman-restart.service`, checks the catalog storage is mounted and readable, writes `.env`, installs and enables the `lsdb-deploy` timer. Idempotent; safe to re-run. |
| `deploy.sh` | The blue/green deploy: builds a new app image, starts it beside the live container, checks it, switches the router to it, and retires the old container once its downloads are done. `--if-changed` deploys only when a site's `production` branch has moved; `--status` says what is live. |
| `deploy/` | The systemd service and timer that run `deploy.sh --if-changed` every minute. Installed by `init.sh`. |
| `Dockerfile` | Two stages. The first downloads the `production` branch of [astronomy-commons/data.lsdb.io](https://github.com/astronomy-commons/data.lsdb.io) and [astronomy-commons/lsdb.io](https://github.com/astronomy-commons/lsdb.io), and builds the former with Node (`npm ci && npm run build`); the latter is plain files. The second is Apache httpd 2.4 with the results in `/srv/data.lsdb.io` and `/srv/lsdb.io`. |
| `router/` | The router image: Apache as a reverse proxy, forwarding everything on port 8080 to whichever app container is live. |
| `compose.yaml` | Four services: `router` (port 8080), `app-blue` and `app-green` (the same Apache image with the catalogs bind-mounted read-only; one is live at a time), and `monitoring` (the VM's CPU, memory and disks on port 9110). Driven by `deploy.sh`, not by `podman compose up`. |
| `apache/httpd.conf` | Two Apache virtual hosts on plain HTTP port 8080, chosen by `Host` header. `data.lsdb.io` (the default): the website, and the public catalogs from `/srv/hats/published` as `/hats/` with directory listings. `lsdb.io`: the landing page. |
| `monitoring/` | Service VM monitor, copied unchanged from [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor). Its image and compose settings (`monitoring/compose.yaml`, pulled into `compose.yaml` with `extends`). See `monitoring/README.md`. |
| `dev-startup.sh` | Local development helper for macOS: runs `deploy.sh` with docker as your own uid/gid with an empty local catalog directory, since a laptop has neither `VM.set` nor the storage. |
| `tests/zero-downtime.sh` | Deploys a second time during a slow download and continuous requests, and fails if anything was dropped. Run by CI. |
| `SECRETS.md` | Why the service has no secrets, the NFS ownership model, and what to do if it ever gets one. |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  VM reverse  ──►  │  router container: apache (port 8080)     │
  proxy :8080      │    forwards everything, Host header and   │
                   │    all, to the live app container         │
                   └───────────────┬──────────────────────────┘
                                   │ compose network
                   ┌───────────────▼──────────────────────────┐
                   │  app container, "blue" or "green": apache │
                   │    Host: data.lsdb.io                     │
                   │      /        → website (in the image)    │
                   │      /hats/*  → /srv/hats/published ──────┼──► /service/hats-catalogs
                   │    Host: lsdb.io                          │     (NFS, on the VM)
                   │      /        → website (in the image)    │
                   └──────────────────────────────────────────┘
                     (during a deploy both colours run: the new
                      one takes new requests, the old one
                      finishes its downloads and exits)

  gadget monitor   ┌──────────────────────────────────────────┐
  (polls every ──► │  monitoring container (port 9110)         │
  minute) :9110    │    /metrics → this VM's CPU, memory,      │
                   │               disks, load (VM's / at      │
                   │               /host, read-only)           │
                   └──────────────────────────────────────────┘
```

## Updating the websites

The sites' source is not in this repo. A deploy builds the commit that the
`production` branch of each site's repo points at:

| Site | Source | Branch set by |
|---|---|---|
| data.lsdb.io | `astronomy-commons/data.lsdb.io`, `production` | `DATA_SITE_BRANCH` in `deploy.sh` |
| lsdb.io | `astronomy-commons/lsdb.io`, `production` | `MAIN_SITE_BRANCH` in `deploy.sh` |

Development happens on each site's `main`; `production` is what is live.
**Merging to `production` deploys.** Releasing a change to a site is one
step: in the site's repo, merge `main` into `production` (a pull request
from `main` to `production`). Within a few minutes the VM notices, builds, and
switches to the new version, with no downtime. So merge there only what is
ready to go live.

To see what happened, on the VM:

```bash
./deploy.sh --status                  # which colour is live, and at which commits
journalctl -u lsdb-deploy -n 50       # the timer's deploys, and any failures
systemctl list-timers lsdb-deploy.timer
```

`/VERSION` on each site also prints the commit that is live.

**If a build fails**, nothing changes: the live container is not touched
until a new one has built, started and passed its checks. The failure is in
the journal, and the timer tries again on its next run.

**To go back to an earlier version**, revert the change on the site's
`production` branch; the revert deploys like any other change. To hold a
site at one version meanwhile, set its `*_SITE_BRANCH` in `deploy.sh` to a
tag or a full commit id; set it back to the branch afterwards.

**To stop automatic deploys**: `systemctl disable --now lsdb-deploy.timer`.
`./deploy.sh` still deploys by hand.

## Deploying by hand

A change to this repo (the Apache configuration, the `Dockerfile`) is not
picked up by the timer, which only watches the sites. Deploy it yourself:

```bash
cd /root/middle-earth-lsdb
git pull
./init.sh                       # only if init.sh or deploy/ changed
./deploy.sh
```

This is the same no-downtime deploy the timer does. To confirm the live
container has the change, look inside it, not at the checkout:

```bash
live=$(./deploy.sh --status | sed -n 's/^live: \([a-z]*\).*/\1/p')
podman exec lsdb-app-$live grep -n 'Alias /hats' /usr/local/apache2/conf/extra/httpd-custom.conf
```

**Do not use `podman compose up` or `down` to deploy.** `up` would start
both colours at once and leave the router pointing where it was; `down`
stops everything, router included. `podman compose down` is still how to
stop the whole service on purpose; `./deploy.sh` brings it back.

**A change under `router/` is the exception.** The router is the one
container that cannot be replaced without a gap, because it is what holds
port 8080. `./deploy.sh --router` rebuilds and restarts it as part of a
deploy; the sites are unavailable for a few seconds and downloads in
progress are cut off. The router's configuration is a dozen lines and
should rarely change.

## Moving a VM from the single-container setup

Before the router there was one container, `lsdb-app`, on port 8080. The
first `./deploy.sh` on such a VM builds and checks the new app container
while `lsdb-app` keeps serving, then removes `lsdb-app` and starts the
router in its place. That one changeover has a gap of a few seconds; every
deploy after it has none.

```bash
cd /root/middle-earth-lsdb
git pull
sudo ./init.sh      # installs the timer; its first run is two minutes later
./deploy.sh
```

## How a deploy works

There are two app containers, `lsdb-app-blue` and `lsdb-app-green`, built
from the same `Dockerfile`. One is live; the other normally does not exist.
`deploy.sh`:

1. asks GitHub which commit each site's `production` branch points at;
2. builds the image for the idle colour from exactly those commits, while
   the live container keeps serving;
3. starts it, and checks it directly on its own port (8081 for blue, 8082
   for green): both sites answer, at the expected commits, and `/hats/`
   lists the catalogs;
4. rewrites the router's `backend.conf` to name the new container and sends
   the router a graceful reload (`SIGUSR1`). Requests already in progress
   finish against the old container; new ones go to the new one;
5. checks the sites again, this time through the router, and switches back
   if they do not answer;
6. stops the old container gracefully. Apache finishes the requests it has
   and exits; if a download is still going after an hour
   (`DRAIN_SECONDS`), it is cut off. The container is then removed.

Which colour is live is recorded in one place, the router's `backend.conf`,
kept in the `router-state` volume so it survives a restart of the router.

CI runs this for real on every pull request: `tests/zero-downtime.sh`
deploys during a slow 300 MB download and a stream of requests to both
sites, and fails if any request is not a 200 or the download is short.

## Two sites, one container

The VM's reverse proxy sends everything to port 8080, and the router passes
it on unchanged, so Apache tells the sites apart by the `Host` header. **The
proxy must pass the original `Host` through** (`data.lsdb.io`, `lsdb.io`, `www.lsdb.io`); if it rewrites it,
every request gets the default site, data.lsdb.io. The default also answers
for the VM's own name and for `localhost`, which is why the checks above
need `-H 'Host: lsdb.io'` to reach the other one.

The lsdb.io site also answers to `lsdb-alt.astro.washington.edu`, a second
name for the VM, so it can be tested through the proxy before `lsdb.io`
itself is pointed here:

```bash
curl -s https://lsdb-alt.astro.washington.edu/ | wc -c
```

Both sites have the title "LSDB", so compare sizes: the lsdb.io landing page
is about 12 KB and the data.lsdb.io front page about 4 KB. Getting the 4 KB
page here means the proxy is rewriting `Host` (or the container predates
this alias and needs a redeploy).

To add a third site, add a fetch step and a `COPY` in the `Dockerfile` and a
`<VirtualHost>` in `apache/httpd.conf`. A second repo on this VM would
compete for ports 8080 and 9110.

## The catalogs: `/hats/`

`https://data.lsdb.io/hats/<name>/...` is what LSDB clients read, and the
largest part of what this service serves. The data is not in the image or the
repo. It lives on the shire storage server, in `hats/catalogs`
(`/astro/store/shire/hats/catalogs` as seen from arnor or epyc), which IT
mounts on the VM at `/service/hats-catalogs`. `init.sh` names that mount point
(`HATS_DIR`, at the top of the script) and `compose.yaml` bind-mounts it
read-only at `/srv/hats`.

**Only `hats/catalogs/published/` is served.** That directory holds nothing
but symlinks, one per public catalog, pointing at the catalogs beside it:

```
hats/catalogs/
├── published/                 <- served as https://data.lsdb.io/hats/
│   ├── delve -> ../delve
│   ├── erosita -> ../erosita_dr1_erass1       (public name differs)
│   ├── dp1 -> ../dp1/public_parquet           (part of a catalog)
│   └── ...
├── delve/
├── erosita_dr1_erass1/
├── dp1/                       <- the rest of this is not public
└── gaia_dr2/                  <- no link, so no URL
```

A catalog is public if and only if it has a link in `published/`, and the
link's name is its public name. The links are made by hand on a machine
that mounts shire, not on the VM.

- **Publishing a catalog:** put it in `hats/catalogs` and link it from
  `published/`, for example
  `cd hats/catalogs/published && ln -s ../erosita_dr1_erass1 erosita`.
  It is served at once; nothing is restarted. To give it a description in the listing, add an
  `AddDescription` line to `apache/httpd.conf` and rebuild.
- **Unpublishing:** remove its link from `published/`.
- **Links must be relative and stay inside `hats/catalogs`.** The VM mounts
  only that directory, so a link to anywhere else is dangling there (on the
  legacy host they pointed into `/epyc/data3`).
- **The catalog must be readable by everyone.** The web server runs as the
  VM's service account, which is neither the owner nor in the group of these
  files. A catalog that is not world-readable answers 403.
- **`.htaccess` files are not read** (`AllowOverride None`). All Apache
  configuration is in `apache/httpd.conf`.

**What this does and does not protect.** The web server only maps URLs into
`published/`, so a catalog with no link there cannot be requested, whatever
else is in the directory. But the links are the whole access list, so:

- Whoever can write to `published/` decides what the world can download. The
  script creates it writable by its owner only; keep it that way.
- A symlink *inside* a published catalog is followed too. Publishing a
  directory publishes everything reachable from it.
- The web server can still read every world-readable file in the mount. For
  data that must not get out (Rubin data-rights releases, for example), do
  not rely on the missing link alone: make it not world-readable (or keep
  it outside `hats/catalogs`), so that a mistaken link answers 403 instead
  of serving it.

## Design choices

**One container, one process.** Both sites are static files, so the app
container runs Apache and nothing else. There is no application process to
reverse-proxy to and no `start.sh`.

**Blue/green behind our own router, not the VM's proxy.** A container cannot
be replaced in place without a gap: the old one has to let go of port 8080
before the new one can take it, and a catalog download in progress is cut
off. So two app containers take turns, and a router container that never
needs to change holds the port. The switch could have been done in the VM's
reverse proxy instead, but that is IT's standard configuration, not this
repo's. The same images would run unchanged somewhere that brings its own
load balancer, with the router dropped.

**The sites are built inside the image.** Nobody builds on a laptop and copies
files to the server. What is deployed is exactly one commit of each site,
the tip of its `production` branch when the image was built, visible at
`/VERSION`.

**Containers for everything but the deploy itself.** The only things
`init.sh` does on the host are check the service account, install podman,
check the storage mount, and install the timer that runs `deploy.sh`. That
script has to live on the host, since it is what builds and replaces the
containers. The
service account, SSH, SELinux and the NFS mount are provisioned by IT.

**Almost nothing is written.** The app containers keep no state. The only
state is which colour is live: one small file in the router's `router-state`
volume. Apache's access and error logs go to each container's stdout/stderr:
`podman logs lsdb-router`, `podman logs lsdb-app-blue` (or `-green`).

**Service account with fixed uid/gid.** The service account name, uid, and gid
come from IT's `/root/VM.set` on the VM, and flow through `.env` into the
Dockerfile and compose.yaml with no fallback defaults. Nothing about the
account is committed to the repo. Apache runs as that uid, which is the one
that can read the catalogs on the NFS share (`root_squash`; see `SECRETS.md`).

**Port 8080, localhost only.** The router listens on port 8080 and the
compose file binds it to `127.0.0.1:8080`, with ordinary port mapping (no
host networking). The app containers are also bound to localhost, on 8081
and 8082, only so that `deploy.sh` can check a new one before it is live. The VM's reverse proxy handles TLS termination and routes
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
- `/service/hats-catalogs` is mounted, readable by the service account, and
  has a `published/` directory of links to the public catalogs. `init.sh`
  warns if not; the app container will not start if the mount point does
  not exist.
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
enabled, which `init.sh` does. The router and the live app container come
back as they were, and the router still points at the same colour. The
`lsdb-deploy` timer is enabled too, so a reboot also resumes automatic
deploys. The NFS mount must also come back at boot;
that is IT's `/etc/fstab` entry, not something this repo manages.
