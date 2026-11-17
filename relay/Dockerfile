# syntax=docker/dockerfile:1
#
# The Saucer Showdown relay server: lets players behind home routers play
# online without port forwarding, for Saucer Showdown or any other game (see
# README.md). It listens on UDP 24680, and serves its metrics for Prometheus
# over HTTP on TCP 24681. Publish only the UDP port to the internet; scrape
# the metrics from inside your own network.
#
#   docker build -t saucer-showdown-relay relay
#   docker run -p 24680:24680/udp saucer-showdown-relay
#
# It runs the relay's GDScript (this folder) on a headless Godot. The build
# context is this folder alone, and CI (relay-image.yml) rebuilds the image
# only when something in it changes.

ARG GODOT_VERSION=4.7.2
ARG TINI_VERSION=0.19.0

# Fetch Godot on the build machine's own platform (no emulation needed), for
# the target's architecture. The checksums are pinned from Godot's
# SHA512-SUMS.txt for this version; update them together with GODOT_VERSION.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS godot
ARG GODOT_VERSION
ARG TINI_VERSION
ARG TARGETARCH
ARG SHA512_X86_64=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
ARG SHA512_ARM64=dd59918da086bd49bde2f5450b5e567ff8650cbde9abbd7b8f4ca1197ff8c609baa38834666d032deafb47099078d7822279e2a0e06e5665745468f26533e7e2
# tini, so the relay stops promptly on SIGTERM (PID 1 ignores signals it has
# no handler for, and Godot has none).
ARG TINI_SHA256_AMD64=c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee
ARG TINI_SHA256_ARM64=eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl unzip \
	&& rm -rf /var/lib/apt/lists/*
RUN set -eu; \
	case "$TARGETARCH" in \
		amd64) arch=x86_64; sum="$SHA512_X86_64" ;; \
		arm64) arch=arm64; sum="$SHA512_ARM64" ;; \
		*) echo "no Godot build for $TARGETARCH" >&2; exit 1 ;; \
	esac; \
	curl -fsSLo /tmp/godot.zip \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.${arch}.zip"; \
	echo "${sum}  /tmp/godot.zip" | sha512sum -c -; \
	unzip -q -j /tmp/godot.zip -d /tmp/godot; \
	mv /tmp/godot/Godot_v* /godot; \
	chmod 0755 /godot; \
	case "$TARGETARCH" in amd64) tsum="$TINI_SHA256_AMD64" ;; arm64) tsum="$TINI_SHA256_ARM64" ;; esac; \
	curl -fsSLo /tini "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-${TARGETARCH}"; \
	echo "${tsum}  /tini" | sha256sum -c -; \
	chmod 0755 /tini

FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="Saucer Showdown relay" \
	org.opencontainers.image.description="Room-code relay for online games, Saucer Showdown's and any other (UDP 24680)" \
	org.opencontainers.image.source="https://github.com/drewburr-labs/saucer-showdown"
COPY --from=godot /godot /usr/local/bin/godot
COPY --from=godot /tini /usr/local/bin/tini
WORKDIR /relay
# Godot only needs a project file to treat /relay as a project. (relay/ has
# none of its own: Godot would then skip the folder in the game's project,
# and the game needs relay_protocol.gd from it.)
COPY <<EOF project.godot
config_version=5
EOF
COPY relay_protocol.gd relay_server.gd relay_metrics.gd relay_metrics_http.gd run_relay.gd ./
# Godot keeps its user data under HOME; give it somewhere writable. (It also
# logs a harmless "libfontconfig.so.1" line at startup: there are no fonts
# to load on a headless server.)
ENV HOME=/tmp
USER 65532:65532
EXPOSE 24680/udp 24681/tcp
ENTRYPOINT ["tini", "--", "godot", "--headless", "--path", "/relay", "--script", "res://run_relay.gd", "--"]
CMD ["--port=24680", "--metrics-port=24681"]
