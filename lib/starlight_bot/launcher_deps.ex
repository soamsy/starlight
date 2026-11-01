defmodule StarlightBot.LauncherDeps do
  @launchers [
    {"direct", "Open native window"},
    {"gamescope_window", "Gamescope window"},
    {"gamescope", "Headless gamescope"},
    {"kwin", "Nested KWin"}
  ]

  def launchers, do: @launchers

  def description("direct"), do: "Starts Limbus the usual way, in a normal window on your desktop. Starlight captures that window and drives it with your real mouse and keyboard, so it can't be used while you do other things."
  def description("kwin"), do: "Runs a private KWin session at 1920x1080 and starts Limbus inside it, shown as a window on your desktop. The game never sees your window frame or display scaling, and your mouse stays free. Works from any desktop that has KWin installed."
  def description("gamescope_window"), do: "Runs gamescope at 1920x1080 inside a window on your desktop and starts Limbus inside it. Like Nested KWin, input goes into the game directly and doesn't use your mouse."
  def description("gamescope"), do: "Runs gamescope with no window at all. Limbus renders at 1920x1080 invisibly and only Starlight sees it. Good for unattended runs, but you can't watch the game."
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
