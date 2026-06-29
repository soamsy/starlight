# Starlight — Project Plan

Starlight is an Elixir/OTP desktop automation bot for Limbus Company's Mirror Dungeon (and Luxcavation dailies). It is the spiritual successor to Charge-Grinder, rebuilt from scratch with a proper state machine, database-backed hook system, and a LiveView debug UI.

## Quick Index

Start here (current, kept in sync with the code):

| Doc | Contents |
|-----|----------|
| [ONBOARDING.md](docs/ONBOARDING.md) | Entry point for a new engineer or agent — what exists, where to look, current gotchas |
| [CURRENT_ARCHITECTURE.md](docs/CURRENT_ARCHITECTURE.md) | Tech stack, module layout, OTP process tree, data flow |
| [STATUS.md](docs/STATUS.md) | What's implemented vs. not, per subsystem, updated per-PR |
| [TRANSITIONS.md](docs/TRANSITIONS.md) | Screen/transition DSL deep dive: subscreens, steps, BFS planning |

Original pre-rewrite design notes — written before implementation started, so
they describe intent and are not all built yet; cross-check against
`docs/STATUS.md` before relying on one of these:

| Doc | Contents |
|-----|----------|
| [vision.md](docs/old_docs/vision.md) | Screen capture, OpenCV matching, hook system |
| [input.md](docs/old_docs/input.md) | Mouse/keyboard injection, movement profiles, anti-detection |
| [screens.md](docs/old_docs/screens.md) | Screen state machine, screen modules, transition graph |
| [dungeon.md](docs/old_docs/dungeon.md) | Map navigation, DAG detection, pathfinding |
| [battle.md](docs/old_docs/battle.md) | Battle loop, skill chaining, sin color detection |
| [shop.md](docs/old_docs/shop.md) | Shop planner, inventory tracking, fusion optimizer |
| [packs.md](docs/old_docs/packs.md) | Pack selection, priority classes, AKAZE during animation (SIFT fallback) |
| [database.md](docs/old_docs/database.md) | Schema, migrations, dual-DB (master + user) |
| [ui.md](docs/old_docs/ui.md) | LiveView dashboard, hook editor, run log viewer |
| [scheduler.md](docs/old_docs/scheduler.md) | Team rotation, enkephalin, daily scheduling |
| [recovery.md](docs/old_docs/recovery.md) | Error recovery, backoff policy, anti-detection context |
| [phases.md](docs/old_docs/phases.md) | Development phases and priorities |

## Core Philosophy

Charge-Grinder is a good bot that grew organically into a Python script with 40 global mutable variables and no visibility into what it's doing at runtime. Starlight fixes the structural problems:

- **No shared mutable state.** OTP GenServers own their state. No god-object params module.
- **Explicit state machine.** Each game screen is a module. Transitions are declared, not inferred from polling.
- **Database-backed hooks.** Image templates live in SQLite with metadata. New hooks added at runtime via UI without restarting.
- **Live debug UI.** Phoenix LiveView streams annotated screenshots and decision logs while the bot is running.
- **Structured recovery.** Errors escalate through a policy, not a retry counter.

## What We Are Stealing from Charge-Grinder

- The relative mouse motion injection concept from Charge-Grinder's evdev approach (but via libei/EIS through KWin D-Bus instead of uinput — no udev rules, no group membership, events bypass the kernel device layer entirely)
- The dungeon graph cost table and DFS path ranking
- The HSV centroid skill sin color detection
- The SIFT/AKAZE matching approach for pack selection (specifically valuable during card swing animation; we use AKAZE as primary, SIFT as fallback)
- The binary threshold template matching for map connection arrows
- The general shape of the shop state (balance, tier inventory, uptie queue)

## Target Platform

**Primary**: Linux, KDE Plasma, Wayland  
**Secondary**: Linux, X11  
**Tertiary**: Windows (Rust NIF wrapping ghub DLL for input; standard Win32 for capture)

## Key Technical Decisions (Summary)

| Decision | Choice | Reason |
|----------|--------|--------|
| Runtime | Elixir/OTP | Supervision, hot reload, LiveView |
| UI | Phoenix LiveView (local browser, no Elixir Desktop) | Simpler than Elixir Desktop; same capability for a dev tool |
| CV | evision (OpenCV bindings) latest stable | Full OpenCV 5 access via NIF |
| Capture (KDE Wayland) | ashpd + PipeWire ScreenCast | Standard portal path; window-specific capture; one-time permission |
| Capture (X11) | xcap or mss-equivalent in Rust NIF | Secondary path |
| Input (Linux) | libei/reis via KWin EIS D-Bus (Rust NIF) | Session-level Wayland injection; reaches XWayland games; no udev rules, no groups; EIS in KWin since Plasma 6.0 |
| Input (Windows) | Rust NIF loading ghub DLL | Presents as Logitech USB HID; Win32 INJECTED flag doesn't apply |
| Mouse movement | Math bezier + gaussian noise | No model file required; two profiles: `:human` and `:fast` |
| Database | SQLite via Ecto, two files | master.db (committed) + user.db (gitignored) |
| Frame normalization | Always scale to 1920×1080 | All hook coords in one space; click coords scaled back at emit time |
