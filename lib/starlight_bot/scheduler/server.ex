defmodule StarlightBot.Scheduler.Server do
  use GenServer
  alias StarlightBot.{DailyProgress, GameWindow, LogStore, Scheduler}
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Navigation.Navigator

  @tick_ms 30_000
  @retry_after_failure_ms 5 * 60_000
  @ready_poll_ms 5_000
  @run_start_confirm_ms 5_000
  @max_events 50
  @forced_window_s 2 * 3600

  defstruct settings: nil, task: nil, activity: nil, retry_after: nil, last_fire: nil, close_armed: false, events: []

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  def start_now, do: GenServer.cast(__MODULE__, :start_now)

  def cancel, do: GenServer.cast(__MODULE__, :cancel)

  @impl true
  def init(_opts) do
    Scheduler.subscribe()
    send(self(), :tick)
    {:ok, %__MODULE__{settings: Scheduler.get_settings()}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, external(state), state}

  @impl true
  def handle_cast(:start_now, state) do
    Scheduler.hold("clear")
    {:noreply, start_now_run(%{state | retry_after: nil, last_fire: nil})}
  end

  def handle_cast(:cancel, %{task: %Task{} = task} = state) do
    Scheduler.hold("1")
    Task.Supervisor.terminate_child(StarlightBot.TaskSupervisor, task.pid)
    Process.demonitor(task.ref, [:flush])
    Navigator.cancel()
    state = %{state | task: nil, activity: nil, retry_after: nil, last_fire: nil}
    {:noreply, add_event(state, :info, "canceled the scheduled run before it started, holding the schedulers for 1h")}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state |> forget_while_blocked() |> maybe_fire() |> maybe_close()}
  end

  def handle_info({:scheduler_settings, settings}, state) do
    state = %{state | settings: settings, retry_after: nil, last_fire: nil}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(:daily_progress, state), do: {:noreply, maybe_close(state)}

  def handle_info({:scheduler_event, kind, text}, state), do: {:noreply, add_event(state, kind, text)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_task(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish_task(state, {:error, "crashed: #{inspect(reason)}"})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp forget_while_blocked(state) do
    if Scheduler.blocked(), do: %{state | last_fire: nil, retry_after: nil}, else: state
  end

  defp maybe_fire(%{task: %Task{}} = state), do: state
  defp maybe_fire(%{settings: %{enabled: false}} = state), do: state

  defp maybe_fire(state) do
    with {:due, _date, end_at} <- Scheduler.due(Scheduler.local_now(), state.settings),
         remaining = DailyProgress.remaining(state.settings),
         true <- DailyProgress.pending?(remaining),
         nil <- Scheduler.blocked(),
         false <- retry_pending?(state),
         false <- Scheduler.busy?() do
      fire(state, remaining, end_at)
    else
      _ -> state
    end
  end

  defp maybe_close(%{task: nil, close_armed: true, settings: settings} = state) do
    if Scheduler.busy?() do
      state
    else
      state = %{state | close_armed: false}

      if Scheduler.close_after_goals?(settings, DailyProgress.remaining(settings), Navigator.status().last_run) do
        case GameWindow.close() do
          :ok -> add_event(state, :ok, "goals met, closed Limbus")
          {:error, reason} -> add_event(state, :error, "goals met, but closing Limbus failed: #{inspect(reason)}")
        end
      else
        state
      end
    end
  end

  defp maybe_close(state), do: state

  defp start_now_run(%{task: %Task{}} = state), do: state

  defp start_now_run(state) do
    remaining = DailyProgress.remaining(state.settings)

    cond do
      not DailyProgress.pending?(remaining) -> add_event(state, :info, "start now: today's targets are already done")
      Scheduler.busy?() -> add_event(state, :info, "start now: a run is already in progress or paused")
      true -> fire(state, remaining, NaiveDateTime.add(Scheduler.local_now(), @forced_window_s))
    end
  end

  defp fire(%{last_fire: remaining} = state, remaining, _end_at) do
    add_event(
      %{state | last_fire: nil, retry_after: System.monotonic_time(:millisecond) + @retry_after_failure_ms},
      :error,
      "the last scheduled run made no progress, trying again in #{div(@retry_after_failure_ms, 60_000)} min"
    )
  end

  defp fire(state, remaining, end_at) do
    settings = state.settings

    case Scheduler.runner_action(remaining) do
      nil ->
        add_event(state, :error, "the runner pages aren't set up for what's left today, can't start the scheduled run")

      action ->
        start_task(state, "starting the scheduled run (#{DailyProgress.remaining_label(remaining)})", fn -> fire_task(settings, action, remaining, end_at) end)
    end
  end

  defp retry_pending?(%{retry_after: nil}), do: false
  defp retry_pending?(%{retry_after: at}), do: System.monotonic_time(:millisecond) < at

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
        {:fired, remaining, text} ->
          add_event(%{state | retry_after: nil, last_fire: remaining, close_armed: true}, :ok, text)

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

  defp fire_task(settings, action, remaining, end_at) do
    with {:ok, rect, launched?} <- ensure_window(settings, end_at),
         :ok <- ensure_aspect(rect, settings.steam_app_id),
         :ok <- if(launched?, do: await_game_ready(end_at), else: :ok),
         :ok <- start_run(action) do
      {:fired, remaining, "started the scheduled run (#{DailyProgress.remaining_label(remaining)})"}
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

  defp request_run(action), do: Navigator.run_scheduled(action)

  defp confirm_run_started do
    Process.sleep(@run_start_confirm_ms)

    case Navigator.status() do
      %{run_kind: kind} when kind != nil -> :ok
      _ -> {:retry_later, "the navigator didn't start the run, check the runner log", @retry_after_failure_ms}
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
      close_armed: state.close_armed,
      retry_after_ms: if(retry_pending?(state), do: state.retry_after - System.monotonic_time(:millisecond)),
      events: state.events
    }
  end

  defp ms_until(end_at), do: NaiveDateTime.diff(end_at, Scheduler.local_now(), :millisecond)

  defp launch_label(%{launch_mode: "steam", steam_app_id: id}), do: "steam app #{id}"
  defp launch_label(%{launch_mode: "exe", exe_path: path}), do: path

  defp size_label({_x, _y, w, h}), do: "#{w}x#{h}"
end
