# middle-earth-lsdb

Containerized deployment of the LSDB websites for UW DiRAC VM infrastructure,
following
[middle-earth-service-example](https://github.com/dirac-institute/middle-earth-service-example).

One Apache container (behind a small router container, so that deploys drop
no requests) serves:

- **[data.lsdb.io](https://data.lsdb.io)**: the catalog browser, built from the
  `production` branch of
  [astronomy-commons/data.lsdb.io](https://github.com/astronomy-commons/data.lsdb.io),
  and the HATS catalogs at `/hats/`, bind-mounted read-only from the shire
  storage server;
- **[lsdb.io](https://lsdb.io)**: the project's landing page, from the
  `production` branch of
  [astronomy-commons/lsdb.io](https://github.com/astronomy-commons/lsdb.io).

A second container reports the VM's CPU, memory and disks to the DiRAC gadget
monitor.

```bash
git clone <this repo>
cd middle-earth-lsdb
sudo ./init.sh
./deploy.sh
```

After that the VM deploys by itself: merging to a site's `production` branch
goes live within a few minutes, with no downtime.

- **`DEPLOY.md`**: deploying, verifying, updating the websites, how the
  blue/green deploy works, how the catalogs are served, and the design
  choices.
- **`SECRETS.md`**: why there are none, and the NFS ownership model.
- **`monitoring/README.md`**: the service VM monitor.

To try it on a laptop with Docker: `./dev-startup.sh`.
