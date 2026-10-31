# Linux support: next steps

State: COSMIC (portal), GNOME (portal, nested KWin, gamescope) and KDE work. A full MD run works on GNOME with gamescope without taking over the real mouse.

## Test next

1. **Gamescope window launcher with real Limbus.** Only the headless backend has run the bot. Check that the window opens, capture is not black, clicks land, and the window stays focused.
2. **Open native window launcher.** Steam mode and exe mode, on GNOME and COSMIC. Check the already-running guard and the "Needs" line.
3. **Launcher dropdown in the browser.** Pick each option, reload, confirm it persists. Confirm the bottom-left "Open Limbus" panel shows the missing programs, disables the button, and the "Launcher settings" link opens the scheduler tab.
4. **Restart Starlight while a gamescope Limbus is running.** Input should reconnect to gamescope, not fall back to the portal.
5. **Scheduler auto launch** with each launcher, including when a dependency is missing.
6. **Click origin comparison.** Run the Linux Checks click test on the portal path, nested KWin and gamescope, and compare the "saw the click from" lines against a real mouse click in the test window.
7. **Long runs.** Several MD runs back to back under gamescope, checking frame rate, capture with `ENABLE_GAMESCOPE_WSI=0`, and the game window resize button.
8. **Two Limbus copies or two gamescopes.** The socket scan picks the newest live one, so check that this is the right one.

## Build next

- Visible mode for headless gamescope, or a way to peek at the headless output.
- Check the Debian and Fedora package hints in the Linux Checks page.
- Other compositors with libei: Hyprland, Sway, niri. Portal support varies, so test each.
- Decide the default launcher per desktop (KWin on KDE, gamescope or native elsewhere).

## Known gaps

- Cursor readback only works on KDE and in nested X sessions, so "Read cursor position" is expected to fail elsewhere.
- Dependency lists for KWin and gamescope come from what the launch scripts call, not from a full audit.
