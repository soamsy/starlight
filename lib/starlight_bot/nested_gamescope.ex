defmodule StarlightBot.NestedGamescope do
  alias StarlightBot.{AppSettings, LogStore}

  @width 1920
  @height 1080
  @ready_timeout_ms 20_000
  @poll_ms 100
  @ei_socket ~r/^gamescope-\d+-ei$/
  @cursor_flags []

  def spawn(backend, argv, extra_env \\ [], cwd \\ File.cwd!()) when backend in ["headless", "wayland"] do
    case System.find_executable("gamescope") do
      nil -> {:error, :gamescope_not_installed}
      gamescope -> start(gamescope, backend, argv, extra_env, cwd)
    end
  end

  defp start(gamescope, backend, argv, extra_env, cwd) do
    dir = state_dir()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    log_path = Path.join(dir, "gamescope.log")
    before = ei_sockets()
    [inner_w, inner_h] = String.split(AppSettings.gamescope_resolution(), "x")
    args = ["--backend", backend, "-w", inner_w, "-h", inner_h, "-W", "#{@width}", "-H", "#{@height}"] ++ @cursor_flags ++ extra_flags() ++ ["--"] ++ argv
    log("starting gamescope #{backend} at #{inner_w}x#{inner_h} inside #{@width}x#{@height}, its log is #{log_path}")
    log("spawning detached: #{Enum.join(args, " ")}")

    # WSI must stay off: with it on, MIT-SHM captures come back as black frames
    case System.cmd("sh", ["-c", ~s(setsid -f "$@" </dev/null >"$0" 2>&1), log_path, gamescope | args], stderr_to_stdout: true, env: backend_env(backend) ++ [{"ENABLE_GAMESCOPE_WSI", "0"} | extra_env], cd: cwd) do
      {_, 0} -> await_ei_socket(before, System.monotonic_time(:millisecond) + @ready_timeout_ms)
      {out, code} -> {:error, {:launch_failed, code, String.trim(out)}}
    end
  end

  defp state_dir, do: Path.join(System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!(), "starlight-nested")

  defp extra_flags, do: String.split(AppSettings.gamescope_flags())

  defp backend_env("headless"), do: [{"WAYLAND_DISPLAY", nil}]
  defp backend_env("wayland"), do: [{"gamescope_cursor_composite", "2"}]

  defp await_ei_socket(before, deadline) do
    case ei_sockets() -- before do
      [socket | _] ->
        log("gamescope up, input socket #{socket}")
        :ok

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :gamescope_timeout}
        else
          Process.sleep(@poll_ms)
          await_ei_socket(before, deadline)
        end
    end
  end

  defp ei_sockets do
    runtime = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()

    case File.ls(runtime) do
      {:ok, names} -> Enum.filter(names, &(Regex.match?(@ei_socket, &1) and live?(Path.join(runtime, &1))))
      {:error, _} -> []
    end
  end

  defp live?(path) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp log(text), do: LogStore.append(:info, "launch: " <> text)
end
