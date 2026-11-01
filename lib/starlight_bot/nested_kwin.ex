defmodule StarlightBot.NestedKwin do
  alias StarlightBot.LogStore

  @width 1920
  @height 1080
  @socket "starlight-0"
  @frame_lock_plugin "starlight-frame-lock"
  @ready_timeout_ms 15_000
  @poll_ms 100
  @env_keys ~w(DISPLAY WAYLAND_DISPLAY LIBEI_SOCKET XAUTHORITY DBUS_SESSION_BUS_ADDRESS)

  @supervisor """
  state=$1
  bus=$state/bus
  dbus_pid=$(dbus-daemon --session --address="unix:path=$bus" --fork --print-pid) || exit 1
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
  mkdir -p "$state/config"
  XDG_CONFIG_HOME="$state/config" kwin_wayland --xwayland --no-lockscreen --width #{@width} --height #{@height} --socket #{@socket} --exit-with-session "$state/inner.sh" 2> "$state/kwin.log" &
  kwin_pid=$!
  echo $kwin_pid > "$state/kwin.pid"
  wait $kwin_pid
  kill $dbus_pid 2>/dev/null
  rm -f "$bus" "$state/kwin.pid" "$state/session.env"
  """

  @inner """
  #!/bin/sh
  state=$(dirname "$0")
  env | grep -E '^(#{Enum.join(@env_keys, "|")})=' > "$state/session.env.tmp"
  mv "$state/session.env.tmp" "$state/session.env"
  exec sleep infinity
  """

  def state_dir do
    Path.join(System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!(), "starlight-nested")
  end

  def ensure do
    case pid() do
      {:ok, pid} ->
        log("reusing nested kwin pid #{pid}")
        {:ok, pid}

      :error ->
        log("no nested kwin running, starting one")
        start()
    end
  end

  def pid do
    with {:ok, text} <- File.read(path("kwin.pid")),
         {pid, _} <- Integer.parse(String.trim(text)),
         true <- File.exists?("/proc/#{pid}") do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  def env do
    case File.read(path("session.env")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), [k, v] <- [String.split(line, "=", parts: 2)], do: {k, v}

      {:error, _} ->
        []
    end
  end

  def spawn(argv, extra_env \\ [], cwd \\ File.cwd!()) do
    {:ok, kwin_pid} = pid()
    nested_env = env()
    env = nested_env ++ extra_env ++ [{"STARLIGHT_KWIN_PID", to_string(kwin_pid)}]
    log("spawning detached, kwin pid #{kwin_pid} is killed when it exits: #{Enum.join(argv, " ")}")

    case System.cmd("sh", ["-c", ~s(setsid -f sh -c '"$@"; kill "$STARLIGHT_KWIN_PID"' sh "$@" </dev/null >/dev/null 2>&1), "sh" | argv], stderr_to_stdout: true, env: env, cd: cwd) do
      {_, 0} ->
        log("spawned")
        :ok

      {out, code} ->
        {:error, {:launch_failed, code, String.trim(out)}}
    end
  end

  def lock_frame(kwin_pid) do
    File.write!(path("frame_lock.js"), frame_lock_script(kwin_pid))

    case gdbus("unloadScript", [@frame_lock_plugin]) do
      {:error, reason} ->
        if String.contains?(reason, "ServiceUnknown") do
          log("host compositor is not KWin, skipping the frame lock")
          :ok
        else
          run_frame_lock(kwin_pid)
        end

      {:ok, _} ->
        run_frame_lock(kwin_pid)
    end
  end

  defp run_frame_lock(kwin_pid) do
    with {:ok, out} <- gdbus("loadScript", [path("frame_lock.js"), @frame_lock_plugin]),
         [_, id] <- Regex.run(~r/\((\d+),\)/, out),
         {:ok, _} <- gdbus_object("/Scripting/Script#{id}", "org.kde.kwin.Script.run", []) do
      log("frame lock script #{id} running in host kwin, holding pid #{kwin_pid} window at #{@width}x#{@height} client area")
      :ok
    else
      {:error, reason} -> {:error, {:frame_lock_failed, reason}}
      other -> {:error, {:frame_lock_failed, other}}
    end
  end

  defp start do
    dir = state_dir()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    Enum.each(~w(bus kwin.pid session.env session.env.tmp), &File.rm(path(&1)))
    log("state dir #{dir}, kwin log #{path("kwin.log")}")
    File.write!(path("inner.sh"), @inner)
    File.chmod!(path("inner.sh"), 0o700)

    case System.cmd("sh", ["-c", ~s(setsid -f "$@" </dev/null >/dev/null 2>&1), "sh", "sh", "-c", @supervisor, "sh", dir], stderr_to_stdout: true) do
      {_, 0} -> await_ready(System.monotonic_time(:millisecond) + @ready_timeout_ms)
      {out, code} -> {:error, {:nested_kwin_failed, code, String.trim(out)}}
    end
  end

  defp await_ready(deadline) do
    with true <- File.exists?(path("session.env")),
         {:ok, pid} <- pid() do
      log("nested kwin up, pid #{pid}, socket #{@socket}, output #{@width}x#{@height}")
      {:ok, pid}
    else
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :nested_kwin_timeout}
        else
          Process.sleep(@poll_ms)
          await_ready(deadline)
        end
    end
  end

  defp gdbus(method, args), do: gdbus_object("/Scripting", "org.kde.kwin.Scripting." <> method, args)

  defp gdbus_object(object_path, method, args) do
    argv = ["call", "--session", "--dest", "org.kde.KWin", "--object-path", object_path, "--method", method] ++ args

    case System.cmd("gdbus", argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp log(text), do: LogStore.append(:info, "launch: " <> text)

  defp path(name), do: Path.join(state_dir(), name)

  defp frame_lock_script(kwin_pid) do
    """
    let fixing = false;
    function lock(w) {
      if (w.pid !== #{kwin_pid}) return;
      const apply = () => {
        if (fixing || w.fullScreen) return;
        const f = w.frameGeometry;
        const c = w.clientGeometry;
        const width = #{@width} + (f.width - c.width);
        const height = #{@height} + (f.height - c.height);
        if (f.width === width && f.height === height) return;
        fixing = true;
        w.frameGeometry = {x: f.x, y: f.y, width: width, height: height};
        fixing = false;
      };
      w.frameGeometryChanged.connect(apply);
      apply();
    }
    workspace.windowList().forEach(lock);
    workspace.windowAdded.connect(lock);
    """
  end
end
