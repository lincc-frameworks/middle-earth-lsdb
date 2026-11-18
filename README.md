# middle-earth-lsdb

Containerized deployment of the LSDB websites for UW DiRAC VM infrastructure,
following
[middle-earth-service-example](https://github.com/dirac-institute/middle-earth-service-example).

One Apache container serves:

- **[data.lsdb.io](https://data.lsdb.io)**: the catalog browser, built from a
  pinned commit of
  [astronomy-commons/data.lsdb.io](https://github.com/astronomy-commons/data.lsdb.io),
  and the HATS catalogs at `/hats/`, bind-mounted read-only from the shire
  storage server;
- **[lsdb.io](https://lsdb.io)**: the project's landing page, from a pinned
  commit of
  [astronomy-commons/lsdb.io](https://github.com/astronomy-commons/lsdb.io).

A second container reports the VM's CPU, memory and disks to the DiRAC gadget
monitor.

```bash
git clone <this repo>
cd middle-earth-lsdb
sudo ./init.sh
podman compose up -d --build
```

- **`DEPLOY.md`**: deploying, verifying, updating the websites, how the
  catalogs are served, and the design choices.
- **`SECRETS.md`**: why there are none, and the NFS ownership model.
- **`monitoring/README.md`**: the service VM monitor.

To try it on a laptop with Docker: `./dev-startup.sh`.
