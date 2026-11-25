# The router in front of the blue and green app containers (httpd.conf here,
# deploy.sh at the top of the repo). Apache again, as a plain reverse proxy.

FROM docker.io/library/httpd:2.4

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

# conf/state is owned by the service account in the image so that the empty
# `router-state` volume takes that ownership the first time it is mounted.
RUN groupadd -g ${SVC_GID} ${SVC_USER} 2>/dev/null || true && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} 2>/dev/null || true && \
    mkdir -p /usr/local/apache2/conf/state && \
    chown -R ${SVC_UID}:${SVC_GID} /usr/local/apache2/logs /usr/local/apache2/conf/state

COPY httpd.conf /usr/local/apache2/conf/extra/router.conf
RUN sed -i -e 's/^Listen 80$/#Listen 80/' \
           -e 's/^#\(LoadModule proxy_module \)/\1/' \
           -e 's/^#\(LoadModule proxy_http_module \)/\1/' \
        /usr/local/apache2/conf/httpd.conf && \
    grep -q '^LoadModule proxy_http_module ' /usr/local/apache2/conf/httpd.conf && \
    echo 'Include conf/extra/router.conf' >> /usr/local/apache2/conf/httpd.conf

EXPOSE 8080

CMD ["httpd-foreground"]
