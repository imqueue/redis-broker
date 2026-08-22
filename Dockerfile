# imqueue/redis-broker — one image, both announcer modules, the operator picks at
# runtime with IMQ_BROKER_MODE.
#
# Why one image rather than one per module: the question the two modules answer
# differently — "does this network deliver broadcast?" — is usually not answerable
# until the pod is scheduled. A runtime switch means the same manifest moves from
# a laptop bridge network to a GCP VPC by changing one environment variable.
#
# Published for the Redis versions in .github/workflows/release.yml. It also
# builds against older ones — `--build-arg REDIS_VERSION=6.2` works and is
# tested — but those are not published, because a tag is a promise to rebuild on
# CVE and 6.2 is end of life upstream.

ARG REDIS_VERSION=7.4

FROM redis:${REDIS_VERSION} AS builder

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        uuid-dev \
        libcurl4-openssl-dev \
        libjson-c-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY modules/promoter  ./promoter
COPY modules/unicaster ./unicaster

# Built separately so a failure names which module broke.
RUN make -C promoter && make -C unicaster

FROM redis:${REDIS_VERSION}

# Runtime libraries only. libcurl and json-c are here even in promoter mode,
# which costs a few MB the broadcast path never calls — the price of one image
# instead of two, and cheaper than making the operator choose at pull time.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libuuid1 \
        libcurl4 \
        libjson-c5; \
    rm -rf /var/lib/apt/lists/*

# org.opencontainers.image.source is what links the GHCR package back to this
# repository, so the package page shows the README and the licence rather than an
# orphan blob. NOTE: it does NOT make the package public — GHCR packages are
# private on first publish whatever the repository's visibility, and that is a
# one-time change under the org's package settings.
LABEL org.opencontainers.image.source="https://github.com/imqueue/redis-broker" \
      org.opencontainers.image.description="Redis that announces itself — both @imqueue broker-discovery modules in one image, chosen at runtime with IMQ_BROKER_MODE" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.url="https://imqueue.org/blog/horizontally-scalable-redis-broker/" \
      org.opencontainers.image.vendor="@imqueue" \
      org.opencontainers.image.title="redis-broker"

COPY --from=builder /src/promoter/promoter.so   /usr/local/lib/redis_modules/promoter.so
COPY --from=builder /src/unicaster/unicaster.so /usr/local/lib/redis_modules/unicaster.so

COPY conf/redis-broker.conf.template /usr/local/share/redis-broker/redis-broker.conf.template
COPY entrypoint.sh /usr/local/bin/redis-broker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/redis-broker-entrypoint.sh; \
    mkdir -p /etc/redis

# 6379 is Redis. 63000/udp is where the announcer shouts, and where a service's
# UDPClusterManager listens. Both are needed for discovery to work.
EXPOSE 6379 63000/udp

# Wraps the official entrypoint rather than replacing it: that script does uid
# handling and argument rewriting this image has no business reimplementing.
ENTRYPOINT ["/usr/local/bin/redis-broker-entrypoint.sh"]
CMD ["redis-server"]
