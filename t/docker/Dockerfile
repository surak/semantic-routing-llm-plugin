# Test::Nginx environment for running APISIX's own test harness against this
# plugin: the released APISIX image (OpenResty + Lua deps) + Test::Nginx +
# the matching APISIX source tree (t/APISIX.pm, t/lib, ...).
ARG APISIX_VERSION=3.19.0
FROM apache/apisix:${APISIX_VERSION}-debian
ARG APISIX_VERSION
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends git perl cpanminus make gcc libc6-dev ca-certificates \
 && cpanm --notest Test::Nginx IPC::Run \
 && rm -rf /var/lib/apt/lists/* /root/.cpanm
RUN git clone --depth 1 --branch ${APISIX_VERSION} https://github.com/apache/apisix.git /apisix \
 && git -C /apisix submodule update --init --depth 1 t/toolkit \
 && ln -s /usr/local/apisix/deps /apisix/deps
WORKDIR /apisix
ENV PATH=/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin:$PATH \
    PERL5LIB=/apisix \
    TEST_NGINX_BINARY=/usr/local/openresty/bin/openresty
