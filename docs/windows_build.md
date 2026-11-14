# Building on Windows

Windows is a build target (Tauri bundles an NSIS installer via `src-tauri/tauri.windows.conf.json`). Screen capture and input injection are Linux-only for now; on Windows the NIF compiles the stubs in `native/starlight_native/src/capture/unsupported.rs`.

## Toolchain

| Tool | Version | Install |
|---|---|---|
| MSVC C++ Build Tools | 2022 or newer, "Desktop development with C++" workload | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"` |
| Rust (MSVC toolchain) | stable | `winget install Rustlang.Rustup` |
| Erlang/OTP | 29.x (`.tool-versions` pins 29.1.1) | `winget install Erlang.ErlangOTP --version 29.1.1`, or the installer from erlang.org |
| Elixir | 1.20.x on OTP 29 (`.tool-versions` pins 1.20.4) | `winget install Elixir.Elixir --version 1.20.4`, or `elixir-otp-29.zip` from the Elixir GitHub releases with `bin` on `PATH` |
| Tauri CLI | 2.x | `cargo install tauri-cli` |

The Erlang and Elixir winget installers don't touch `PATH`. Add `C:\Program Files\Erlang OTP\bin` and `C:\Program Files\Elixir\bin` to your user `PATH`, then open a new terminal so it picks everything up. The MSVC Build Tools need to come first: Rustler, and any dependency that falls back to compiling C, link with `link.exe`. If `mix compile` can't find the linker, run it from "Developer PowerShell for VS".

Optional: `winget install SQLite.SQLite` for the `sqlite3` CLI used by the hook-notes queries in `AGENTS.md`.

## What you don't need to install

- **WebView2**: ships with Windows 11 (Tauri's runtime).
- **NSIS**: Tauri downloads it on the first `nsis` bundle.
- **tailwind / esbuild**: mix downloads the binaries.
- **evision, exqlite**: pull precompiled Windows NIFs (fall back to an MSVC build).
- **reis, xcb, ashpd, zbus, wayland-\***: gated behind `cfg(target_os = "linux")` in `native/starlight_native/Cargo.toml`.

## Build

OTP 29 on Windows reports `:system_architecture` as `x86_64-pc-windows`. evision only maps the old `win32` value to its `x86_64-windows-msvc` precompiled target, so without help it falls back to building OpenCV from source (and fails on a missing `nmake`). Both evision and cc_precompiler (used by exqlite) accept a `TARGET_ARCH`/`TARGET_OS`/`TARGET_ABI` override, and `mix.exs` sets them to `x86_64`/`windows`/`msvc` on Windows unless you've set any of them yourself. Set all three or none: cc_precompiler joins them as-is, so a partial override yields a bogus target like `-windows-msvc`.

Then:

```powershell
git submodule update --init
mix local.hex --force; mix local.rebar --force
mix deps.get
mix compile
```

Desktop app (prod release + NSIS installer in `src-tauri/target/release/bundle/nsis/`):

```powershell
cd src-tauri
cargo tauri build
```

`tauri.windows.conf.json` overrides `beforeBuildCommand` with cmd syntax (`set MIX_ENV=prod&& mix ...`), since Tauri runs it through `cmd.exe` on Windows.
