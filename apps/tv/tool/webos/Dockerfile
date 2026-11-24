# Ubuntu build environment for LG's flutter-webos SDK, which supports only
# Ubuntu hosts. Use it from macOS or Windows; see apps/tv/README.md.
FROM ubuntu:24.04

ARG FLUTTER_WEBOS_REF=main
ARG WEBOS_NDK_URL=https://github.com/lg-flutter-webos/ndk/releases/download/11.2.0/webos-ndk-flutter-starfish-x86_64-ca9v1-11.2.0.sh

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget unzip xz-utils cmake pkg-config file python3 \
      libgtk-3-0 libgtk-3-dev git git-lfs ninja-build clang make openssh-client \
    && rm -rf /var/lib/apt/lists/*

# The current webOS CLI (ares), used for packaging, needs Node.js 20 or later.
ARG NODE_VERSION=20.19.0
RUN curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
      | tar -xJ -C /opt && ln -s /opt/node-v${NODE_VERSION}-linux-x64/bin/* /usr/local/bin/ \
    && npm install -g @webos-tools/cli \
    && ln -sf /opt/node-v${NODE_VERSION}-linux-x64/bin/ares* /usr/local/bin/

RUN git clone https://github.com/lg-flutter-webos/flutter-webos.git /opt/flutter-webos \
    && git -C /opt/flutter-webos checkout "$FLUTTER_WEBOS_REF"
ENV PATH="/opt/flutter-webos/bin:${PATH}"

RUN wget -q -O /tmp/ndk.sh "$WEBOS_NDK_URL" && sh /tmp/ndk.sh -y && rm /tmp/ndk.sh
ENV WEBOS_FLUTTER_NDK_ENV=/usr/local/starfish-sdk-x86_64/environment-setup-ca9v1-webosmllib32-linux-gnueabi

RUN git config --global --add safe.directory '*' \
    && flutter-webos config --no-analytics \
    && flutter-webos precache

WORKDIR /work
