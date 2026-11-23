#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t starlight-appimage -f packaging/Dockerfile .

mkdir -p dist
docker run --rm \
  -v "$PWD":/src:ro \
  -v "$PWD/dist":/dist \
  -v starlight-build:/build \
  -v starlight-cargo:/root/.cargo/registry \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  starlight-appimage bash -c '
    set -euo pipefail
    rsync -a --delete \
      --exclude=.git --exclude=_build --exclude=deps/ --exclude=target/ --exclude=node_modules \
      --exclude=dist --exclude=.starlight-dev --exclude="*.dump" \
      /src/ /build/
    cd /build
    mix local.hex --force && mix local.rebar --force
    mix deps.get
    gpu=/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitGPUProcess
    cd src-tauri && cargo tauri build --config "{\"bundle\":{\"linux\":{\"appimage\":{\"files\":{\"$gpu\":\"$gpu\"}}}}}"
    cp target/release/bundle/appimage/*.AppImage /dist/
    chown "$HOST_UID:$HOST_GID" /dist/*.AppImage
  '
