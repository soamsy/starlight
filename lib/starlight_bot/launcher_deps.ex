defmodule StarlightBot.LauncherDeps do
  @launchers [
    {"direct", "Open native window"},
    {"gamescope_window", "Gamescope window"},
    {"gamescope", "Headless gamescope"}
  ]

  def launchers, do: @launchers

  def description("direct"), do: "Opens Limbus in a normal desktop window and drives it with your desktop's mouse and keyboard. Alt-tab to pause the bot."
  def description("gamescope_window"), do: "Runs Limbus in gamescope, shown as a window you can freely resize, and Limbus will still render 1920x1080 resolution for the bot to see. Your mouse is free (bot doesn't need it), but hovering your mouse over the window can compete with the bot. Limbus will think its window is focused under gamescope (this is good)."
  def description("gamescope"), do: "Runs Limbus in gamescope with no window, so your mouse and keyboard can never interfere. Best for unattended runs, but you can't watch or click in the game. Audio still plays. Limbus will think its window is focused under gamescope (this is good)."
  def description(_launcher), do: ""

  def label(launcher), do: Enum.find_value(@launchers, "Gamescope window", fn {id, label} -> id == launcher && label end)

  def requirements(launcher, launch_mode) do
    for exe <- executables(launcher, launch_mode), do: %{name: exe, found?: System.find_executable(exe) != nil}
  end

  def missing(launcher, launch_mode) do
    for %{name: name, found?: false} <- requirements(launcher, launch_mode), do: name
  end

  defp executables("direct", "steam"), do: ["steam"]
  defp executables("direct", _mode), do: []
  defp executables(_gamescope, _mode), do: ["gamescope"]
end
