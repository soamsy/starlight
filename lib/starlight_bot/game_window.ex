defmodule StarlightBot.GameWindow do
  alias StarlightBot.{LogStore, Native, NestedKwin, SteamLaunch}
  alias StarlightBot.Vision.Capture

  @target_w 1920
  @target_h 1080
  @window_poll_ms 2_000
  @resize_settle_ms 1_500
  @resize_attempts 3
  @plugin_name "starlight-resize"

  def rect do
    case Native.get_window_rect(window_class()) do
      {:ok, x, y, w, h} -> {:ok, {x, y, w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  def aspect_ok?({_x, _y, w, h}), do: h > 0 and abs(w * 9 - h * 16) <= w * 9 * 0.005

  def launch(%{launch_mode: "steam", steam_app_id: app_id}) do
    LogStore.append(:info, "launch: opening Steam app #{app_id} in a nested KWin")

    with {:ok, %{argv: argv, env: env, cwd: cwd}} <- SteamLaunch.command(app_id),
         {:ok, kwin_pid} <- NestedKwin.ensure(),
         :ok <- NestedKwin.lock_frame(kwin_pid) do
      NestedKwin.spawn(argv, env, cwd)
    end
    |> log_failure()
  end

  def launch(%{launch_mode: "exe", exe_path: path}) do
    LogStore.append(:info, "launch: opening #{path} in a nested KWin")

    with {:ok, kwin_pid} <- NestedKwin.ensure(),
         :ok <- NestedKwin.lock_frame(kwin_pid) do
      NestedKwin.spawn([path])
    end
    |> log_failure()
  end

  def launch(%{launch_mode: "none"}), do: {:error, :launch_disabled}

  defp log_failure({:error, reason} = error) do
    LogStore.append(:error, "launch: failed: #{inspect(reason)}")
    error
  end

  defp log_failure(result), do: result

  def await_window(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_window(deadline)
  end

  defp poll_window(deadline) do
    case rect() do
      {:ok, rect} ->
        Capture.refresh_window_rect()
        {:ok, rect}

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :window_timeout}
        else
          Process.sleep(@window_poll_ms)
          poll_window(deadline)
        end
    end
  end

  def fix_aspect(steam_app_id) do
    lock = {:game_window_resize, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        with {:ok, before} <- rect() do
          fix_aspect(steam_app_id, before, @resize_attempts)
        end
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, :resize_in_progress}
    end
  end

  defp fix_aspect(steam_app_id, before, attempts_left) do
    with {:ok, buses} <- run_resize_script(steam_app_id) do
      Process.sleep(@resize_settle_ms)
      Capture.refresh_window_rect()

      case rect() do
        {:ok, {_, _, @target_w, @target_h} = after_rect} -> {:ok, %{before: before, after: after_rect, buses: buses}}
        {:ok, _after_rect} when attempts_left > 1 ->
          Native.forget_window()
          fix_aspect(steam_app_id, before, attempts_left - 1)
        {:ok, after_rect} ->
          Native.forget_window()
          {:error, {:resize_ignored, %{before: before, after: after_rect, buses: buses}}}
        error -> error
      end
    end
  end

  defp run_resize_script(steam_app_id) do
    path = Path.join(System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!(), "#{@plugin_name}.js")
    File.write!(path, resize_script(steam_app_id))

    results =
      Enum.map(buses(), fn {label, bus_args} ->
        {label, load_and_run(bus_args, path)}
      end)

    case Enum.filter(results, fn {_label, result} -> result == :ok end) do
      [] -> {:error, {:kwin_unreachable, results}}
      ran -> {:ok, Enum.map(ran, &elem(&1, 0))}
    end
  end

  defp buses do
    host = [{:host, ["--session"]}]

    case System.get_env("XDG_RUNTIME_DIR") do
      nil ->
        host

      runtime_dir ->
        nested = Path.join([runtime_dir, "starlight-nested", "bus"])
        if File.exists?(nested), do: host ++ [{:nested, ["--address", "unix:path=#{nested}"]}], else: host
    end
  end

  defp load_and_run(bus_args, path) do
    gdbus(bus_args, "/Scripting", "org.kde.kwin.Scripting.unloadScript", [@plugin_name])

    with {:ok, out} <- gdbus(bus_args, "/Scripting", "org.kde.kwin.Scripting.loadScript", [path, @plugin_name]),
         [_, id_str] <- Regex.run(~r/\((\d+),\)/, out),
         id = String.to_integer(id_str),
         {:ok, _} <- gdbus(bus_args, "/Scripting/Script#{id}", "org.kde.kwin.Script.run", []) do
      Process.sleep(300)
      gdbus(bus_args, "/Scripting", "org.kde.kwin.Scripting.unloadScript", [@plugin_name])
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, {:bad_script_id, other}}
    end
  end

  defp gdbus(bus_args, object_path, method, args) do
    argv = ["call"] ++ bus_args ++ ["--dest", "org.kde.KWin", "--object-path", object_path, "--method", method] ++ args

    case System.cmd("gdbus", argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp resize_script(steam_app_id) do
    """
    for (const w of workspace.stackingOrder) {
      const cls = (w.resourceClass || "").toLowerCase();
      if (w.caption !== #{Jason.encode!(window_title())} && cls !== #{Jason.encode!(String.downcase(window_class()))} && cls !== #{Jason.encode!("steam_app_#{steam_app_id}")}) continue;
      print("starlight-resize matched caption=" + w.caption + " class=" + w.resourceClass + " geometry=" + JSON.stringify(w.frameGeometry));
      if (w.fullScreen) w.fullScreen = false;
      w.setMaximize(false, false);
      const f = w.frameGeometry;
      const c = w.clientGeometry;
      const area = workspace.clientArea(KWin.FullScreenArea, w);
      w.frameGeometry = {x: area.x, y: area.y, width: #{@target_w} + (f.width - c.width), height: #{@target_h} + (f.height - c.height)};
    }
    """
  end

  defp window_class, do: Application.get_env(:starlight_bot, :game_window_class, "LimbusCompany")
  defp window_title, do: Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")
end
