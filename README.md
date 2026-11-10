# Starlight

An Elixir project for Limbus Company automation. `starlight_bot` is the root project (vision + navigation + automation).

## Build requirements

- **Erlang/OTP 29.1.1 and Elixir 1.20.4**, pinned in `.tool-versions`. Install them with [mise](https://mise.jdx.dev) or asdf (`mise install`), or use distro packages if the versions match. On Arch/CachyOS, Erlang is split into per-app packages; `erlang-ssl`, `erlang-public_key`, `erlang-asn1`, `erlang-inets` and `erlang-xmerl` are required alongside `erlang-core` (Hex and rebar3 need them).
- **Rust 1.91 or newer** (rustler 0.38's minimum) plus a C linker, for the NIF in `native/starlight_native/`.
- **libxcb**, linked by the NIF for X11 window discovery and capture.
- **Network access on first build.** `mix deps.get` pulls from Hex, `mix compile` downloads evision's precompiled OpenCV NIF, and the first `mix assets.build` downloads the tailwind and esbuild binaries.
- **The `vendor/EgoGiftML` submodule**, which holds the ego gift models and the data for `mix ego_gifts.setup`. Clone with `--recurse-submodules`, or run `git submodule update --init` in an existing checkout.

## Getting started (starlight_bot)

```sh
mix deps.get
mix compile        # compiles Rust NIF — slow on first run (~30–60s)
mix db.setup
mix phx.server     # starts at localhost:4000
```

## Desktop app (Tauri)

`src-tauri/` wraps the Phoenix app in a Tauri window using [ElixirKit](https://elixirkit.hexdocs.pm/tauri.html). Needs `cargo-tauri` (`cargo install tauri-cli`) and webkit2gtk-4.1.

```sh
cd src-tauri
cargo tauri dev                          # runs mix phx.server on :4000; code reload and asset watchers work as in the browser
env NO_STRIP=true cargo tauri build      # prod release + AppImage in src-tauri/target/release/bundle/appimage/
```

Packaged builds always run in user mode (`allow_authoring` is off outside dev and test), keep data in `~/.starlight` (including logs, risky-battle screenshots and a staged copy of `base.db`), and skip dev-only behavior: JS console log forwarding, `save_timeout_frames` and the file logger. The window uses port 47621 when free, otherwise a random one, and only one instance can run at a time.

## Web UI routes (starlight_bot)

| Route | Description |
|-------|-------------|
| `/` or `/hooks` | Hook editor — create, edit, test hooks; region/click-region selection |

## Root-level convenience aliases

| Command | Description |
|---------|-------------|
| `mix db.setup` | Create and migrate the base, user and runs databases |
| `mix db.migrate` | Run pending migrations on all three databases |
| `mix phx.server` | Start starlight_bot web server |
| `mix assets.build` | Build starlight_bot CSS/JS assets |

## Data layout

Starlight keeps three SQLite files instead of one:

| File | Holds | Who writes it |
|------|-------|---------------|
| `base.db` | Shipped data: hooks, E.G.O gifts, theme packs, plan templates, fusion route templates, sinner profiles | Maintainers only; read-only for users |
| `user.db` | The user's teams, plans, scheduler settings, runner forms, hook overrides, added sinner profiles | The user |
| `runs.db` | Run logs and run events | The app, local only |

`priv/data/base.db` and `priv/data/user_seed.db` are committed. On first start in user mode the seed is copied to `~/.starlight/user.db`; after that the user owns it and upgrades never touch it. `runs.db` is never committed.

Where data lives is set by `~/.config/starlight/config.toml` (`mode` and `data_dir`), editable from the gear in the app's sidebar:

- `mode = "authoring"` (the default under `mix phx.server` in dev) edits the committed databases in place; run history and user hook images go to `.starlight-dev/`.
- `mode = "user"` reads `base.db` read-only and keeps everything else under `data_dir` (default `~/.starlight`). `STARLIGHT_HOME=/some/dir` forces user mode against that directory, which is the easiest way to try the user experience from a checkout.

Hook overlays: a user can override a shipped hook by name. The override records the shipped hook's `version`; bumping `hooks.version` in `base.db` (the "Bump version" button in authoring mode) retires user overrides of that hook until they re-apply them.

Commit `base.db` and `user_seed.db` only after stopping the server (or running `PRAGMA wal_checkpoint(TRUNCATE)` on `user_seed.db`) so the files contain the latest edits.

## System dependencies

- KDE Plasma 6.0+ with KWin — required for input injection via EIS (`LIBEI_SOCKET` set automatically in a KDE session)
- XDG Remote Desktop portal — used by the EIS client when `LIBEI_SOCKET` is not set directly
