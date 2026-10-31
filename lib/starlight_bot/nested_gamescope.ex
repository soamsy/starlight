defmodule StarlightBot.NestedGamescope do
  alias StarlightBot.{LogStore, NestedKwin}

  @width 1920
  @height 1080
  @ready_timeout_ms 20_000
  @poll_ms 100
  @ei_socket ~r/^gamescope-\d+-ei$/

  def available?, do: System.find_executable("gamescope") != nil

  def spawn(argv, extra_env \\ [], cwd \\ File.cwd!()) do
    case System.find_executable("gamescope") do
      nil -> {:error, :gamescope_not_installed}
      gamescope -> start(gamescope, argv, extra_env, cwd)
    end
  end

  defp start(gamescope, argv, extra_env, cwd) do
    dir = NestedKwin.state_dir()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    log_path = Path.join(dir, "gamescope.log")
    before = ei_sockets()
    args = ["--backend", "headless", "-w", "#{@width}", "-h", "#{@height}", "-W", "#{@width}", "-H", "#{@height}", "--"] ++ argv
    log("starting gamescope headless at #{@width}x#{@height}, its log is #{log_path}")
    log("spawning detached: #{Enum.join(args, " ")}")

    case System.cmd("sh", ["-c", ~s(setsid -f "$@" </dev/null >"$0" 2>&1), log_path, gamescope | args], stderr_to_stdout: true, env: [{"WAYLAND_DISPLAY", nil}, {"ENABLE_GAMESCOPE_WSI", "0"} | extra_env], cd: cwd) do
      {_, 0} -> await_ei_socket(before, System.monotonic_time(:millisecond) + @ready_timeout_ms)
      {out, code} -> {:error, {:launch_failed, code, String.trim(out)}}
    end
  end

  defp await_ei_socket(before, deadline) do
    case ei_sockets() -- before do
      [socket | _] ->
        System.put_env("STARLIGHT_EIS_SOCKET", socket)
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
    case File.ls(System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()) do
      {:ok, names} -> Enum.filter(names, &Regex.match?(@ei_socket, &1))
      {:error, _} -> []
    end
  end

  defp log(text), do: LogStore.append(:info, "launch: " <> text)
end
