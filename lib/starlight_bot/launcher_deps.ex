defmodule StarlightBot.LauncherDeps do
  @launchers [
    {"direct", "Open native window"},
    {"gamescope_window", "Gamescope window"},
    {"gamescope", "Headless gamescope"}
  ]

  def launchers, do: @launchers

  def description("direct"), do: "Opens Limbus in a normal desktop window and drives it with your desktop's mouse and keyboard. Alt-tab to pause the bot."
  def description("gamescope_window"), do: "Runs Limbus in gamescope. It won't steal your mouse, and it doesn't need resizing since you're setting gamescope's internal resolution to 1920x1080. As far as Limbus is concerned it is 'focused' in its XWayland instance."
  def description("gamescope"), do: "Runs Limbus in gamescope headless, where the gamescope window isn't visible. Good for scheduled runs if you don't want the launch to be distracting."
  def description(_launcher), do: ""

  def label(launcher), do: Enum.find_value(@launchers, "Gamescope window", fn {id, label} -> id == launcher && label end)

  def requirements(launcher, launch_mode) do
    for exe <- executables(launcher, launch_mode), do: %{name: exe, found?: System.find_executable(exe) != nil}
  end

  def missing(launcher, launch_mode) do
    for %{name: name, found?: false} <- requirements(launcher, launch_mode), do: name
  end

  defp executables(_launcher, "none"), do: []
  defp executables("direct", "steam"), do: ["steam"]
  defp executables("direct", _mode), do: []
  defp executables(_gamescope, _mode), do: ["gamescope"]
end
