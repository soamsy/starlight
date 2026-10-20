defmodule StarlightBot.Scheduler.Server do
  use GenServer
  alias StarlightBot.{GameWindow, LogStore, Scheduler}
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Navigation.Navigator

  @tick_ms 30_000
  @retry_after_failure_ms 5 * 60_000
  @ready_poll_ms 5_000
  @run_start_confirm_ms 5_000
  @max_events 50

  defstruct settings: nil, task: nil, activity: nil, retry_after: nil, events: []

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  def test_launch, do: GenServer.cast(__MODULE__, :test_launch)

  def test_fix_aspect, do: GenServer.cast(__MODULE__, :test_fix_aspect)

  def cancel_test_launch, do: GenServer.cast(__MODULE__, :cancel_test_launch)

  @impl true
  def init(_opts) do
    Scheduler.subscribe()
    send(self(), :tick)
    {:ok, %__MODULE__{settings: Scheduler.get_settings()}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, external(state), state}

  @impl true
  def handle_cast(:test_launch, %{task: nil} = state) do
    settings = state.settings
    {:noreply, start_task(state, "testing launch", fn -> test_launch_task(settings) end)}
  end

  def handle_cast(:test_fix_aspect, %{task: nil} = state) do
    app_id = state.settings.steam_app_id
    {:noreply, start_task(state, "testing aspect ratio fix", fn -> fix_aspect_task(app_id) end)}
  end

  def handle_cast(:cancel_test_launch, %{task: %Task{} = task, activity: "testing launch"} = state) do
    Task.shutdown(task, :brutal_kill)
    state = %{state | task: nil, activity: nil} |> add_event(:info, "launch test cancelled")
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:cancel_test_launch, state), do: {:noreply, state}

  def handle_cast(_test, state) do
    {:noreply, add_event(state, :error, "busy #{state.activity}, try again when it finishes")}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, maybe_fire(state)}
  end

  def handle_info({:scheduler_settings, settings}, state) do
    state = %{state | settings: settings, retry_after: nil}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:scheduler_event, kind, text}, state), do: {:noreply, add_event(state, kind, text)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_task(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish_task(state, {:error, "crashed: #{inspect(reason)}"})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_fire(%{task: %Task{}} = state), do: state
  defp maybe_fire(%{settings: %{enabled: false}} = state), do: state

  defp maybe_fire(state) do
    with {:due, date, end_at} <- Scheduler.due(Scheduler.local_now(), state.settings),
         false <- retry_pending?(state),
         true <- navigator_idle?(),
         action when action != nil <- Scheduler.runner_action(state.settings) do
      settings = state.settings
      start_task(state, "starting the scheduled #{runner_label(settings.runner)} run", fn -> fire_task(settings, action, date, end_at) end)
    else
      _ -> state
    end
  end

  defp retry_pending?(%{retry_after: nil}), do: false
  defp retry_pending?(%{retry_after: at}), do: System.monotonic_time(:millisecond) < at

  defp navigator_idle? do
    case Navigator.status() do
      %{phase: :idle, run_kind: nil} -> true
      _ -> false
    end
  end

  defp start_task(state, activity, fun) do
    task = Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fun)
    state = %{state | task: task, activity: activity} |> add_event(:info, activity)
    broadcast(state)
    state
  end

  defp finish_task(state, result) do
    state = %{state | task: nil, activity: nil}

    state =
      case result do
        {:fired, date, text} ->
          Scheduler.mark_fired(date)
          add_event(%{state | retry_after: nil}, :ok, text)

        {:ok, text} ->
          add_event(state, :ok, text)

        {:wait, text} ->
          add_event(state, :info, text)

        {:retry_later, text, after_ms} ->
          add_event(%{state | retry_after: System.monotonic_time(:millisecond) + after_ms}, :error, text)

        {:error, text} ->
          add_event(state, :error, text)
      end

    broadcast(state)
    state
  end

  defp fire_task(settings, action, date, end_at) do
    with {:ok, rect, launched?} <- ensure_window(settings, end_at),
         :ok <- ensure_aspect(rect, settings.steam_app_id),
         :ok <- if(launched?, do: await_game_ready(end_at), else: :ok),
         :ok <- start_run(action) do
      {:fired, date, "started the scheduled #{runner_label(settings.runner)} run"}
    end
  end

  defp ensure_window(settings, end_at) do
    case GameWindow.rect() do
      {:ok, rect} ->
        {:ok, rect, false}

      {:error, _} when settings.launch_mode == "none" ->
        {:wait, "Limbus isn't open and launching is off, waiting for it"}

      {:error, _} ->
        notify(:info, "Limbus isn't open, launching it (#{launch_label(settings)})")
        timeout_ms = min(settings.launch_timeout_s * 1000, max(ms_until(end_at), 0))

        with :ok <- GameWindow.launch(settings),
             {:ok, rect} <- GameWindow.await_window(timeout_ms) do
          notify(:info, "Limbus window appeared at #{inspect(rect)}")
          {:ok, rect, true}
        else
          {:error, reason} ->
            {:retry_later, "launching Limbus failed: #{inspect(reason)}", settings.launch_timeout_s * 1000}
        end
    end
  end

  defp ensure_aspect(rect, steam_app_id) do
    if GameWindow.aspect_ok?(rect) do
      :ok
    else
      notify(:info, "Limbus window is #{size_label(rect)}, not 16:9, resizing it to 1920x1080 in KWin")

      case GameWindow.fix_aspect(steam_app_id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:retry_later, "couldn't fix the aspect ratio: #{inspect(reason)}", @retry_after_failure_ms}
      end
    end
  end

  defp await_game_ready(end_at) do
    case Engine.localize() do
      {:ok, screen} ->
        notify(:info, "game is up on #{screen}")
        :ok

      :unknown ->
        if ms_until(end_at) > @ready_poll_ms do
          Process.sleep(@ready_poll_ms)
          await_game_ready(end_at)
        else
          {:retry_later, "the game never reached a recognized screen before the window ended", @retry_after_failure_ms}
        end
    end
  end

  defp start_run({:luxcavation_then_mirror_dungeon, lux, md}) do
    request_run(lux)
    Navigator.queue_after_run(md)
    confirm_run_started()
  end

  defp start_run(action) do
    request_run(action)
    confirm_run_started()
  end

  defp request_run({:run_mirror_dungeon, picks, run_count, config}), do: Navigator.run_mirror_dungeon(picks, run_count, config)

  defp request_run({:run_luxcavation, team, exp_c, exp_r, thread_c, thread_r, collect_xp?, collect_enkephalin?, convert}),
    do: Navigator.run_luxcavation(team, exp_c, exp_r, thread_c, thread_r, collect_xp?, collect_enkephalin?, convert)

  defp confirm_run_started do
    Process.sleep(@run_start_confirm_ms)

    case Navigator.status() do
      %{run_kind: kind} when kind != nil -> :ok
      _ -> {:retry_later, "the navigator didn't start the run, check the runner log", @retry_after_failure_ms}
    end
  end

  defp test_launch_task(settings) do
    case GameWindow.rect() do
      {:ok, rect} ->
        {:ok, "Limbus is already open (#{size_label(rect)}, aspect #{aspect_label(rect)})"}

      {:error, _} ->
        notify(:info, "launching Limbus (#{launch_label(settings)}), waiting up to #{settings.launch_timeout_s}s for its window")

        with :ok <- GameWindow.launch(settings),
             {:ok, rect} <- GameWindow.await_window(settings.launch_timeout_s * 1000) do
          {:ok, "Limbus window appeared (#{size_label(rect)}, aspect #{aspect_label(rect)})"}
        else
          {:error, reason} -> {:error, "launch test failed: #{inspect(reason)}"}
        end
    end
  end

  defp fix_aspect_task(steam_app_id) do
    case GameWindow.fix_aspect(steam_app_id) do
      {:ok, %{before: before, after: after_rect, buses: buses}} ->
        {:ok, "resized via #{Enum.join(buses, " + ")} KWin: #{size_label(before)} -> #{size_label(after_rect)}"}

      {:error, {:resize_ignored, %{before: before, after: after_rect, buses: buses}}} ->
        {:error, "ran the resize script on #{Enum.join(buses, " + ")} KWin but the window stayed #{size_label(after_rect)} (was #{size_label(before)})"}

      {:error, reason} ->
        {:error, "aspect fix failed: #{inspect(reason)}"}
    end
  end

  defp notify(kind, text), do: send(__MODULE__, {:scheduler_event, kind, text})

  defp add_event(%{events: [%{text: text} | _]} = state, _kind, text), do: state

  defp add_event(state, kind, text) do
    LogStore.append(kind, "scheduler: #{text}")
    event = %{at: Scheduler.local_now(), kind: kind, text: text}
    state = %{state | events: Enum.take([event | state.events], @max_events)}
    broadcast(state)
    state
  end

  defp broadcast(state), do: Scheduler.broadcast({:scheduler_state, external(state)})

  defp external(state) do
    %{
      settings: state.settings,
      activity: state.activity,
      retry_after_ms: if(retry_pending?(state), do: state.retry_after - System.monotonic_time(:millisecond)),
      events: state.events
    }
  end

  defp ms_until(end_at), do: NaiveDateTime.diff(end_at, Scheduler.local_now(), :millisecond)

  def runner_label("luxcavation_then_mirror_dungeon"), do: "luxcavation then mirror dungeon"
  def runner_label("mirror_dungeon"), do: "mirror dungeon"
  def runner_label("luxcavation"), do: "luxcavation"

  defp launch_label(%{launch_mode: "steam", steam_app_id: id}), do: "steam app #{id}"
  defp launch_label(%{launch_mode: "exe", exe_path: path}), do: path

  defp size_label({_x, _y, w, h}), do: "#{w}x#{h}"

  defp aspect_label(rect), do: if(GameWindow.aspect_ok?(rect), do: "16:9", else: "not 16:9")
end
