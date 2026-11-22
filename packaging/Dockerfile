FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates git rsync pkg-config file xz-utils unzip \
    autoconf m4 libssl-dev libncurses5-dev libncursesw5-dev libsctp-dev \
    libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    libxcb1-dev libxcb-shm0-dev libxcb-composite0-dev libxkbcommon-dev libdbus-1-dev \
    libclang-dev cmake \
    && rm -rf /var/lib/apt/lists/*

ENV MISE_DATA_DIR=/opt/mise
ENV PATH=/opt/mise/shims:/root/.cargo/bin:$PATH
RUN curl -fsSL https://mise.run | sh && /root/.local/bin/mise --version
COPY .tool-versions /tmp/tv/.tool-versions
RUN cd /tmp/tv && /root/.local/bin/mise install -y && /root/.local/bin/mise reshim

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && cargo install tauri-cli --locked

ENV APPIMAGE_EXTRACT_AND_RUN=1
ENV NO_STRIP=true
WORKDIR /build
