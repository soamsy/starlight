defmodule Mix.Tasks.StarlightBot.Screenshot do
  @shortdoc "Take a screenshot of the game window and save to disk"
  @moduledoc """
  Captures a frame from the game window and saves it as a PNG file.
  Useful for verifying capture is working and for creating hook templates.

      mix starlight.screenshot
      mix starlight.screenshot /tmp/frame.png
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    path = List.first(args) || "/tmp/starlight_screenshot_#{:os.system_time(:second)}.png"

    IO.puts("Taking screenshot...")

    case StarlightBot.Vision.Capture.save_screenshot(path) do
      :ok ->
        IO.puts("Saved: #{path}")

      {:error, :no_window} ->
        Mix.raise("Game window not found. Start Limbus Company first.")

      {:error, :window_not_found} ->
        Mix.raise("Limbus Company window not found on any X display in /tmp/.X11-unix. Is the game running?")

      {:error, reason} ->
        Mix.raise("Screenshot failed: #{inspect(reason)}")
    end
  end
end
