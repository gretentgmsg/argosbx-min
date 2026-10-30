# syntax=docker/dockerfile:1
# Minimal Hysteria2 (sing-box) + VLESS-Reality (Xray) + optional Cloudflare Argo (cloudflared) image.
# Binaries come ONLY from the official upstream GitHub releases and are verified against pinned SHA256 at build time.
#
# Upgrade procedure: change the version ARGs below, then update the matching SHA256 ARGs from:
#   sing-box:  https://github.com/SagerNet/sing-box/releases  (download asset, sha256sum)
#   Xray:      https://github.com/XTLS/Xray-core/releases      (asset "Xray-linux-<arch>.zip.dgst")
#   cloudflared: https://github.com/cloudflare/cloudflared/releases (download asset, sha256sum)

FROM debian:bookworm-slim AS fetch
ARG TARGETARCH
ARG SINGBOX_VERSION=1.14.4
ARG XRAY_VERSION=26.10.21
ARG CF_VERSION=2026.10.5
# SHA256 of the release assets (verified against upstream on 2026-10-28).
ARG SB_SHA256_AMD64=231e57c18378f780a08de832844a1ca9716e17a7bcf82964b350844d243c03ac
ARG SB_SHA256_ARM64=241cb4ccbf1a003235f8a969cc25d28cc74487df52721f6de28be7e37eae2ae9
ARG XR_SHA256_AMD64=0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978
ARG XR_SHA256_ARM64=d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c
ARG CF_SHA256_AMD64=e1bc0cf084fd9e590554fe769a86b1db46701c3f847a43d902f7b974a4e16298
ARG CF_SHA256_ARM64=72e0d05a67e09da87cf495e409a28c3cc5994dd23fc66a982eebea6a55923b7d
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/dl
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) SB_ARCH=amd64; XR_ARCH=64;        CF_ARCH=amd64; SB_SHA="${SB_SHA256_AMD64}"; XR_SHA="${XR_SHA256_AMD64}"; CF_SHA="${CF_SHA256_AMD64}" ;; \
      arm64) SB_ARCH=arm64; XR_ARCH=arm64-v8a; CF_ARCH=arm64; SB_SHA="${SB_SHA256_ARM64}"; XR_SHA="${XR_SHA256_ARM64}"; CF_SHA="${CF_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}-glibc.tar.gz"; \
    curl -fsSL -o xr.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XR_ARCH}.zip"; \
    curl -fsSL -o cloudflared "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-${CF_ARCH}"; \
    echo "${SB_SHA}  sb.tgz" | sha256sum -c -; \
    echo "${XR_SHA}  xr.zip" | sha256sum -c -; \
    echo "${CF_SHA}  cloudflared" | sha256sum -c -; \
    mkdir -p /out; \
    tar -xzf sb.tgz --strip-components=1 -C /out --wildcards '*/sing-box'; \
    unzip -q -o xr.zip xray geoip.dat geosite.dat -d /out; \
    install -m 0755 cloudflared /out/cloudflared; \
    chmod 0755 /out/sing-box /out/xray; \
    /out/sing-box version | head -n1; /out/xray version | head -n1; /out/cloudflared --version

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
 && mkdir -p /data && chown 10001:10001 /data && chmod 700 /data
COPY --from=fetch /out/ /opt/bin/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV XRAY_LOCATION_ASSET=/opt/bin
# Some PaaS wrappers run tini as a non-PID-1 process; registering as subreaper keeps zombie reaping working there.
ENV TINI_SUBREAPER=1
USER 10001:10001
VOLUME ["/data"]
EXPOSE 443/tcp 443/udp
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
