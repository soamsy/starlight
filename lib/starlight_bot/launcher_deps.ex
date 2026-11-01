defmodule StarlightBot.LauncherDeps do
  @launchers [
    {"direct", "Open native window"},
    {"kwin", "Nested KWin"},
    {"gamescope_window", "Gamescope window"},
    {"gamescope", "Headless gamescope"}
  ]

  def launchers, do: @launchers

  def description("direct"), do: "Starts Limbus the usual way, in a normal window on your desktop. Starlight captures that window and drives it with your real mouse and keyboard, so it can't be used while you do other things."
  def description("kwin"), do: "Runs a private KWin session at 1920x1080 and starts Limbus inside it, shown as a window on your desktop. The game never sees your window frame or display scaling, and your mouse stays free. Works from any desktop that has KWin installed."
  def description("gamescope_window"), do: "Gamescope is Valve's micro-compositor: it runs a game on its own private display at a fixed resolution, independent of your desktop. This mode shows that display as a 1920x1080 window on your desktop and starts Limbus inside it. Starlight sends input straight to the game, so it doesn't use your mouse. Gamescope is told not to grab your mouse or keyboard, so you can still click around your desktop, but moving your own mouse over the window competes with the bot."
  def description("gamescope"), do: "Gamescope is Valve's micro-compositor: it runs a game on its own private display at a fixed resolution, independent of your desktop. This mode runs it with no window at all. Limbus renders at 1920x1080 invisibly and only Starlight sees it, so your mouse and keyboard can never interfere. Good for unattended runs, but you can't watch or click in the game."
  def description(_launcher), do: ""

  def label(launcher), do: Enum.find_value(@launchers, "Nested KWin", fn {id, label} -> id == launcher && label end)

  def requirements(launcher, launch_mode) do
    for exe <- executables(launcher, launch_mode), do: %{name: exe, found?: System.find_executable(exe) != nil}
  end

  def missing(launcher, launch_mode) do
    for %{name: name, found?: false} <- requirements(launcher, launch_mode), do: name
  end

  defp executables("direct", "steam"), do: ["steam"]
  defp executables("direct", _mode), do: []
  defp executables("kwin", _mode), do: ["kwin_wayland", "Xwayland", "dbus-daemon", "gdbus"]
  defp executables(_gamescope, _mode), do: ["gamescope"]
end
