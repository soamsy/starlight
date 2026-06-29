# Starlight

An Elixir project for Limbus Company automation. `starlight_bot` is the root project (vision + navigation + automation).

## Environment

This project requires a split OTP environment (OTP 29 system + OTP 28 from Nix). Source `.envrc` before doing anything:

```sh
source .envrc
```

Without `.envrc`, `mix` will fail with cryptic BEAM errors.

## Getting started (starlight_bot)

```sh
source .envrc
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

- Rust toolchain — for the starlight_bot Rustler NIF (compiles automatically on first `mix compile`)
- KDE Plasma 6.0+ with KWin — required for input injection via EIS (`LIBEI_SOCKET` set automatically in a KDE session)
- XDG Remote Desktop portal — used by the EIS client when `LIBEI_SOCKET` is not set directly
