# Linux support: next steps

State: COSMIC, GNOME and Hyprland work, along with KDE. Every launcher (gamescope, native window), the scheduler auto launch and the Linux Checks page have been tested on GNOME, COSMIC and Hyprland. A full MD run works under gamescope without taking over the real mouse.

## Build next

- Visible mode for headless gamescope, or a way to peek at the headless output.
- Check the Debian and Fedora package hints in the Linux Checks page.
- Other compositors with libei: Sway, niri. Portal support varies, so test each.
- Decide the default launcher per desktop (gamescope or native).

## Known gaps

- Cursor readback only works on KDE and in nested X sessions, so "Read cursor position" is expected to fail elsewhere.
- Dependency lists for gamescope come from what the launch scripts call, not from a full audit.
