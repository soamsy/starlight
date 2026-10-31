defmodule StarlightBot.EnkephalinSchedule.Server do
  use GenServer
  alias StarlightBot.{AppSettings, EnkephalinSchedule, GameWindow, LogStore, Scheduler}
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Navigation.Navigator

  @tick_ms 30_000
  @attempt_backoff_ms 10 * 60_000
  @ready_poll_ms 5_000
  @charge_start_confirm_ms 5_000

  defstruct next_attempt_at: nil, task: nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, maybe_charge(state)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    log_result(result)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    LogStore.append(:error, "enkephalin scheduler: crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_charge(%{task: %Task{}} = state), do: state

  defp maybe_charge(state) do
    now = Scheduler.local_now()
    settings = EnkephalinSchedule.get_settings()

    with true <- settings.enabled,
         true <- EnkephalinSchedule.due?(now, settings),
         false <- backing_off?(state),
         true <- runners_idle?(),
         {:ok, end_at} <- window_end(now, settings),
         true <- window_ready?(settings) do
      LogStore.append(:info, "enkephalin scheduler: starting a charge")
      task = Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn -> charge(settings, end_at) end)
      %{state | task: task, next_attempt_at: System.monotonic_time(:millisecond) + @attempt_backoff_ms}
    else
      _ -> state
    end
  end

  defp window_end(now, settings) do
    case EnkephalinSchedule.window_end(now, settings) do
      nil -> :error
      end_at -> {:ok, end_at}
    end
  end

  defp window_ready?(settings), do: match?({:ok, _}, GameWindow.rect()) or settings.launch_mode != "none"

  defp charge(settings, end_at) do
    with {:ok, rect} <- ensure_window(settings, end_at),
         :ok <- ensure_aspect(rect, settings.steam_app_id),
         :ok <- await_game_ready(end_at),
         :ok <- start_charge() do
      :started
    end
  end

  defp ensure_window(settings, end_at) do
    case GameWindow.rect() do
      {:ok, rect} ->
        {:ok, rect}

      {:error, _} ->
        LogStore.append(:info, "enkephalin scheduler: Limbus isn't open, launching it (#{launch_label(settings)})")
        timeout_ms = min(settings.launch_timeout_s * 1000, max(ms_until(end_at), 0))

        with :ok <- GameWindow.launch(settings),
             {:ok, rect} <- GameWindow.await_window(timeout_ms) do
          {:ok, rect}
        else
          {:error, reason} -> {:error, "launching Limbus failed: #{inspect(reason)}"}
        end
    end
  end

  defp ensure_aspect(rect, steam_app_id) do
    if GameWindow.aspect_ok?(rect) do
      :ok
    else
      case GameWindow.fix_aspect(steam_app_id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "couldn't fix the aspect ratio: #{inspect(reason)}"}
      end
    end
  end

  defp await_game_ready(end_at) do
    case Engine.localize() do
      {:ok, _screen} ->
        :ok

      :unknown ->
        if ms_until(end_at) > @ready_poll_ms do
          Process.sleep(@ready_poll_ms)
          await_game_ready(end_at)
        else
          {:error, "the game never reached a recognized screen before the window ended"}
        end
    end
  end

  defp start_charge do
    Navigator.charge_enkephalin(AppSettings.enkephalin_convert_count())
    Process.sleep(@charge_start_confirm_ms)

    case Navigator.status() do
      %{run_kind: kind} when kind != nil -> :ok
      _ -> {:error, "the navigator didn't start the charge, check the runner log"}
    end
  end

  defp log_result(:started), do: :ok
  defp log_result({:error, text}), do: LogStore.append(:error, "enkephalin scheduler: #{text}")

  defp backing_off?(%{next_attempt_at: nil}), do: false
  defp backing_off?(%{next_attempt_at: at}), do: System.monotonic_time(:millisecond) < at

  defp runners_idle?, do: navigator_idle?() and scheduler_idle?()

  defp navigator_idle? do
    case Navigator.status() do
      %{phase: :idle, run_kind: nil} -> true
      _ -> false
    end
  end

  defp scheduler_idle? do
    case GenServer.whereis(Scheduler.Server) do
      nil -> true
      _pid -> Scheduler.Server.status().activity == nil
    end
  end

  defp ms_until(end_at), do: NaiveDateTime.diff(end_at, Scheduler.local_now(), :millisecond)

  defp launch_label(%{launch_mode: "steam", steam_app_id: id}), do: "steam app #{id}"
  defp launch_label(%{launch_mode: "exe", exe_path: path}), do: path
end
