FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates git rsync pkg-config file xz-utils unzip \
    autoconf m4 libssl-dev libncurses5-dev libncursesw5-dev libsctp-dev \
    libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    libxcb1-dev libxcb-shm0-dev libxcb-composite0-dev libxkbcommon-dev libdbus-1-dev \
    libclang-dev cmake \
    && rm -rf /var/lib/apt/lists/*

ARG WEBKIT_VERSION=2.54.3
ARG WEBKIT_SHA256=2779c1b46f88762e8400650271ba14452dc4e30b37059981552d8b562b7d0862
ARG WEBKIT_JOBS=8

RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg lsb-release gettext ninja-build ruby gperf bison flex python3 perl unifdef \
    gcc-12 g++-12 libstdc++-12-dev bubblewrap xdg-dbus-proxy \
    libglib2.0-dev libsoup-3.0-dev libcairo2-dev libfreetype-dev libfontconfig-dev libharfbuzz-dev libicu-dev \
    libjpeg-dev libpng-dev libwebp-dev libopenjp2-7-dev liblcms2-dev libxml2-dev libxslt1-dev libsqlite3-dev \
    libgcrypt20-dev libtasn1-6-dev libsecret-1-dev libenchant-2-dev libhyphen-dev libwoff-dev libbrotli-dev \
    libseccomp-dev libsystemd-dev libmanette-0.2-dev libatspi2.0-dev libatk-bridge2.0-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev libepoxy-dev libgbm-dev libdrm-dev libegl1-mesa-dev libgles2-mesa-dev \
    libx11-dev libxt-dev libxcomposite-dev libxdamage-dev libxrender-dev libxtst-dev \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-18 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends clang-18 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir /tmp/wk && cd /tmp/wk; \
    curl -fsSL -o wk.tar.xz "https://webkitgtk.org/releases/webkitgtk-${WEBKIT_VERSION}.tar.xz"; \
    echo "${WEBKIT_SHA256}  wk.tar.xz" | sha256sum --check --strict; \
    tar xf wk.tar.xz; \
    cmake -S webkitgtk-${WEBKIT_VERSION} -B build -GNinja \
      -DPORT=GTK -DUSE_GTK4=OFF \
      -DCMAKE_C_COMPILER=clang-18 -DCMAKE_CXX_COMPILER=clang++-18 \
      -DCMAKE_C_FLAGS="--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/12" \
      -DCMAKE_CXX_FLAGS="--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/12 -stdlib=libstdc++" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DCMAKE_INSTALL_LIBEXECDIR=lib/x86_64-linux-gnu \
      -DUSE_LIBBACKTRACE=OFF -DUSE_AVIF=OFF -DUSE_JPEGXL=OFF -DUSE_SYSPROF_CAPTURE=OFF \
      -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_DOCUMENTATION=OFF -DENABLE_INTROSPECTION=OFF \
      -DENABLE_MINIBROWSER=OFF -DENABLE_BUBBLEWRAP_SANDBOX=ON; \
    cmake --build build --parallel "${WEBKIT_JOBS}"; \
    DESTDIR=/tmp/wk/stage cmake --install build; \
    cp -a /tmp/wk/stage/usr/. /usr/; \
    ldconfig; \
    glibc_max=$(objdump -T /usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0 | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1); \
    echo "libwebkit2gtk needs ${glibc_max}"; \
    test "$(printf '%s\n' "${glibc_max}" GLIBC_2.35 | sort -V | tail -1)" = GLIBC_2.35; \
    cd / && rm -rf /tmp/wk

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
