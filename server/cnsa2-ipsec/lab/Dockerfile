# Lab image: strongSwan 6.1.0 built against Debian's OpenSSL 3.5 for the
# CNSA 2.0 IPsec profile (AES-256-GCM, SHA-384, P-384 + ML-KEM-1024,
# ML-DSA-87 certificates). Not a production image.
FROM debian:trixie-slim
ARG SS_VERSION=6.1.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev curl ca-certificates bzip2 \
      iproute2 iputils-ping openssl tcpdump procps \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://download.strongswan.org/strongswan-${SS_VERSION}.tar.bz2 | tar xj -C /usr/src \
    && cd /usr/src/strongswan-${SS_VERSION} \
    && ./configure --prefix=/usr --sysconfdir=/etc --enable-openssl --enable-ml \
         --disable-gmp --enable-silent-rules >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null \
    && rm -rf /usr/src/strongswan-${SS_VERSION}
