defmodule StarlightBot.GameWindow do
  alias StarlightBot.{AppSettings, LauncherDeps, LogStore, Native, NestedGamescope, NestedKwin, SteamLaunch}
  alias StarlightBot.Vision.Capture

  @target_w 1920
  @target_h 1080
  @window_poll_ms 500
  @resize_settle_ms 1_500
  @resize_attempts 3
  @launch_settle_max_ms 20_000
  @launch_stable_ms 2_000
  @plugin_name "starlight-resize"

  def rect do
    case Native.get_window_rect(window_class()) do
      {:ok, x, y, w, h} -> {:ok, {x, y, w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  def aspect_ok?({_x, _y, w, h}), do: h > 0 and abs(w * 9 - h * 16) <= w * 9 * 0.005

  def launch(settings, launcher \\ AppSettings.launcher())

  def launch(%{launch_mode: "none"}, _launcher), do: {:error, :launch_disabled}

  def launch(%{launch_mode: mode} = settings, launcher) do
    case LauncherDeps.missing(launcher, mode) do
      [] -> launch_with(settings, launcher)
      missing -> log_failure({:error, {:missing_dependencies, missing}})
    end
  end

  defp launch_with(%{launch_mode: "steam", steam_app_id: app_id}, "direct") do
    LogStore.append(:info, "launch: opening Steam app #{app_id}")

    with :ok <- ensure_not_running(window_class() <> ".exe") do
      start("direct", ["steam", "steam://rungameid/#{app_id}"], [], File.cwd!())
    end
    |> log_failure()
  end

  defp launch_with(%{launch_mode: "steam", steam_app_id: app_id}, launcher) do
    LogStore.append(:info, "launch: opening Steam app #{app_id} in #{launcher_label(launcher)}")

    with :ok <- ensure_not_running(window_class() <> ".exe"),
         {:ok, %{argv: argv, env: env, cwd: cwd}} <- SteamLaunch.command(app_id, args: game_args(launcher)) do
      pin_resolution(launcher, env)
      start(launcher, argv, env, cwd)
    end
    |> log_failure()
  end

  defp launch_with(%{launch_mode: "exe", exe_path: path}, launcher) do
    LogStore.append(:info, "launch: opening #{path} in #{launcher_label(launcher)}")

    with :ok <- ensure_not_running(Path.basename(path)) do
      start(launcher, [path], [], File.cwd!())
    end
    |> log_failure()
  end

  def launch_program(%{launch_mode: "steam", steam_app_id: app_id} = settings, launcher, exe, args) do
    LogStore.append(:info, "launch: opening #{Path.basename(exe)} in #{launcher_label(launcher)} through Steam app #{app_id}")

    with [] <- LauncherDeps.missing(launcher, settings.launch_mode),
         :ok <- ensure_not_running(window_class() <> ".exe"),
         {:ok, %{argv: argv, env: env, cwd: cwd}} <- SteamLaunch.command(app_id, exe: exe, args: args) do
      start(launcher, argv, env, cwd)
    else
      [_ | _] = missing -> log_failure({:error, {:missing_dependencies, missing}})
      other -> log_failure(other)
    end
  end

  def launch_program(_settings, _launcher, _exe, _args), do: {:error, :steam_launch_mode_required}

  defp game_args(launcher) when launcher in ["gamescope", "gamescope_window"], do: ["-force-d3d11"]
  defp game_args(_launcher), do: []

  defp pin_resolution(launcher, env) when launcher in ["gamescope", "gamescope_window"] do
    with {_, data_path} <- List.keyfind(env, "STEAM_COMPAT_DATA_PATH", 0),
         reg_path = Path.join([data_path, "pfx", "user.reg"]),
         {:ok, reg} <- File.read(reg_path) do
      pinned =
        reg
        |> pin_dword(~r/^("Screenmanager Resolution (?:Window )?Width_h\d+"=dword:)[0-9a-f]{8}/m, @target_w)
        |> pin_dword(~r/^("Screenmanager Resolution (?:Window )?Height_h\d+"=dword:)[0-9a-f]{8}/m, @target_h)

      if pinned != reg, do: File.write!(reg_path, pinned)
    end

    :ok
  end

  defp pin_resolution(_launcher, _env), do: :ok

  defp pin_dword(reg, pattern, value) do
    hex = value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
    Regex.replace(pattern, reg, fn _, prefix -> prefix <> hex end)
  end

  defp start("direct", argv, env, cwd) do
    case System.cmd("sh", ["-c", ~s(setsid -f "$@" </dev/null >/dev/null 2>&1), "sh" | argv], stderr_to_stdout: true, env: env, cd: cwd) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:launch_failed, code, String.trim(out)}}
    end
  end

  defp start("gamescope", argv, env, cwd), do: NestedGamescope.spawn("headless", argv, env, cwd)
  defp start("gamescope_window", argv, env, cwd), do: NestedGamescope.spawn("wayland", argv, env, cwd)

  defp start(_kwin, argv, env, cwd) do
    with {:ok, kwin_pid} <- NestedKwin.ensure(),
         :ok <- NestedKwin.lock_frame(kwin_pid) do
      NestedKwin.spawn(argv, env, cwd)
    end
  end

  defp launcher_label("direct"), do: "a native window"
  defp launcher_label("gamescope"), do: "a headless gamescope"
  defp launcher_label("gamescope_window"), do: "a gamescope window"
  defp launcher_label(_kwin), do: "a nested KWin"

  def close do
    case System.cmd("pkill", ["-TERM", "-f", window_class() <> ".exe"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, :not_running}
    end
  end

  defp ensure_not_running(exe) do
    case System.cmd("pgrep", ["-f", exe], stderr_to_stdout: true) do
      {out, 0} ->
        pids = out |> String.split() |> Enum.join(", ")

        LogStore.append(
          :error,
          "launch: #{exe} is already running (pid #{pids}); Proton would wait for it to exit before starting a second copy, so close it first"
        )

        {:error, :already_running}

      _ ->
        :ok
    end
  end

  defp log_failure({:error, reason} = error) do
    LogStore.append(:error, "launch: failed: #{inspect(reason)}")
    error
  end

  defp log_failure(result), do: result

  def await_window(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_window(deadline)
  end

  def await_settled_window(timeout_ms) do
    with {:ok, _rect} <- await_window(timeout_ms) do
      await_stable_rect(System.monotonic_time(:millisecond) + @launch_settle_max_ms)
      Capture.refresh_window_rect()
      rect()
    end
  end

  defp await_stable_rect(deadline) do
    stable_until = System.monotonic_time(:millisecond) + @launch_stable_ms
    poll_stable(rect(), stable_until, deadline)
  end

  defp poll_stable(last, stable_until, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline or (now >= stable_until and match?({:ok, _}, last)) ->
        :ok

      true ->
        Process.sleep(@window_poll_ms)
        current = rect()

        if current == last,
          do: poll_stable(current, stable_until, deadline),
          else: poll_stable(current, System.monotonic_time(:millisecond) + @launch_stable_ms, deadline)
    end
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
    with {:ok, buses} <- resize_window(steam_app_id) do
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

  defp resize_window(steam_app_id) do
    case resize_hyprland(steam_app_id) do
      :ok -> {:ok, [:hyprland]}
      :skip -> resize_via_kwin_or_x11(steam_app_id)
    end
  end

  def resize_via_label(buses) do
    buses
    |> Enum.map(fn
      :hyprland -> "Hyprland"
      :x11 -> "X11"
      _kwin -> "KWin"
    end)
    |> Enum.uniq()
    |> Enum.join(" and ")
  end

  defp resize_hyprland(steam_app_id) do
    with signature when is_binary(signature) <- System.get_env("HYPRLAND_INSTANCE_SIGNATURE"),
         {out, 0} <- System.cmd("hyprctl", ["clients", "-j"], stderr_to_stdout: true),
         {:ok, clients} <- Jason.decode(out),
         %{"address" => address, "floating" => floating, "fullscreen" => fullscreen} <- Enum.find(clients, &hyprland_match?(&1, steam_app_id)) do
      target = "address:#{address}"

      if fullscreen != 0 do
        hyprland_dispatch(
          ~s|hl.dsp.window.fullscreen({ mode = "fullscreen", action = "unset", window = "#{target}" })|,
          [["focuswindow", target], ["fullscreen", "0"]]
        )
      end

      if not floating do
        hyprland_dispatch(~s|hl.dsp.window.float({ action = "enable", window = "#{target}" })|, [["setfloating", target]])
      end

      hyprland_dispatch(
        ~s|hl.dsp.window.resize({ x = #{@target_w}, y = #{@target_h}, window = "#{target}" })|,
        [["resizewindowpixel", "exact #{@target_w} #{@target_h},#{target}"]]
      )

      :ok
    else
      _ -> :skip
    end
  end

  defp hyprland_dispatch(lua, legacy_commands) do
    case System.cmd("hyprctl", ["dispatch", lua], stderr_to_stdout: true) do
      {"ok" <> _, 0} ->
        :ok

      _ ->
        for command <- legacy_commands, do: System.cmd("hyprctl", ["dispatch" | command], stderr_to_stdout: true)
        :ok
    end
  end

  defp hyprland_match?(client, steam_app_id) do
    class = String.downcase(client["class"] || "")
    client["title"] == window_title() or class == String.downcase(window_class()) or class == "steam_app_#{steam_app_id}"
  end

  defp resize_via_kwin_or_x11(steam_app_id) do
    case run_resize_script(steam_app_id) do
      {:ok, buses} ->
        {:ok, buses}

      {:error, {:kwin_unreachable, _}} ->
        case Native.resize_window(window_class(), @target_w, @target_h) do
          :ok -> {:ok, [:x11]}
          {:error, reason} -> {:error, reason}
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
