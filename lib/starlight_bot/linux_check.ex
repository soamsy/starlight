defmodule StarlightBot.LinuxCheck do
  alias StarlightBot.{Data, GameWindow, Native, Scheduler, WinProbe}

  @target_title "starlight-target"
  @cmd_timeout_ms 5_000
  @key_a 30
  @btn_left 0x110
  @btn_right 0x111
  @key_esc 1
  @injected_probe_duration_s 120
  @hardware_probe_duration_s 25

  @checks [
    %{id: :session, group: "Environment", title: "Session and compositor", active?: false},
    %{id: :tools, group: "Environment", title: "Helper tools", active?: false},
    %{id: :portals, group: "Environment", title: "XDG portals", active?: false},
    %{id: :protocols, group: "Environment", title: "Wayland protocols", active?: false},
    %{id: :uinput, group: "Environment", title: "uinput access", active?: false},
    %{id: :x_displays, group: "Environment", title: "X displays and game window", active?: false},
    %{id: :resize, group: "Game window", title: "Resize game window to 1920x1080", active?: true},
    %{id: :target, group: "Input and capture", title: "Open test window", active?: true},
    %{id: :capture, group: "Input and capture", title: "Capture test window", active?: true},
    %{id: :eis, group: "Input and capture", title: "Connect input", active?: true},
    %{id: :cursor, group: "Input and capture", title: "Cursor control", active?: true},
    %{id: :click, group: "Input and capture", title: "Move and click", active?: true},
    %{id: :keyboard, group: "Input and capture", title: "Type a key", active?: true},
    %{id: :close, group: "Input and capture", title: "Close test window", active?: true},
    %{id: :winprobe_direct, group: "Windows input", title: "Injected input, native window", active?: true, manual?: true},
    %{id: :winprobe_gamescope_window, group: "Windows input", title: "Injected input, gamescope window", active?: true, manual?: true},
    %{id: :winprobe_gamescope, group: "Windows input", title: "Injected input, headless gamescope", active?: true, manual?: true},
    %{id: :winprobe_hardware_direct, group: "Windows input", title: "Real hardware baseline, native window", active?: true, manual?: true},
    %{id: :winprobe_hardware_gamescope_window, group: "Windows input", title: "Real hardware baseline, gamescope window", active?: true, manual?: true}
  ]

  @tools [
    %{bin: "wayland-info", why: "lists the protocols the compositor offers", pkg: %{arch: "wayland-utils", debian: "wayland-utils", fedora: "wayland-utils"}},
    %{bin: "busctl", why: "inspects the XDG portals", pkg: %{arch: "systemd", debian: "systemd", fedora: "systemd"}},
    %{bin: "Xwayland", why: "the game and the test window run on it", pkg: %{arch: "xorg-xwayland", debian: "xwayland", fedora: "xorg-x11-server-Xwayland"}},
    %{bin: "python3", why: "runs the test window", pkg: %{arch: "python", debian: "python3", fedora: "python3"}},
    %{bin: "ei-debug-events", why: "optional: watch libei events by hand", optional: true, pkg: %{arch: "libei", debian: "libei-tools", fedora: "libei-utils"}},
    %{bin: "wtype", why: "optional: type on wlroots compositors by hand", optional: true, pkg: %{arch: "wtype", debian: "wtype", fedora: "wtype"}},
    %{bin: "wlrctl", why: "optional: move the pointer on wlroots compositors by hand", optional: true, pkg: %{arch: "wlrctl", debian: "wlrctl", fedora: "wlrctl"}}
  ]

  @pyside_pkg %{arch: "pyside6", debian: "python3-pyside6.qtwidgets", fedora: "python3-pyside6"}

  @portal_backends %{
    kde: "xdg-desktop-portal-kde",
    gnome: "xdg-desktop-portal-gnome",
    cosmic: "xdg-desktop-portal-cosmic",
    hyprland: "xdg-desktop-portal-hyprland",
    wlroots: "xdg-desktop-portal-wlr"
  }

  @portals ~w(RemoteDesktop ScreenCast InputCapture Screenshot)

  @protocols [
    {"zwlr_virtual_pointer_manager_v1", "virtual pointer input (wlroots style)"},
    {"zwp_virtual_keyboard_manager_v1", "virtual keyboard input"},
    {"ext_image_copy_capture_manager_v1", "screen capture"},
    {"zwlr_screencopy_manager_v1", "screen capture (older wlroots)"},
    {"ext_foreign_toplevel_list_v1", "window list"},
    {"zwlr_foreign_toplevel_manager_v1", "window list (older wlroots)"},
    {"zwp_pointer_constraints_v1", "pointer constraints"},
    {"xwayland_shell_v1", "Xwayland integration"}
  ]

  def checks, do: @checks
  def passive_ids, do: for(%{active?: false, id: id} <- @checks, do: id)
  def active_ids, do: for(%{active?: true, id: id} = check <- @checks, not Map.get(check, :manual?, false), do: id)
  def target_title, do: @target_title
  def heading, do: "Linux checks"
  def log_prefix, do: "linux-check: "

  def run(id, log) when is_atom(id) do
    status = check(id, log)
    log.(status_kind(status), "#{title(id)}: #{status}")
    status
  end

  defp title(id), do: Enum.find(@checks, &(&1.id == id)).title

  defp status_kind(:ok), do: :ok
  defp status_kind(:warn), do: :info
  defp status_kind(:error), do: :error

  defp check(:session, log) do
    env = ~w(XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION WAYLAND_DISPLAY DISPLAY LIBEI_SOCKET XDG_RUNTIME_DIR)

    for name <- env do
      log.(:info, "#{name}=#{System.get_env(name) || "(unset)"}")
    end

    log.(:info, "distro: #{os_release()["PRETTY_NAME"] || "unknown"} (package family: #{distro()})")
    compositor = compositor()
    log.(:info, "compositor: #{compositor}")
    log.(:info, "expected input path: #{expected_input(compositor)}")

    cond do
      System.get_env("XDG_SESSION_TYPE") != "wayland" -> fail(log, "not a Wayland session")
      compositor == :unknown -> :warn
      true -> :ok
    end
  end

  defp check(:tools, log) do
    found = Map.new(@tools, &{&1.bin, System.find_executable(&1.bin)})

    for tool <- @tools do
      case found[tool.bin] do
        nil -> log.(if(tool[:optional], do: :info, else: :error), "#{tool.bin}: missing, #{tool.why}")
        path -> log.(:ok, "#{tool.bin}: #{path}")
      end
    end

    pyside = pyside?()
    log.(if(pyside, do: :ok, else: :error), "PySide6: #{if pyside, do: "importable", else: "missing, runs the test window"}")

    absent = Enum.filter(@tools, &(found[&1.bin] == nil)) ++ if(pyside, do: [], else: [%{pkg: @pyside_pkg}])
    log_install(log, absent |> Enum.map(&Map.get(&1.pkg, distro())) |> Enum.reject(&is_nil/1))

    if Enum.any?(absent, &(not Map.get(&1, :optional, false))), do: :error, else: :ok
  end

  defp check(:portals, log) do
    case cmd("busctl", ["--user", "introspect", "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"]) do
      {:ok, out} ->
        found = parse_portals(out)

        for name <- @portals do
          case found[name] do
            nil -> log.(:error, "portal #{name}: not offered")
            version -> log.(:ok, "portal #{name}: v#{version}")
          end
        end

        backends = running_portal_backends(log)
        wanted = @portal_backends[compositor() |> portal_family()]
        if wanted, do: log.(:info, "backend for this desktop: #{wanted}")
        log_install_for_portal(log, wanted, backends)
        if found["RemoteDesktop"], do: :ok, else: :error

      {:error, reason} ->
        log.(:error, "could not reach the portal service: #{reason}")
        :error
    end
  end

  defp check(:protocols, log) do
    if System.get_env("WAYLAND_DISPLAY") == nil do
      log.(:error, "WAYLAND_DISPLAY is unset")
      :error
    else
      case cmd("wayland-info", []) do
        {:ok, out} ->
          globals = Regex.scan(~r/interface: '([a-z_0-9]+)'/, out) |> Enum.map(&List.last/1) |> MapSet.new()
          log.(:info, "compositor offers #{MapSet.size(globals)} protocols")

          for {name, what} <- @protocols do
            if MapSet.member?(globals, name), do: log.(:ok, "#{name}: #{what}"), else: log.(:info, "#{name}: absent (#{what})")
          end

          :ok

        {:error, reason} ->
          log.(:error, "wayland-info failed: #{reason}")
          :error
      end
    end
  end

  defp check(:uinput, log) do
    case File.open("/dev/uinput", [:write]) do
      {:ok, io} ->
        File.close(io)
        log.(:ok, "/dev/uinput is writable")
        :ok

      {:error, reason} ->
        log.(:error, "/dev/uinput: #{:file.format_error(reason)}")
        log.(:info, "fix: add yourself to the input group and add a udev rule: KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\"")
        :error
    end
  end

  defp check(:x_displays, log) do
    sockets = Path.wildcard("/tmp/.X11-unix/X*")
    log.(:info, "X sockets: #{Enum.join(sockets, " ")}")
    log.(:info, "host DISPLAY: #{System.get_env("DISPLAY") || "(unset)"}")
    title = Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")

    case Native.window_details(title) do
      {:ok, lines} ->
        for line <- lines, do: log.(:info, "#{title}: #{line}")
        game_window_verdict(title, lines, log)

      {:error, reason} ->
        log.(:info, "#{title} window not found: #{inspect(reason)}")
        :warn
    end
  end

  defp check(:resize, log) do
    case GameWindow.rect() do
      {:ok, {_, _, w, h}} ->
        log.(:info, "#{Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")} client area is #{w}x#{h}")

        case GameWindow.fix_aspect(Scheduler.get_settings().steam_app_id) do
          {:ok, %{after: {_, _, aw, ah}, buses: buses}} ->
            log.(:ok, "resized to #{aw}x#{ah} through #{GameWindow.resize_via_label(buses)}")
            :ok

          {:error, {:resize_ignored, %{after: {_, _, aw, ah}, buses: buses}}} ->
            fail(log, "#{GameWindow.resize_via_label(buses)} ran the resize but the window stayed #{aw}x#{ah}")

          {:error, reason} ->
            fail(log, "resize failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        log.(:info, "game window not found (#{inspect(reason)}); start Limbus first")
        :warn
    end
  end

  defp check(:target, log) do
    stop_target()
    File.rm(target_log())

    with {:ok, python} <- find(System.find_executable("python3"), "python3 is not installed"),
         true <- pyside?() || {:error, "PySide6 is not installed"},
         :ok <- spawn_target(python),
         :ok <- wait_for(fn -> match?({:ok, "shown\n" <> _}, File.read(target_log())) end, 8_000, "the test window never appeared"),
         {:ok, rect} <- wait_for_rect(5_000) do
      log.(:ok, "test window open at #{inspect(rect)}")
      :ok
    else
      {:error, reason} ->
        log.(:error, "#{reason}")
        :error
    end
  end

  defp check(:capture, log) do
    with {:ok, bin, w, h} <- grab(log) do
      log.(:info, "captured #{w}x#{h}")
      pixel = center_pixel(bin, w, h)
      log.(if(pixel == {0, 0, 255}, do: :ok, else: :error), "center pixel (B,G,R) = #{inspect(pixel)}, expected {0, 0, 255} (red)")
      if pixel == {0, 0, 255}, do: :ok, else: :error
    else
      _ -> :error
    end
  end

  defp check(:eis, log) do
    with :ok <- ensure_input(log) do
      log.(:ok, "input ready through #{Native.input_backend()}")
      :ok
    end
  end

  defp check(:cursor, log) do
    case Native.get_cursor_pos() do
      {:ok, x, y} ->
        log.(:ok, "cursor readback works, cursor at #{x},#{y}")
        :ok

      {:error, reason} ->
        log.(:info, "no cursor readback (#{inspect(reason)}), trying the absolute pointer")
        absolute_probe(log)
    end
  end

  defp check(:click, log) do
    with {:ok, {x, y, w, h}} <- target_rect(log),
         :ok <- ensure_input(log) do
      File.write(target_log(), "")
      goal = {x + div(w, 2), y + div(h, 2)}
      log.(:info, "aiming at #{inspect(goal)}")
      reach(goal, log)
      Process.sleep(400)

      case last_event("move") do
        [_, hx, hy] -> log.(:info, "pointer is over the window at #{hx},#{hy}")
        _ -> log.(:info, "the window has not seen the pointer yet")
      end

      Native.button_event(@btn_left, true)
      Process.sleep(60)
      Native.button_event(@btn_left, false)
      Process.sleep(400)

      case last_event("press") do
        [_, "LeftButton", lx, ly] ->
          log.(:ok, "click landed at window #{lx},#{ly}, expected about #{div(w, 2)},#{div(h, 2)}")
          log_origin(log)
          verify_flip(log)

        _ ->
          log.(:error, "the test window saw no click")
          :error
      end
    else
      _ -> :error
    end
  end

  defp check(:keyboard, log) do
    with {:ok, _rect} <- target_rect(log),
         :ok <- ensure_input(log) do
      Native.key_event(@key_a, true)
      Process.sleep(40)
      Native.key_event(@key_a, false)
      Process.sleep(300)

      case last_event("key") do
        [_, "'a'" | _] ->
          log.(:ok, "the test window received 'a'")
          :ok

        [_, other | _] ->
          log.(:error, "the test window received #{other} instead of 'a'")
          :error

        _ ->
          log.(:error, "the test window saw no key press (does it have focus?)")
          :error
      end
    else
      _ -> :error
    end
  end

  defp check(:winprobe_direct, log), do: run_probe(:injected, "direct", log)
  defp check(:winprobe_gamescope_window, log), do: run_probe(:injected, "gamescope_window", log)
  defp check(:winprobe_gamescope, log), do: run_probe(:injected, "gamescope", log)
  defp check(:winprobe_hardware_direct, log), do: run_probe(:hardware, "direct", log)
  defp check(:winprobe_hardware_gamescope_window, log), do: run_probe(:hardware, "gamescope_window", log)

  defp check(:close, log) do
    stop_target()
    Native.get_window_rect(Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany"))
    log.(:ok, "test window closed")
    :ok
  end

  defp run_probe(mode, launcher, log) do
    settings = Scheduler.get_settings()
    dir = Path.join(Data.paths().root, "winprobe")
    exe = Path.join(dir, "winprobe.exe")
    stamp = Calendar.strftime(NaiveDateTime.local_now(), "%Y%m%d-%H%M%S")
    out = Path.join(dir, "winprobe-#{mode}-#{launcher}-#{stamp}.log")
    duration = if mode == :injected, do: @injected_probe_duration_s, else: @hardware_probe_duration_s

    with :ok <- install_probe(dir, exe, log) do
      log.(:info, "launcher #{launcher} (this check overrides the saved launcher setting), launch mode #{settings.launch_mode}, raw event log #{out}")

      case GameWindow.launch_program(settings, launcher, exe, ["--out=" <> out, "--duration=#{duration}"]) do
        :ok ->
          result = probe_session(mode, out, duration, log)
          System.cmd("pkill", ["-f", "winprobe.exe"], stderr_to_stdout: true)
          Native.forget_window()
          result

        {:error, :already_running} ->
          log.(:info, "close Limbus first; Proton would hold the probe until the game exits")
          :warn

        {:error, :steam_launch_mode_required} ->
          fail(log, "the probe starts through Steam's Proton, so the scheduler launch mode must be steam")

        {:error, reason} ->
          fail(log, "could not start the probe: #{inspect(reason)}")
      end
    end
  end

  defp install_probe(dir, exe, log) do
    with true <- File.regular?(WinProbe.exe_path()) || {:error, missing_probe_message()},
         :ok <- File.mkdir_p(dir),
         :ok <- File.cp(WinProbe.exe_path(), exe) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> fail(log, reason)
      {:error, reason} -> fail(log, "could not install the probe: #{inspect(reason)}")
    end
  end

  defp missing_probe_message do
    zig = if System.find_executable("zig"), do: "zig is installed", else: "zig is not installed, install it first"
    "#{WinProbe.exe_path()} is missing, so there is nothing to run inside Proton. Build it with priv/linux_checks/build_winprobe.sh (#{zig})"
  end

  defp probe_session(mode, out, duration, log) do
    with :ok <- wait_for(fn -> WinProbe.ready?(read_probe(out)) end, 120_000, "the probe never started; check the launch log for Proton errors"),
         {:ok, {x, y, w, h} = rect} <- wait_for_rect(20_000, WinProbe.title()) do
      log.(:ok, "probe running, client area #{w}x#{h} at #{x},#{y}")
      drive_probe(mode, rect, duration, log)

      case wait_for(fn -> WinProbe.finished?(read_probe(out)) end, 15_000 + duration * 1_000, "the probe did not finish") do
        :ok -> WinProbe.report(WinProbe.parse(read_probe(out)), mode, log)
        {:error, message} ->
          log.(:error, message)
          WinProbe.report(WinProbe.parse(read_probe(out)), mode, log)
          :error
      end
    else
      {:error, message} -> fail(log, message)
    end
  end

  defp read_probe(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp drive_probe(:injected, {x, y, w, h}, _duration, log) do
    center = {x + div(w, 2), y + div(h, 2)}

    with :ok <- Native.init_input(WinProbe.title(), Data.portal_token_path()) do
      log.(:info, "input connected through #{Native.input_backend()}")
      reach(center, log)
      Process.sleep(500)
      sweep(center, log)
      Process.sleep(200)
      tap_button(@btn_left, 60)
      tap_button(@btn_left, 20)
      tap_button(@btn_right, 40)
      Native.scroll(0, 120)
      Process.sleep(200)
      tap_key(@key_a, 40)
      tap_key(@key_a, 120)
      Process.sleep(300)
      tap_key(@key_esc, 40)
      log.(:info, "sent a relative sweep, an absolute sweep, 2 left clicks, 1 right click, 1 wheel notch, 2 presses of A and Escape")
    else
      {:error, reason} -> log.(:error, "libei connection failed: #{inspect(reason)}")
    end
  end

  defp drive_probe(:hardware, _rect, duration, log) do
    log.(:info, "use your real mouse and keyboard on the probe window now: move around, left and right click, scroll, type A; press Escape to finish, or it closes after #{duration} s")
    log.(:info, "this only works when the probe window is visible on your desktop (native window or gamescope window launcher)")
  end

  defp sweep({cx, cy}, log) do
    sweep_steps("relative", log, fn _ -> Native.move_relative(4.0, 2.0) end)
    sweep_steps("absolute", log, fn i -> Native.move_absolute((cx + 160 - i * 4) * 1.0, (cy + 80 - i * 2) * 1.0) end)
  end

  defp sweep_steps(label, log, move) do
    log.(:info, "sweeping the pointer in 40 steps with #{label} moves")

    failure =
      Enum.find_value(1..40, fn i ->
        result = move.(i)
        Process.sleep(8)
        if result != :ok, do: result
      end)

    if failure, do: log.(:info, "#{label} moves reported #{inspect(failure)}")
    Process.sleep(150)
  end

  defp tap_button(code, hold_ms) do
    Native.button_event(code, true)
    Process.sleep(hold_ms)
    Native.button_event(code, false)
    Process.sleep(150)
  end

  defp tap_key(code, hold_ms) do
    Native.key_event(code, true)
    Process.sleep(hold_ms)
    Native.key_event(code, false)
    Process.sleep(150)
  end

  defp game_window_verdict(title, lines, log) do
    text = Enum.join(lines, "\n")
    [_, ww, wh] = Regex.run(~r/window geometry (\d+)x(\d+)/, text)
    [_, cw, ch, cx, cy] = Regex.run(~r/client area (\d+)x(\d+) at \+(\d+)\+(\d+)/, text)
    framed? = {ww, wh} != {cw, ch}

    if framed? do
      log.(:info, "#{title} has a frame drawn inside its window (#{ww}x#{wh} window, #{cw}x#{ch} client at +#{cx}+#{cy}); Starlight uses the client area")
    end

    save_game_capture(title, log)

    cond do
      {cw, ch} == {"1920", "1080"} ->
        log.(:ok, "#{title} client area is 1920x1080")
        :ok

      true ->
        fail(log, "#{title} client area is #{cw}x#{ch}, not 1920x1080; use the resize button")
    end
  end

  defp save_game_capture(title, log) do
    path = Path.join(Data.screenshots_dir(), "linux-check-game.png")

    with {:ok, bin, w, h} <- Native.grab_frame(title),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Native.save_png(bin, w, h, path) do
      log.(:info, "saved a #{w}x#{h} capture of the game to #{path}")
    else
      other -> log.(:error, "could not save a capture of the game: #{inspect(other)}")
    end
  end

  defp absolute_probe(log) do
    with {:ok, {x, y, w, h}} <- target_rect(log),
         :ok <- ensure_input(log),
         :ok <- Native.move_absolute((x + div(w, 2)) * 1.0, (y + div(h, 2)) * 1.0) do
      log.(:ok, "absolute pointer works, the bot moves the cursor with it")
      :ok
    else
      _ ->
        log.(:info, "absolute pointer unavailable; moves fall back to relative steps and the tracked position")
        :warn
    end
  end

  defp reach({gx, gy} = goal, log) do
    case Native.move_absolute(gx * 1.0, gy * 1.0) do
      :ok ->
        log.(:info, "moved with the absolute pointer")

      {:error, reason} ->
        log.(:info, "absolute pointer unavailable (#{inspect(reason)}), using relative moves")
        reach_relative(goal, log)
    end
  end

  defp reach_relative({gx, gy}, log) do
    case Native.get_cursor_pos() do
      {:ok, _, _} -> nudge({gx, gy}, 6, log)
      {:error, _} ->
        log.(:info, "no cursor readback, sliding to the top left corner first")
        for _ <- 1..80 do
          Native.move_relative(-300.0, -300.0)
          Process.sleep(8)
        end
        Process.sleep(100)
        step_toward({0, 0}, {gx, gy})
    end
  end

  defp nudge(_goal, 0, log), do: log.(:info, "stopped nudging after 6 tries")

  defp nudge({gx, gy} = goal, tries, log) do
    {:ok, cx, cy} = Native.get_cursor_pos()
    {dx, dy} = {gx - cx, gy - cy}

    if abs(dx) <= 1 and abs(dy) <= 1 do
      log.(:info, "cursor within 1px of the goal")
    else
      step_toward({cx, cy}, goal)
      Process.sleep(80)
      nudge(goal, tries - 1, log)
    end
  end

  defp step_toward({cx, cy}, {gx, gy}) do
    {dx, dy} = {gx - cx, gy - cy}
    steps = max(div(max(abs(dx), abs(dy)), 40), 1)

    for _ <- 1..steps do
      Native.move_relative(dx / steps, dy / steps)
      Process.sleep(8)
    end
  end

  defp verify_flip(log) do
    with {:ok, bin, w, h} <- grab(log) do
      pixel = center_pixel(bin, w, h)
      log.(if(pixel == {0, 255, 0}, do: :ok, else: :error), "center pixel after click (B,G,R) = #{inspect(pixel)}, expected {0, 255, 0} (green)")
      if pixel == {0, 255, 0}, do: :ok, else: :error
    else
      _ -> :error
    end
  end

  defp ensure_input(log) do
    case Native.move_relative(0.0, 0.0) do
      :ok ->
        :ok

      {:error, _} ->
        case Native.init_input(@target_title, Data.portal_token_path()) do
          :ok -> :ok
          {:error, reason} -> fail(log, "libei connection failed: #{inspect(reason)}")
        end
    end
  end

  defp fail(log, text) do
    log.(:error, text)
    :error
  end

  defp target_rect(log) do
    case Native.get_window_rect(@target_title) do
      {:ok, x, y, w, h} ->
        {:ok, {x, y, w, h}}

      {:error, reason} -> fail(log, "test window not found (#{inspect(reason)}); run \"Open test window\" first")
    end
  end

  defp grab(log) do
    case Native.grab_frame(@target_title) do
      {:ok, bin, w, h} -> {:ok, bin, w, h}
      {:error, reason} -> fail(log, "capture failed: #{inspect(reason)}")
    end
  end

  defp center_pixel(bin, w, h) do
    offset = (div(h, 2) * w + div(w, 2)) * 3
    <<b, g, r>> = binary_part(bin, offset, 3)
    {b, g, r}
  end

  defp log_origin(log) do
    case File.read(target_log()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "origin "))
        |> List.last()
        |> case do
          nil -> :ok
          line -> log.(:info, "the window saw the click from " <> String.replace_prefix(line, "origin ", ""))
        end

      _ ->
        :ok
    end
  end

  defp last_event(kind) do
    case File.read(target_log()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, kind <> " "))
        |> List.last()
        |> case do
          nil -> nil
          line -> String.split(line, " ")
        end

      _ ->
        nil
    end
  end

  defp target_log, do: Path.join(System.tmp_dir!(), "starlight-linux-check-target.log")
  defp target_script, do: Application.app_dir(:starlight_bot, "priv/linux_checks/target.py")

  defp spawn_target(python) do
    env = [{"QT_QPA_PLATFORM", "xcb"}]

    case System.cmd("sh", ["-c", ~s(exec "$@" >/dev/null 2>&1 &), "sh", python, "-I", target_script(), target_log()], env: env) do
      {_, 0} -> :ok
      {out, code} -> {:error, "could not start the test window (#{code}): #{out}"}
    end
  end

  defp stop_target do
    System.cmd("pkill", ["-f", target_script()], stderr_to_stdout: true)
    Native.forget_window()
    :ok
  end

  defp wait_for(fun, timeout_ms, message) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, message)
  end

  defp do_wait(fun, deadline, message) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> {:error, message}
      true -> Process.sleep(150) && do_wait(fun, deadline, message)
    end
  end

  defp wait_for_rect(timeout_ms, title \\ @target_title) do
    result =
      wait_for(
        fn -> match?({:ok, _, _, _, _}, Native.get_window_rect(title)) end,
        timeout_ms,
        "the #{title} window opened but could not be located on any X display"
      )

    with :ok <- result, {:ok, x, y, w, h} <- Native.get_window_rect(title), do: {:ok, {x, y, w, h}}
  end

  defp find(nil, message), do: {:error, message}
  defp find(value, _message), do: {:ok, value}

  defp pyside? do
    case cmd("python3", ["-I", "-c", "import PySide6.QtWidgets"]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp cmd(exe, args) do
    case System.find_executable(exe) do
      nil ->
        {:error, "#{exe} is not installed"}

      path ->
        task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

        case Task.yield(task, @cmd_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} -> {:ok, out}
          {:ok, {out, code}} -> {:error, "exit #{code}: #{String.slice(out, 0, 300)}"}
          _ -> {:error, "timed out"}
        end
    end
  end

  defp parse_portals(out) do
    out
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &portal_line/2)
    |> elem(1)
  end

  defp portal_line(line, {current, found}) do
    interface = Regex.run(~r/^org\.freedesktop\.portal\.(\w+)\s+interface/, line)
    version = Regex.run(~r/^\.version\s+property\s+u\s+(\d+)/, line)

    cond do
      interface -> {List.last(interface), found}
      current && version -> {current, Map.put_new(found, current, List.last(version))}
      true -> {current, found}
    end
  end

  defp running_portal_backends(log) do
    case cmd("busctl", ["--user", "list", "--no-legend"]) do
      {:ok, out} ->
        backends = Regex.scan(~r/org\.freedesktop\.impl\.portal\.desktop\.(\w+)/, out) |> Enum.map(&List.last/1) |> Enum.uniq()
        log.(:info, "portal backends on the bus: #{Enum.join(backends, ", ")}")
        backends

      _ ->
        []
    end
  end

  defp log_install_for_portal(_log, nil, _backends), do: :ok

  defp log_install_for_portal(log, wanted, backends) do
    short = wanted |> String.replace_prefix("xdg-desktop-portal-", "")

    if short in backends do
      log.(:ok, "#{wanted} is running")
    else
      log.(:error, "#{wanted} is not running")
      log_install(log, [wanted])
    end
  end

  defp log_install(_log, []), do: :ok

  defp log_install(log, packages) do
    packages = Enum.uniq(packages)

    case install_prefix(distro()) do
      nil -> log.(:info, "install these with your package manager: #{Enum.join(packages, " ")}")
      prefix -> log.(:info, "install: #{prefix} #{Enum.join(packages, " ")}")
    end
  end

  defp install_prefix(:arch), do: "sudo pacman -S --needed"
  defp install_prefix(:debian), do: "sudo apt install"
  defp install_prefix(:fedora), do: "sudo dnf install"
  defp install_prefix(_), do: nil

  defp os_release do
    case File.read("/etc/os-release") do
      {:ok, text} ->
        for line <- String.split(text, "\n"), [k, v] <- [String.split(line, "=", parts: 2)], into: %{}, do: {k, String.trim(v, "\"")}

      _ ->
        %{}
    end
  end

  def distro do
    release = os_release()
    ids = [release["ID"] | String.split(release["ID_LIKE"] || "")]

    cond do
      Enum.any?(ids, &(&1 in ["arch", "cachyos", "manjaro"])) -> :arch
      Enum.any?(ids, &(&1 in ["debian", "ubuntu"])) -> :debian
      Enum.any?(ids, &(&1 in ["fedora", "rhel"])) -> :fedora
      true -> :other
    end
  end

  def compositor do
    desktop = String.downcase(System.get_env("XDG_CURRENT_DESKTOP") || System.get_env("DESKTOP_SESSION") || "")

    cond do
      String.contains?(desktop, "kde") -> :kde
      String.contains?(desktop, "gnome") -> :gnome
      String.contains?(desktop, "cosmic") -> :cosmic
      String.contains?(desktop, "hyprland") -> :hyprland
      String.contains?(desktop, "niri") -> :niri
      String.contains?(desktop, "sway") -> :sway
      String.contains?(desktop, "labwc") -> :labwc
      String.contains?(desktop, "wayfire") -> :wayfire
      true -> :unknown
    end
  end

  defp portal_family(compositor) when compositor in [:sway, :labwc, :wayfire, :niri], do: :wlroots
  defp portal_family(compositor), do: compositor

  defp expected_input(:kde), do: "libei straight from KWin"
  defp expected_input(compositor) when compositor in [:gnome, :cosmic], do: "libei through the RemoteDesktop portal"
  defp expected_input(compositor) when compositor in [:niri, :hyprland, :sway, :labwc, :wayfire],
    do: "libei through the RemoteDesktop portal if the backend offers it, otherwise the Wayland virtual pointer and keyboard protocols"
  defp expected_input(_), do: "unknown"
end
