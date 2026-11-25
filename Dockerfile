# The LSDB websites, served by one Apache:
#
#   data.lsdb.io   the catalog browser, built from source, plus the HATS
#                  catalogs under /hats/
#   lsdb.io        the project's landing page (plain files, no build)
#
# Stage 1 fetches each site's `production` branch and builds data.lsdb.io.
# Stage 2 is Apache with the results. The HATS catalogs are not in the image;
# compose.yaml bind-mounts them read-only at /srv/hats.

# ── Stage 1: fetch and build the sites ──────────────────────────────────────
FROM docker.io/library/node:22-bookworm-slim AS sites

# What to deploy: the `production` branch of each site's repo. Every build
# downloads the branch as it is at that moment, so releasing a site is merging
# its `main` into `production` and rebuilding on the VM (DEPLOY.md, "Updating
# the websites"). A tag or a full commit id also works here, to hold a site at
# one version.
#   https://github.com/astronomy-commons/data.lsdb.io
ARG DATA_SITE_REF=production
#   https://github.com/astronomy-commons/lsdb.io
ARG MAIN_SITE_REF=production

# The commit a downloaded archive was made from: GitHub records it in the
# archive's header. Written to each site's /VERSION, since a branch name says
# nothing about what is actually deployed.
RUN printf '%s\n' '#!/bin/sh' \
        'id=$(gzip -dc "$1" | head -c 1024 | grep -a -o -E "[0-9a-f]{40}" | head -n 1)' \
        '[ -n "$id" ] || { echo "no commit id in $1" >&2; exit 1; }' \
        'echo "$id"' > /usr/local/bin/archive-commit && \
    chmod +x /usr/local/bin/archive-commit

# lsdb.io: served as it is in the repo, minus the files that aren't the site.
WORKDIR /out/lsdb.io
ADD https://github.com/astronomy-commons/lsdb.io/archive/${MAIN_SITE_REF}.tar.gz /tmp/main.tar.gz
RUN tar -xzf /tmp/main.tar.gz --strip-components=1 && \
    rm -rf README README.md .gitignore .github CNAME && \
    archive-commit /tmp/main.tar.gz > VERSION && rm /tmp/main.tar.gz

# data.lsdb.io: webpack build + prerendered pages, into dist/.
WORKDIR /build
ADD https://github.com/astronomy-commons/data.lsdb.io/archive/${DATA_SITE_REF}.tar.gz /tmp/data.tar.gz
RUN tar -xzf /tmp/data.tar.gz --strip-components=1 && \
    archive-commit /tmp/data.tar.gz > /tmp/data.version && rm /tmp/data.tar.gz
# HUSKY=0: the git hooks are for developers; there is no .git here.
RUN HUSKY=0 npm ci
RUN npm run build && \
    # The legacy host read this for its 404 fallback; that now lives in
    # apache/httpd.conf, where .htaccess files are not read at all.
    rm -f dist/.htaccess && \
    mv /tmp/data.version dist/VERSION && \
    mv dist /out/data.lsdb.io

# ── Stage 2: serve them ─────────────────────────────────────────────────────
FROM docker.io/library/httpd:2.4

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

RUN groupadd -g ${SVC_GID} ${SVC_USER} 2>/dev/null || true && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} 2>/dev/null || true && \
    mkdir -p /srv/hats && \
    chown -R ${SVC_UID}:${SVC_GID} /srv /usr/local/apache2/logs

COPY --from=sites --chown=${SVC_UID}:${SVC_GID} /out/data.lsdb.io/ /srv/data.lsdb.io/
COPY --from=sites --chown=${SVC_UID}:${SVC_GID} /out/lsdb.io/      /srv/lsdb.io/

COPY apache/httpd.conf /usr/local/apache2/conf/extra/httpd-custom.conf
RUN sed -i 's/^Listen 80$/#Listen 80/' /usr/local/apache2/conf/httpd.conf && \
    echo 'Include conf/extra/httpd-custom.conf' >> /usr/local/apache2/conf/httpd.conf

EXPOSE 8080

# Apache is the only process, so there is no start.sh. Logs go to the
# container's stdout/stderr (the base image's default): `podman logs`.
CMD ["httpd-foreground"]
