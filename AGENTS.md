# AGENTS.md

Guidelines for AI agents (Claude, Codex, etc.) working in this repository.

---

## Commenting Strategy

- **Never add comments to new or changed code.** No exceptions, no judgment call, not even for a non-obvious workaround or constraint. Explain those in chat or the PR description instead. Prefer a clearer name or a restructured line over a comment.
- **Existing comments are untouched**: don't add to them, don't remove them, don't "clean up" a comment on a line you're editing for an unrelated reason. This rule only governs comments the agent itself introduces.
- **Self-check before finishing**: scan the diff for any comment line that wasn't there before. Delete it if found, even if it felt justified when written.
- **Only exception**: the user explicitly asks for a comment or docstring in that turn. Write only what was asked, nothing extra.

## Retry Strategy

- **Fail fast**: If an edit fails 2+ times, re-read the file to understand current state before retrying
- **Change approach**: After repeated failures, try a different strategy rather than the same failing method
- **Validate assumptions**: When something doesn't work, check if underlying assumptions about file content or structure are still valid
- **Ask for clarification**: When stuck, ask a specific question rather than repeatedly attempting the same failed approach

---

## Environment Setup

This project requires a split OTP environment (OTP 29 system + OTP 28 from Nix). Source `.envrc` before doing anything:

```sh
source .envrc      # sets ERL_LIBS, ERL_FLAGS, PATH
```

Without `.envrc`, `mix` will fail with cryptic BEAM errors.

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
- **xcap 0.9.6**: X11 window capture and geometry; all metadata methods return `XCapResult<T>` (fallible API — use `.ok()` or `.map_err()`)
- **ashpd 0.13**: XDG portal access; kept for `remote_desktop` feature (internally imports from `screencast`, so both features must be listed even if screencast portal isn't used directly)
- **image 0.25**: resizing and PNG/JPEG encoding (no system libs)
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
system (see "What's Not Implemented Yet" below), scan existing hook notes for
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

---

## Key Constraints

- **No `kdotool` or external CLI tools for window geometry.** Window position/size comes from `xcap::Window::all()` in `native/starlight_native/src/capture/xcap_capture.rs`. xcap 0.9.6 uses XWayland-compatible X11; all `Window` methods are fallible (`XCapResult<T>`) — use `.ok()` / `.map_err()`, never `.unwrap()`.
- **No `uinput`.** Input injection uses libei/EIS via `reis 0.7`. KWin sets `LIBEI_SOCKET` automatically for child processes in a KDE session.
- **Rust warnings are not acceptable.** Unused imports, dead code, and shadowed bindings must be fixed, not suppressed.
- **Ecto migration syntax:** `add :col, references(:table, ...)` — `references()` is the type, not an option. Passing `add :col, :integer, references(...)` is wrong and will crash `mix db.setup`.
- **Don't remove the focus-loss check in `Navigation.Runner.run_steps/3`** (`Capture.focused?/0` before every step). It's the alt-tab safety net — without it, a script keeps injecting clicks/keys into whatever window the user switched to.
- **Don't spin up headless Chromium/CDP to click through Phoenix LiveView pages as a verification step.** It's unnecessary — confirm changes by compiling (`mix compile --warnings-as-errors`), running any relevant `mix test`, and/or exercising the logic directly via `mix run -e '...'` against the actual modules. If a change genuinely needs visual/browser confirmation, ask the user to check it themselves rather than automating a browser session.

---

## Architecture Overview

```
(root = starlight_bot)
master.db                # single SQLite db, all app data (committed)

lib/starlight_bot/
  application.ex        # OTP supervisor tree
  vision/               # frame capture, OCR prep, hook matching
    capture.ex          # Capture.grab_frame/0 (single-shot) + cache start/stop
    frame.ex            # %Frame{} struct
    hook.ex             # %Hook{} struct, gray_mat precomputed at load
    hook_registry.ex    # GenServer: loaded hooks keyed by atom name
    matcher.ex          # Evision matchTemplate (TM_CCOEFF_NORMED / TM_CCORR_NORMED)
  input/                # mouse, keyboard via EIS NIF
  automation/           # game logic, state machines (in progress)
  repo.ex               # Ecto SQLite3 repo (master.db)

native/starlight_native/
  src/
    cache/
      mod.rs            # start/stop/grab API; OnceLock FRAME+STOP, Mutex THREAD
      xcap_poll.rs      # ~30fps polling loop; caches Window handle across frames
    capture/
      xcap_capture.rs   # single-shot grab + window geometry (xcap 0.9.6 fallible API)
    input/eis.rs        # libei EIS input injection (Linux only)
    movement/           # bezier mouse trajectory
    scale.rs            # rgba_to_bgr, resize_rgba (NORM_W=1920, NORM_H=1080)
    error.rs            # NativeError enum

priv/repo/
  migrations/           # 9 schema migrations for master.db

config/
  config.exs            # base config
  dev.exs               # dev overrides
  test.exs              # test pool = Sandbox, DB = /tmp/starlight_test.db

lib/starlight_bot_web/
  live/
    hook_editor_live.ex           # /hooks — create/edit/test hooks; ?from_cache=1 loads handoff image
    screenshot_viewer_live.ex     # /screenshots — live xcap stream, 40-frame timeline, hook overlay
    screenshot_viewer_live.html.heex
    hook_editor_live.html.heex
  router.ex             # / and /hooks → HookEditorLive; /screenshots → ScreenshotViewerLive
```

### Screenshot cache pipeline

`Capture.start_cache/0` → `Native.cache_start/1` (DirtyIo NIF, joins old thread ~33ms) → `xcap_poll` thread polls `Window::all()` lazily (only on handle failure), writes `CachedFrame{bgr, width, height}` into `OnceLock<Arc<RwLock<Option<CachedFrame>>>>`.

`Native.cache_stop/0` sets the stop flag and immediately clears the FRAME store so subsequent `cache_grab_frame` calls return `{:error, :not_ready}` rather than a stale frame.

### Hook handoff

Screenshot viewer writes the selected frame as `/tmp/_starlight_hook_handoff.jpg`, then navigates to `/hooks?from_cache=1`. Hook editor's `handle_params/3` detects the query param and loads the file via `Evision.imread`, skipping the normal "take screenshot" flow.

### Template image quality

The entire pipeline is lossless: xcap → 1920×1080 BGR `Vec<u8>` → PNG on disk → `Evision.Mat` → PNG blob in DB. `gray_mat` is precomputed at hook load time in `Hook.from_db_row/1`. Template matching uses `TM_CCOEFF_NORMED` for `:gray`/`:rgb` modes and `TM_CCORR_NORMED` for `:binary_thresh`.

---

## Before Opening a PR

1. `source .envrc && mix compile --warnings-as-errors` — zero warnings
2. `mix test` — all tests pass (including migration count test, which covers all migrations applying cleanly)
3. `cargo clippy --manifest-path native/starlight_native/Cargo.toml` — no warnings
