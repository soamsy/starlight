# AGENTS.md

Guidelines for AI agents (Claude, Codex, etc.) working in this repository.

---

## Commenting Strategy

- **Never add comments to new or changed code.** No exceptions, no judgment call, not even for a non-obvious workaround or constraint. Explain those in chat or the PR description instead. Prefer a clearer name or a restructured line over a comment.
- **Existing comments are untouched**: don't add to them, don't remove them, don't "clean up" a comment on a line you're editing for an unrelated reason. This rule only governs comments the agent itself introduces.
- **Self-check before finishing**: scan the diff for any comment line that wasn't there before. Delete it if found, even if it felt justified when written.
- **Only exception**: the user explicitly asks for a comment or docstring in that turn. Write only what was asked, nothing extra.

---

## Environment Setup

Erlang/OTP and Elixir versions are pinned in `.tool-versions` (install with `mise install` or asdf). Distro packages are fine if the versions match; on Arch/CachyOS make sure the split `erlang-ssl`, `erlang-public_key`, `erlang-asn1`, `erlang-inets` and `erlang-xmerl` packages are installed, not just `erlang-core`.

**Check your environment is correct:**

```sh
elixir --version   # must show 1.20.x / OTP 29
mix compile        # should succeed (Rust NIF will compile on first run — slow)
```

---

## Compilation

The Rust NIF in `native/starlight_native/` compiles automatically via Rustler when you run `mix compile`. The first compile takes ~30–60 seconds.

If the Rust code has errors, `mix compile` prints them in full. Fix them in `native/starlight_native/src/`. Key libraries:

- **reis 0.7**: libei EIS protocol for wayland input injection (Linux only)
- **xcb 1.7** (`shm`, `composite` features): direct X11 protocol for window discovery, geometry, focus, capture and pointer queries. One cached connection per display, so a single process can see both the host Xwayland and a nested one. Capture names the window's composite pixmap each frame and reads it with MIT-SHM into a memfd segment (`AttachFd`); the window itself can't be used because MIT-SHM rejects windows that extend past the screen edge, which KWin's title bar causes in the nested session. Frames are grabbed on demand for each check, so every frame postdates the check that asked for it; there is no background frame cache. Hook checks in `Navigation.Machine` grab only the search rects of the hooks involved (`Runner.grab_for/1` → `Native.grab_regions/2`, all rects pipelined in one SHM batch, ~1ms) and get a patch-only `Frame` (`Frame.region/2` reads it, raises if a rect isn't covered); partial frames never leave the machine: `:call` steps and run results get `nil` in their place, so scripts that need pixels call `Capture.grab_frame/0` for a full 1920×1080 frame. To learn which hook an `await_any` saw, use its result (`{:ok, hook}`) rather than re-checking a frame. Off-size windows are resampled per region with a padded capture and a fractional crop so region pixels match the full-frame resize
- **ashpd 0.13**: XDG portal access; kept for `remote_desktop` feature (internally imports from `screencast`, so both features must be listed even if screencast portal isn't used directly)
- **fast_image_resize 6**: SIMD Lanczos3 resize of captures to 1920×1080 when the game window isn't exactly that size (~10ms vs ~120ms with `image`)
- **image 0.25**: PNG/JPEG encoding (no system libs)
- **rustler 0.38**: NIFs collected via `#[rustler::nif]` attribute; `rustler::init!` takes only the module name

---

## Database

All app data (hooks, teams, run logs, ego gifts, etc.) lives in a single SQLite file, `master.db`, committed at the repo root. There is no separate user-local database — this keeps schema and seed data in version control during early dev.

```sh
mix db.setup       # create + migrate master.db
mix db.migrate     # run pending migrations
```

**Never run `mix db.reset`** (drop + recreate) against `master.db` — it destroys hooks/teams data with no undo. Migration files are in `priv/repo/migrations/`. All 9 migrations applying cleanly from scratch is already verified safely by `mix test` (`test_helper.exs` runs every migration against an isolated `/tmp/starlight_test.db`, not the live one) — that's the check to run, not `db.reset`.

Override the path with the `STARLIGHT_DB` env var if needed (see `config/runtime.exs`).

---

## Hook Notes as Screen Documentation

`hooks.notes` (edited inline in the `/hooks` table) is the closest thing this
repo has to living documentation of Limbus Company's UI — each hook's notes
were hand-written while building detection for that element, and typically
explain what a toggle/button means, what state it indicates, or automation
gotchas (e.g. "arrow diagrams interfere with OpenCV detection").

Before designing automation logic, a state machine, or the screen-detection
system, scan existing hook notes for
relevant context rather than guessing at screen semantics from names alone:

```sh
sqlite3 -readonly -header -column master.db \
  "SELECT name, notes FROM hooks WHERE notes IS NOT NULL AND TRIM(notes) != '' ORDER BY name;"
```

Scope to one screen/feature with a `LIKE` filter on the name prefix, e.g. all
`battle_*` hooks:

```sh
sqlite3 -readonly -header -column master.db \
  "SELECT name, notes FROM hooks WHERE name LIKE 'battle_%' AND notes IS NOT NULL AND TRIM(notes) != '' ORDER BY name;"
```

Always use `-readonly` — `master.db` is typically held open by a live `mix
phx.server` (WAL mode), and this is a read query, not a file copy.

---

## Testing

```sh
mix test
```

`test_helper.exs` runs all migrations against `/tmp/starlight_test.db` before the test suite starts. **If any migration file has a syntax error or bad SQL, the test suite fails at startup** with the migration error. This is intentional — it catches migration bugs early.

`test/starlight_bot/migrations_test.exs` verifies:
- All migration files are reflected in `schema_migrations` (count is dynamic — no hardcoded number)
- All expected tables exist in the test database

The test pool is `Ecto.Adapters.SQL.Sandbox` in `:manual` mode. Every test that touches the DB must call:
```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(StarlightBot.Repo)
end
```

`mix test` is fully hermetic — no live KDE session required. `Vision.Capture`,
`Input.Mouse`, `Input.Keyboard`, and `Navigation.Navigator` (the hardware-touching
children) are skipped in `:test` via `config :starlight_bot, start_hardware?: false`
(see `StarlightBot.Application.hardware_children/0`). Real KWin EIS connectivity
checks live in `test/starlight_bot/hardware_test.exs`, tagged `:kde` and excluded
by default — run them explicitly with `mix test.hardware` on a machine with a
live KDE Plasma session (may show a portal permission dialog on first run).

---

## Code Checks

```sh
mix starlight_bot.check   # verifies required runtime deps (LIBEI_SOCKET, etc.)
mix compile --warnings-as-errors   # zero-warning policy for Elixir
cargo clippy --manifest-path native/starlight_native/Cargo.toml   # Rust lints
```

A running `mix phx.server` (code reloader on) holds the `_build/dev` lock while it recompiles, so `mix compile` in dev can hang on "Waiting for lock". Don't stop the server. Use `MIX_ENV=test mix compile --warnings-as-errors` for the warning check instead; it builds in `_build/test` and never contends with the server.

---

## Key Constraints

- **No `kdotool` or external CLI tools for window geometry.** Window discovery/position/size comes from `x11::locate()` in `native/starlight_native/src/capture/x11.rs`, which scans every X display in `/tmp/.X11-unix` (host `$DISPLAY` first) over xcb. Never set `DISPLAY` per call: the process env is shared across threads. All xcb calls are fallible; map errors to `NativeError`, never `.unwrap()`.
- **Nested session input routing.** When the game is found on a display other than the host `$DISPLAY`, `eis.rs` connects to that nested KWin's `org.kde.KWin.EIS.RemoteDesktop.connectToEIS` over the bus at `$XDG_RUNTIME_DIR/starlight-nested/bus` (started by the `limbus-nested` Steam launch wrapper) and reconnects automatically when the game moves between displays. Host input still goes `LIBEI_SOCKET` → portal.
- **No `uinput`.** Input injection uses libei/EIS via `reis 0.7`. KWin sets `LIBEI_SOCKET` automatically for child processes in a KDE session.
- **Rust warnings are not acceptable.** Unused imports, dead code, and shadowed bindings must be fixed, not suppressed.
- **Ecto migration syntax:** `add :col, references(:table, ...)` — `references()` is the type, not an option. Passing `add :col, :integer, references(...)` is wrong and will crash `mix db.setup`.
- **Don't remove the focus-loss check in `Navigation.Machine.guarded/2`** (`Capture.focused?/0` before every step). It's the alt-tab safety net — without it, a script keeps injecting clicks/keys into whatever window the user switched to.
- **Don't spin up headless Chromium/CDP to click through Phoenix LiveView pages as a verification step.** It's unnecessary — confirm changes by compiling (`mix compile --warnings-as-errors`), running any relevant `mix test`, and/or exercising the logic directly via `mix run -e '...'` against the actual modules. If a change genuinely needs visual/browser confirmation, ask the user to check it themselves rather than automating a browser session.

---

## Before Opening a PR

1. `mix compile --warnings-as-errors` — zero warnings
2. `mix test` — all tests pass (including migration count test, which covers all migrations applying cleanly)
3. `cargo clippy --manifest-path native/starlight_native/Cargo.toml` — no warnings
