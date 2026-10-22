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

## Web UI routes (starlight_bot)

| Route | Description |
|-------|-------------|
| `/` or `/hooks` | Hook editor — create, edit, test hooks; region/click-region selection |
| `/screenshots` | Screenshot stream — live xcap feed, 40-frame timeline, hook overlay |
| `/transitions` | Navigation — screen localizing, BFS path execution, stream controls |

## Root-level convenience aliases

| Command | Description |
|---------|-------------|
| `mix db.setup` | Set up starlight_bot database |
| `mix db.reset` | Drop + recreate starlight_bot database |
| `mix phx.server` | Start starlight_bot web server |
| `mix assets.build` | Build starlight_bot CSS/JS assets |

## System dependencies

- KDE Plasma 6.0+ with KWin — required for input injection via EIS (`LIBEI_SOCKET` set automatically in a KDE session)
- XDG Remote Desktop portal — used by the EIS client when `LIBEI_SOCKET` is not set directly
