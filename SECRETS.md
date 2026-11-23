# Secrets layout

No secret is ever committed to this repo or baked into a container image.

**This service currently has no secrets.**

- Both websites are static files from public repos
  ([astronomy-commons/data.lsdb.io](https://github.com/astronomy-commons/data.lsdb.io)
  and [astronomy-commons/lsdb.io](https://github.com/astronomy-commons/lsdb.io)).
- The HATS catalogs served under `/hats/` are public data, served without
  authentication. Only the catalogs linked from `hats/catalogs/published/`
  are served (`DEPLOY.md`, "The catalogs").
- TLS is terminated by the VM's reverse proxy, so the container holds no
  certificate or key. (On the legacy host, epyc, Apache held the
  data.lsdb.io certificate itself; that does not carry over.)

The one thing mounted into the container from shire is the catalog data
(`/service/hats-catalogs`, `HATS_DIR` in `.env`), read-only. It is not secret, but the ownership rules below apply
to it just the same.

## Ownership and root_squash

The shire mounts (`/service/shire`, `/service/hats-catalogs`) are exported
with `root_squash`, so **root on the VM cannot write to them** and reads
them as `nobody`. The container runs as the service
account named in IT's `/root/VM.set` (`VMUSER`, `VMUID`, `VMGID`), which
`init.sh` also writes to the repo's `.env` as `SVC_USER`, `SVC_UID`, `SVC_GID`.
That account must be able to read the catalogs: directories need `r-x` and
files `r--` for it (or for everyone). `init.sh` checks the top directory and
warns if it can't.

To look at the share the way the container sees it, become that user. In
bash, `source .env` in the repo directory first to set the `SVC_*` names.

```bash
sudo -u $SVC_USER ls -l $HATS_DIR
```

## If the service ever needs a secret

For example, a password file for a catalog that is not public. Follow the
DiRAC pattern: put it on the share, owned by the service account, and
bind-mount it read-only.

```bash
sudo -u $SVC_USER install -m 0600 /path/to/secret \
    /service/shire/secrets/my-secret
```

```yaml
volumes:
  - "/service/shire/secrets:/srv/secrets:ro"
```

```
/service/shire/secrets/                0755  $SVC_USER
/service/shire/secrets/<secret-file>   0600  $SVC_USER
```

`/service/shire` is the service's own area and is not served. Never put a
secret under `HATS_DIR`: the web server can read everything there that is
world-readable, and serves whatever `published/` links to.
