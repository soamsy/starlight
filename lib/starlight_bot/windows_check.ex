defmodule StarlightBot.WindowsCheck do
  alias StarlightBot.{Data, Native, WinProbe}

  @target_duration_s 900
  @injected_probe_duration_s 120
  @hardware_probe_duration_s 25
  @key_a 30
  @key_esc 1
  @btn_left 0x110
  @btn_right 0x111
  @red {0, 0, 255}
  @green {0, 255, 0}

  @checks [
    %{id: :system, group: "Environment", title: "Windows and displays", active?: false},
    %{id: :tools, group: "Environment", title: "Zig and the test window", active?: false},
    %{id: :game_window, group: "Environment", title: "Game window", active?: false},
    %{id: :guard, group: "Environment", title: "SendInput refuses the game", active?: false},
    %{id: :resize, group: "Game window", title: "Resize game window to 1920x1080", active?: true},
    %{id: :build, group: "Input and capture", title: "Build test window", active?: true},
    %{id: :target, group: "Input and capture", title: "Open test window", active?: true},
    %{id: :capture, group: "Input and capture", title: "Capture test window", active?: true},
    %{id: :input, group: "Input and capture", title: "Connect input", active?: true},
    %{id: :cursor, group: "Input and capture", title: "Cursor readback", active?: true},
    %{id: :click, group: "Input and capture", title: "Move and click", active?: true},
    %{id: :keyboard, group: "Input and capture", title: "Type a key", active?: true},
    %{id: :close, group: "Input and capture", title: "Close test window", active?: true},
    %{id: :probe_injected, group: "What a game can see", title: "SendInput, test window", active?: true, manual?: true},
    %{id: :probe_hardware, group: "What a game can see", title: "Real hardware baseline", active?: true, manual?: true}
  ]

  def checks, do: @checks
  def passive_ids, do: for(%{active?: false, id: id} <- @checks, do: id)
  def active_ids, do: for(%{active?: true, id: id} = check <- @checks, not Map.get(check, :manual?, false), do: id)
  def heading, do: "Windows checks"
  def log_prefix, do: "windows-check: "

  def run(id, log) when is_atom(id) do
    status = check(id, log)
    log.(status_kind(status), "#{title(id)}: #{status}")
    status
  end

  defp title(id), do: Enum.find(@checks, &(&1.id == id)).title

  defp status_kind(:ok), do: :ok
  defp status_kind(:warn), do: :info
  defp status_kind(:error), do: :error

  defp check(:system, log) do
    {family, name} = :os.type()
    {major, minor, build} = :os.version()
    log.(:info, "os: #{family}/#{name} #{major}.#{minor}.#{build}, #{System.get_env("PROCESSOR_ARCHITECTURE") || "unknown arch"}")

    case Native.system_details() do
      {:ok, lines} ->
        for line <- lines, do: log.(:info, line)
        scaled = Enum.filter(lines, &Regex.match?(~r/scale (?!100%)\d+%/, &1))
        if scaled != [], do: log.(:info, "a monitor is scaled; Starlight reads physical pixels, so this only matters if a capture looks off")
        :ok

      {:error, reason} ->
        fail(log, "could not read system details: #{inspect(reason)}")
    end
  end

  defp check(:tools, log) do
    zig = zig()
    log.(if(zig, do: :ok, else: :info), "zig: #{zig || "not found, install it with: winget install zig.zig"}")
    log.(:info, "test window source: #{WinProbe.source_path()}")

    cond do
      probe_fresh?() ->
        log.(:ok, "test window built: #{probe_exe()}")
        :ok

      zig ->
        log.(:info, "test window not built yet; \"Build test window\" compiles it to #{probe_exe()}")
        :warn

      true ->
        fail(log, "the test window is not built and zig is missing to build it")
    end
  end

  defp check(:game_window, log) do
    title = game_title()

    case Native.window_details(title) do
      {:ok, lines} ->
        for line <- lines, do: log.(:info, "#{title}: #{line}")
        save_game_capture(title, log)
        game_window_verdict(title, lines, log)

      {:error, reason} ->
        log.(:info, "#{title} window not found (#{inspect(reason)}); start Limbus to check it")
        :warn
    end
  end

  defp check(:guard, log) do
    title = game_title()

    case Native.init_input(title, "") do
      {:error, :input_refused} ->
        log.(:ok, "SendInput refused to target #{title}; it only accepts the #{WinProbe.title()} test window")
        log.(:info, "every SendInput call also checks that the foreground window is not LimbusCompany.exe, that pointer events land on the test window, and that keys go to a foreground test window")
        :ok

      other ->
        fail(log, "SendInput did not refuse #{title}: #{inspect(other)}")
    end
  end

  defp check(:resize, log) do
    title = game_title()

    with {:ok, _, _, bw, bh} <- Native.get_window_rect(title) do
      log.(:info, "#{title} client area is #{bw}x#{bh}")

      with :ok <- Native.resize_window(title, 1920, 1080),
           Process.sleep(500),
           {:ok, _, _, w, h} <- Native.get_window_rect(title) do
        if {w, h} == {1920, 1080} do
          log.(:ok, "resized to 1920x1080 with SetWindowPos")
          :ok
        else
          fail(log, "SetWindowPos ran but the client area is #{w}x#{h}")
        end
      else
        other -> fail(log, "resize failed: #{inspect(other)}")
      end
    else
      {:error, reason} ->
        log.(:info, "game window not found (#{inspect(reason)}); start Limbus first")
        :warn
    end
  end

  defp check(:build, log), do: ensure_probe(log)

  defp check(:target, log) do
    stop_probe(target_log())

    with :ok <- ensure_probe(log),
         :ok <- launch_probe(target_log(), @target_duration_s),
         :ok <- wait_for(fn -> WinProbe.ready?(read(target_log())) end, 10_000, "the test window never reported ready"),
         {:ok, {x, y, w, h}} <- wait_for_rect(5_000) do
      log.(:ok, "test window open, client area #{w}x#{h} at #{x},#{y}")
      :ok
    else
      {:error, message} when is_binary(message) -> fail(log, message)
      :error -> :error
    end
  end

  defp check(:capture, log) do
    with {:ok, bin, w, h} <- grab(log) do
      log.(:info, "captured #{w}x#{h}")
      pixel_check(bin, w, h, @red, "red", log)
    end
  end

  defp check(:input, log) do
    case Native.init_input(WinProbe.title(), "") do
      :ok ->
        log.(:ok, "input ready through #{Native.input_backend()}")
        :ok

      {:error, reason} ->
        fail(log, "input refused: #{inspect(reason)}; open the test window first")
    end
  end

  defp check(:cursor, log) do
    case Native.get_cursor_pos() do
      {:ok, x, y} ->
        log.(:ok, "cursor readback works, cursor at #{x},#{y}")
        :ok

      {:error, reason} ->
        fail(log, "no cursor readback: #{inspect(reason)}")
    end
  end

  defp check(:click, log) do
    with {:ok, {x, y, w, h}} <- target_rect(log),
         :ok <- ensure_input(log) do
      goal = {x + div(w, 2), y + div(h, 2)}
      mark = byte_size(read(target_log()))
      log.(:info, "aiming at #{inspect(goal)}")

      with :ok <- move_to(goal, log),
           Process.sleep(200),
           :ok <- tap_button(@btn_left, 60) do
        Process.sleep(400)
        events = new_events(target_log(), mark)

        case Enum.filter(events, &(&1.kind == "wm" and &1.f["msg"] == "LDOWN")) do
          [%{f: f} | _] ->
            log.(:ok, "click landed at window #{f["x"]},#{f["y"]}, expected about #{div(w, 2)},#{div(h, 2)}")
            log.(:info, "Windows reported the click as message source device #{f["dev"]}, origin #{f["origin"]} (1 hardware, 2 injected)")

            with {:ok, bin, cw, ch} <- grab(log), do: pixel_check(bin, cw, ch, @green, "green", log)

          [] ->
            fail(log, "the test window saw no click")
        end
      else
        {:error, reason} -> fail(log, "input refused: #{inspect(reason)}")
      end
    else
      _ -> :error
    end
  end

  defp check(:keyboard, log) do
    with {:ok, _rect} <- target_rect(log),
         :ok <- ensure_input(log) do
      mark = byte_size(read(target_log()))

      case tap_key(@key_a, 40) do
        :ok ->
          Process.sleep(400)
          events = new_events(target_log(), mark)

          if Enum.any?(events, &(&1.kind == "wm" and &1.f["msg"] == "KEYDOWN" and &1.f["wp"] == "41")) do
            log.(:ok, "the test window received A")
            :ok
          else
            fail(log, "the test window saw no A key press")
          end

        {:error, reason} ->
          fail(log, "input refused: #{inspect(reason)}; click the test window first so it has focus")
      end
    else
      _ -> :error
    end
  end

  defp check(:close, log) do
    stop_probe(target_log())
    log.(:ok, "test window closed")
    :ok
  end

  defp check(:probe_injected, log), do: run_probe(:injected, @injected_probe_duration_s, log)
  defp check(:probe_hardware, log), do: run_probe(:hardware, @hardware_probe_duration_s, log)

  defp run_probe(mode, duration, log) do
    stamp = Calendar.strftime(NaiveDateTime.local_now(), "%Y%m%d-%H%M%S")
    out = Path.join(probe_dir(), "winprobe-windows-#{mode}-#{stamp}.log")
    stop_probe(target_log())

    with :ok <- ensure_probe(log),
         :ok <- launch_probe(out, duration),
         :ok <- wait_for(fn -> WinProbe.ready?(read(out)) end, 10_000, "the probe never reported ready"),
         {:ok, {x, y, w, h} = rect} <- wait_for_rect(5_000) do
      log.(:ok, "probe running, client area #{w}x#{h} at #{x},#{y}, raw event log #{out}")
      drive_probe(mode, rect, duration, log)

      case wait_for(fn -> WinProbe.finished?(read(out)) end, 15_000 + duration * 1_000, "the probe did not finish") do
        :ok ->
          WinProbe.report(WinProbe.parse(read(out)), mode, log)

        {:error, message} ->
          log.(:error, message)
          stop_probe(out)
          WinProbe.report(WinProbe.parse(read(out)), mode, log)
          :error
      end
    else
      {:error, message} when is_binary(message) -> fail(log, message)
      :error -> :error
    end
  end

  defp drive_probe(:injected, {x, y, w, h}, _duration, log) do
    center = {x + div(w, 2), y + div(h, 2)}

    with :ok <- Native.init_input(WinProbe.title(), ""),
         :ok <- move_to(center, log) do
      log.(:info, "input connected through #{Native.input_backend()}")
      Process.sleep(500)
      sweep(center, log)
      Process.sleep(200)

      results = [
        tap_button(@btn_left, 60),
        tap_button(@btn_left, 20),
        tap_button(@btn_right, 40),
        Native.scroll(0, 120),
        tap_key(@key_a, 40),
        tap_key(@key_a, 120),
        tap_key(@key_esc, 40)
      ]

      case Enum.reject(results, &(&1 == :ok)) do
        [] -> log.(:info, "sent a relative sweep, an absolute sweep, 2 left clicks, 1 right click, 1 wheel notch, 2 presses of A and Escape")
        refused -> log.(:error, "some input was refused: #{inspect(Enum.uniq(refused))}")
      end
    else
      {:error, reason} -> log.(:error, "input refused: #{inspect(reason)}")
    end
  end

  defp drive_probe(:hardware, _rect, duration, log) do
    log.(:info, "use your real mouse and keyboard on the probe window now: move around, left and right click, scroll, type A; press Escape to finish, or it closes after #{duration} s")
  end

  defp sweep({cx, cy}, log) do
    sweep_steps("relative", log, fn _ -> Native.move_relative(2.0, 1.0) end)
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

  defp move_to({gx, gy}, log) do
    case Native.move_absolute(gx * 1.0, gy * 1.0) do
      :ok ->
        :ok

      {:error, reason} = error ->
        log.(:info, "absolute move refused or failed: #{inspect(reason)}")
        error
    end
  end

  defp tap_button(code, hold_ms) do
    with :ok <- Native.button_event(code, true) do
      Process.sleep(hold_ms)
      result = Native.button_event(code, false)
      Process.sleep(150)
      result
    end
  end

  defp tap_key(code, hold_ms) do
    with :ok <- Native.key_event(code, true) do
      Process.sleep(hold_ms)
      result = Native.key_event(code, false)
      Process.sleep(150)
      result
    end
  end

  defp ensure_input(log) do
    case Native.init_input(WinProbe.title(), "") do
      :ok -> :ok
      {:error, reason} -> fail(log, "input refused: #{inspect(reason)}")
    end
  end

  defp game_window_verdict(title, lines, log) do
    case Regex.run(~r/client area (\d+)x(\d+)/, Enum.join(lines, "\n")) do
      [_, "1920", "1080"] ->
        log.(:ok, "#{title} client area is 1920x1080")
        :ok

      [_, w, h] ->
        fail(log, "#{title} client area is #{w}x#{h}, not 1920x1080; run the resize check")

      nil ->
        fail(log, "could not read the client area of #{title}")
    end
  end

  defp save_game_capture(title, log) do
    path = Path.join(Data.screenshots_dir(), "windows-check-game.png")

    with {:ok, bin, w, h} <- Native.grab_frame(title),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Native.save_png(bin, w, h, path) do
      log.(:info, "saved a #{w}x#{h} capture of the game to #{path}")
    else
      other -> log.(:error, "could not save a capture of the game: #{inspect(other)}")
    end
  end

  defp pixel_check(bin, w, h, expected, name, log) do
    pixel = center_pixel(bin, w, h)
    ok? = pixel == expected
    log.(if(ok?, do: :ok, else: :error), "center pixel (B,G,R) = #{inspect(pixel)}, expected #{inspect(expected)} (#{name})")
    if ok?, do: :ok, else: :error
  end

  defp center_pixel(bin, w, h) do
    offset = (div(h, 2) * w + div(w, 2)) * 3
    <<b, g, r>> = binary_part(bin, offset, 3)
    {b, g, r}
  end

  defp grab(log) do
    case Native.grab_frame(WinProbe.title()) do
      {:ok, bin, w, h} -> {:ok, bin, w, h}
      {:error, reason} -> fail(log, "capture failed: #{inspect(reason)}")
    end
  end

  defp target_rect(log) do
    case Native.get_window_rect(WinProbe.title()) do
      {:ok, x, y, w, h} -> {:ok, {x, y, w, h}}
      {:error, reason} -> fail(log, "test window not found (#{inspect(reason)}); run \"Open test window\" first")
    end
  end

  defp wait_for_rect(timeout_ms) do
    with :ok <- wait_for(fn -> match?({:ok, _, _, _, _}, Native.get_window_rect(WinProbe.title())) end, timeout_ms, "the test window opened but could not be found"),
         {:ok, x, y, w, h} <- Native.get_window_rect(WinProbe.title()) do
      {:ok, {x, y, w, h}}
    end
  end

  defp new_events(path, mark) do
    text = read(path)
    if byte_size(text) > mark, do: WinProbe.parse(binary_part(text, mark, byte_size(text) - mark)), else: []
  end

  defp ensure_probe(log) do
    cond do
      probe_fresh?() ->
        log.(:ok, "test window is built: #{probe_exe()}")
        :ok

      zig = zig() ->
        File.mkdir_p!(probe_dir())
        args = ~w(cc -target x86_64-windows-gnu -O2 -s -Wall -Wl,--subsystem,windows -o) ++ [probe_exe(), WinProbe.source_path()] ++ ~w(-luser32 -lkernel32 -lgdi32)
        log.(:info, "building the test window with #{zig}")

        case System.cmd(zig, args, stderr_to_stdout: true) do
          {_, 0} ->
            log.(:ok, "built #{probe_exe()}")
            :ok

          {out, code} ->
            fail(log, "zig cc exited #{code}: #{String.slice(out, 0, 800)}")
        end

      true ->
        fail(log, "zig is not installed; install it with: winget install zig.zig")
    end
  end

  defp probe_fresh? do
    with {:ok, %{mtime: built}} <- File.stat(probe_exe()),
         {:ok, %{mtime: source}} <- File.stat(WinProbe.source_path()) do
      built >= source
    else
      _ -> false
    end
  end

  defp zig do
    links = Path.join([System.get_env("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Links", "zig.exe"])
    packages = Path.wildcard(Path.join([System.get_env("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages", "zig.zig_*", "*", "zig.exe"]))

    System.find_executable("zig") || Enum.find([links | packages], &File.regular?/1)
  end

  defp launch_probe(out, duration) do
    File.rm(out)
    exe = String.replace(probe_exe(), "/", "\\")

    case System.cmd("cmd", ["/c", "start", "", exe, "--out=" <> out, "--duration=#{duration}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {text, code} -> {:error, "could not start the test window (#{code}): #{text}"}
    end
  end

  defp stop_probe(out) do
    case Regex.run(~r/^start t=\d+ pid=(\d+)/m, read(out)) do
      [_, pid] -> System.cmd("taskkill", ["/PID", pid, "/F"], stderr_to_stdout: true)
      nil -> :ok
    end

    :ok
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
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

  defp fail(log, text) do
    log.(:error, text)
    :error
  end

  defp game_title, do: Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")
  defp probe_dir, do: Path.join(Data.paths().root, "winprobe")
  defp probe_exe, do: Path.join(probe_dir(), "winprobe.exe")
  defp target_log, do: Path.join(probe_dir(), "windows-check-target.log")
end
