defmodule Mix.Tasks.StarlightBot.Check do
  @shortdoc "Verify that all Phase 1 dependencies and environment are ready"
  @moduledoc """
  Checks that everything needed to run StarlightBot Phase 1 is in place.

  Run this before starting the bot for the first time, or after any system change.

      mix starlight.check
  """

  use Mix.Task

  @green "\e[32m✓\e[0m"
  @red "\e[31m✗\e[0m"
  @yellow "\e[33m~\e[0m"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    IO.puts("\nStarlight Phase 1 Environment Check\n" <> String.duplicate("─", 40))
    results = [
      # check_elixir(),
      check_rust(),
      check_nif_compiled(),
      check_kwin_eis(),
      check_game_window(),
      check_user_db(),
      check_x11(),
    ]

    IO.puts("")
    failures = Enum.count(results, &(&1 == :fail))
    warnings = Enum.count(results, &(&1 == :warn))

    cond do
      failures > 0 -> IO.puts("#{@red} #{failures} check(s) failed. Fix these before running the bot.")
      warnings > 0 -> IO.puts("#{@yellow} #{warnings} warning(s). Bot may work with reduced capability.")
      true -> IO.puts("#{@green} All checks passed. Ready to run.")
    end
    version = System.version()
    otp = :erlang.system_info(:otp_release) |> to_string()
    ok("Elixir #{version} / OTP #{otp}")
  end

  defp check_rust do
    case System.cmd("rustc", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> ok("Rust: #{String.trim(output)}")
      _ -> fail("Rust (rustc) not found — install Rust via rustup.rs")
    end
  end

  defp check_nif_compiled do
    nif_path = Path.join([:code.priv_dir(:starlight_bot), "native"])
    so_files = Path.wildcard(Path.join(nif_path, "*.so"))

    if length(so_files) > 0 do
      ok("NIF compiled: #{Path.basename(List.first(so_files))}")
    else
      warn("NIF not yet compiled — run `mix compile` to build the Rust NIF")
    end
  end

  defp check_kwin_eis do
    # Check if KWin EIS D-Bus interface is available
    # Use qdbus or dbus-send to probe the interface
    dbus_cmd = System.find_executable("qdbus-qt6") ||
               System.find_executable("qdbus") ||
               System.find_executable("dbus-send")

    if is_nil(dbus_cmd) do
      warn("No D-Bus query tool found (qdbus-qt6/qdbus/dbus-send) — can't verify KWin EIS")
    else
      cmd = if String.contains?(dbus_cmd, "dbus-send") do
        {dbus_cmd, ["--session", "--print-reply", "--dest=org.kde.KWin",
                    "/org/kde/KWin", "org.freedesktop.DBus.Introspectable.Introspect"]}
      else
        {dbus_cmd, ["org.kde.KWin", "/org/kde/KWin"]}
      end

      case System.cmd(elem(cmd, 0), elem(cmd, 1), stderr_to_stdout: true) do
        {output, 0} when output != "" -> ok("KWin D-Bus service: org.kde.KWin")
        _ -> warn("KWin D-Bus service not found — are you running KDE Plasma?")
      end
    end
  end

  defp check_game_window do
    # Try to find the game window via the Capture GenServer
    case Process.whereis(StarlightBot.Vision.Capture) do
      nil ->
        warn("Vision.Capture not running (app not fully started)")
      _pid ->
        case StarlightBot.Vision.Capture.window_rect() do
          nil ->
            warn("Game window not found — start Limbus Company")
          {wx, wy, w, h} ->
            ok("Game window: #{w}x#{h} at (#{wx}, #{wy})")
        end
    end
  end

  defp check_user_db do
    db_path = Application.get_env(:starlight_bot, StarlightBot.Repo)[:database]

    case File.stat(db_path) do
      {:ok, %{type: :regular}} -> ok("user.db: #{db_path}")
      _ ->
        dir = Path.dirname(db_path)
        if File.exists?(dir) do
          warn("user.db not found — run `mix db.setup` to create it")
        else
          fail("user.db directory missing: #{dir} — run `mix db.setup`")
        end
    end
  end

  defp check_x11 do
    display = System.get_env("DISPLAY")

    if is_nil(display) do
      warn("$DISPLAY not set — xcap capture may fail on pure Wayland (expected for XWayland games)")
    else
      ok("$DISPLAY=#{display} (X11/XWayland accessible)")
    end
  end

  defp ok(msg) do
    IO.puts("  #{@green} #{msg}")
    :ok
  end

  defp warn(msg) do
    IO.puts("  #{@yellow} #{msg}")
    :warn
  end

  defp fail(msg) do
    IO.puts("  #{@red} #{msg}")
    :fail
  end
end
