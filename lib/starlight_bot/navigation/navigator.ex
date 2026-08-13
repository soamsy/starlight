defmodule StarlightBot.Navigation.Navigator do
  use GenServer
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.{Catalog, Runner}

  @topic "navigation"
  @log_limit 100

  defstruct [
    current_screen: nil,   # nil = never localized | :unknown | screen atom
    goal: nil,             # atom | nil
    phase: :idle,          # :idle | :localizing | :running | :paused
    log: [],               # newest first
    task_pid: nil
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def status, do: GenServer.call(__MODULE__, :status)

  def localize, do: GenServer.cast(__MODULE__, :localize)

  def run_to(screen_name), do: GenServer.cast(__MODULE__, {:run_to, screen_name})

  def run_action(action_name), do: GenServer.cast(__MODULE__, {:run_action, action_name})

  def run_transition(transition_name), do: GenServer.cast(__MODULE__, {:run_transition, transition_name})

  def run_script(script_name), do: GenServer.cast(__MODULE__, {:run_script, script_name})

  def run_luxcavation(team_id, exp_count, thread_count, collect_xp?),
    do: GenServer.cast(__MODULE__, {:run_luxcavation, team_id, exp_count, thread_count, collect_xp?})

  def run_mirror_dungeon(team_id, run_count, config),
    do: GenServer.cast(__MODULE__, {:run_mirror_dungeon, team_id, run_count, config})

  def select_team_on_screen(team_id),
    do: GenServer.cast(__MODULE__, {:select_team_on_screen, team_id})

  def claim_rewards(config), do: GenServer.cast(__MODULE__, {:claim_rewards, config})

  def cancel, do: GenServer.cast(__MODULE__, :cancel)

  def resume_luxcavation, do: GenServer.cast(__MODULE__, :resume_luxcavation)

  def resume_mirror_dungeon, do: GenServer.cast(__MODULE__, :resume_mirror_dungeon)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, external(state), state}
  end

  @impl true
  def handle_cast(:localize, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Localizing…")
    me = self()
    screens = Catalog.all_screens()

    pid =
      Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
        result = Runner.check_screens(screens)
        send(me, {:nav_result, :localize, result})
      end).pid

    state = %{state | phase: :localizing, goal: nil, task_pid: pid}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_to, goal}, state) do
    from = state.current_screen

    cond do
      from == goal ->
        state = add_log(state, :ok, "Already at #{goal}")
        broadcast(state)
        {:noreply, state}

      is_nil(from) or from == :unknown ->
        state = add_log(state, :error, "Cannot navigate: current screen unknown. Localize first.")
        broadcast(state)
        {:noreply, state}

      true ->
        case Catalog.plan_path(from, goal) do
          {:error, :no_path} ->
            state = add_log(state, :error, "No path from #{from} to #{goal}")
            broadcast(state)
            {:noreply, state}

          {:ok, transitions} ->
            state = cancel_running(state)
            state = add_log(state, :info, "Planning: #{from} → #{goal} (#{length(transitions)} step(s))")
            me = self()

            pid =
              Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
                ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
                result = Runner.run_plan(transitions, ctx)
                send(me, {:nav_result, :run_to, result})
              end).pid

            state = %{state | phase: :running, goal: goal, task_pid: pid}
            broadcast(state)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:run_action, action_name}, state) do
    from = state.current_screen

    cond do
      is_nil(from) or from == :unknown ->
        state = add_log(state, :error, "Cannot run action: current screen unknown. Localize first.")
        broadcast(state)
        {:noreply, state}

      true ->
        case Catalog.find_action(from, action_name) do
          nil ->
            state = add_log(state, :error, "No action #{action_name} on #{from}")
            broadcast(state)
            {:noreply, state}

          action ->
            state = cancel_running(state)
            state = add_log(state, :info, "Running action: #{action_name}")
            me = self()

            pid =
              Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
                ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
                result = Runner.run_action(from, action, ctx)
                send(me, {:nav_result, :run_action, result})
              end).pid

            state = %{state | phase: :running, goal: nil, task_pid: pid}
            broadcast(state)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:run_transition, transition_name}, state) do
    from = state.current_screen

    cond do
      is_nil(from) or from == :unknown ->
        state = add_log(state, :error, "Cannot navigate: current screen unknown. Localize first.")
        broadcast(state)
        {:noreply, state}

      true ->
        case Catalog.find_transition(from, transition_name) do
          nil ->
            state = add_log(state, :error, "No transition #{transition_name} from #{from}")
            broadcast(state)
            {:noreply, state}

          transition ->
            state = cancel_running(state)
            state = add_log(state, :info, "Running transition: #{transition_name}")
            me = self()

            pid =
              Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
                ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
                result = Runner.run_plan([transition], ctx)
                send(me, {:nav_result, :run_to, result})
              end).pid

            state = %{state | phase: :running, goal: transition.to, task_pid: pid}
            broadcast(state)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:run_script, script_name}, state) do
    case StarlightBot.Automation.Scripts.find(script_name) do
      nil ->
        state = add_log(state, :error, "Unknown script: #{script_name}")
        broadcast(state)
        {:noreply, state}

      %{module: module, label: label} ->
        state = cancel_running(state)
        state = add_log(state, :info, "Running script: #{label}")
        me = self()

        pid =
          Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
            ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
            result = module.run(ctx)
            send(me, {:nav_result, :run_script, result})
          end).pid

        state = %{state | phase: :running, goal: nil, task_pid: pid}
        broadcast(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:run_luxcavation, team_id, exp_count, thread_count, collect_xp?}, state) do
    state = cancel_running(state)

    state =
      add_log(
        state,
        :info,
        "Running luxcavation: team=#{team_id} exp=#{exp_count} thread=#{thread_count} collect_xp=#{collect_xp?}"
      )

    me = self()

    pid =
      Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
        ctx =
          Ctx.new(
            on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end,
            on_pause: fn -> send(me, :nav_paused) end
          )

        result = StarlightBot.Automation.Scripts.LuxcavationRunner.run(team_id, exp_count, thread_count, collect_xp?, ctx)
        send(me, {:nav_result, :run_script, result})
      end).pid

    state = %{state | phase: :running, goal: nil, task_pid: pid}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_mirror_dungeon, team_id, run_count, config}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Running mirror dungeon: team=#{team_id} runs=#{run_count} config=#{inspect(config)}")
    me = self()

    pid =
      Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
        ctx =
          Ctx.new(
            on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end,
            on_pause: fn -> send(me, :nav_paused) end
          )

        result = StarlightBot.Automation.Scripts.MirrorDungeonRunner.run(team_id, run_count, config, ctx)
        send(me, {:nav_result, :run_script, result})
      end).pid

    state = %{state | phase: :running, goal: nil, task_pid: pid}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_mirror_dungeon, %{phase: :paused, task_pid: pid} = state) when is_pid(pid) do
    send(pid, :resume_mirror_dungeon)
    state = %{state | phase: :running}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_mirror_dungeon, state), do: {:noreply, state}

  @impl true
  def handle_cast({:select_team_on_screen, team_id}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Selecting team #{team_id} on screen")
    me = self()

    pid =
      Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
        ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
        result = StarlightBot.Automation.Scripts.SelectTeamOnScreen.run(team_id, ctx)
        send(me, {:nav_result, :select_team_on_screen, result})
      end).pid

    state = %{state | phase: :running, goal: nil, task_pid: pid}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:claim_rewards, config}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Claiming rewards: #{inspect(config)}")
    me = self()

    pid =
      Task.Supervisor.async_nolink(StarlightBot.TaskSupervisor, fn ->
        ctx = Ctx.new(on_log: fn {kind, text} -> send(me, {:nav_log, kind, text}) end)
        result = StarlightBot.Automation.Scripts.ClaimRewards.run(config, ctx)
        send(me, {:nav_result, :claim_rewards, result})
      end).pid

    state = %{state | phase: :running, goal: nil, task_pid: pid}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:cancel, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Cancelled")
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_luxcavation, %{phase: :paused, task_pid: pid} = state) when is_pid(pid) do
    send(pid, :resume_luxcavation)
    state = %{state | phase: :running}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_luxcavation, state), do: {:noreply, state}

  @impl true
  def handle_info({:nav_result, :localize, result}, state) do
    state =
      case result do
        {:ok, screen} ->
          state
          |> Map.put(:current_screen, screen)
          |> Map.put(:phase, :idle)
          |> Map.put(:task_pid, nil)
          |> add_log(:ok, "On screen: #{screen}")

        :unknown ->
          state
          |> Map.put(:current_screen, :unknown)
          |> Map.put(:phase, :idle)
          |> Map.put(:task_pid, nil)
          |> add_log(:error, "Screen not recognized")
      end

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :run_to, result}, state) do
    state =
      case result do
        {:ok, arrived} ->
          state
          |> Map.put(:current_screen, arrived)
          |> Map.put(:phase, :idle)
          |> Map.put(:goal, nil)
          |> Map.put(:task_pid, nil)
          |> add_log(:ok, "Arrived at #{arrived}")

        {:error, reason} ->
          state
          |> Map.put(:phase, :idle)
          |> Map.put(:goal, nil)
          |> Map.put(:task_pid, nil)
          |> add_log(:error, "Failed: #{inspect(reason)}")
      end

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :run_action, result}, state) do
    state =
      case result do
        {:ok, screen} ->
          state
          |> Map.put(:current_screen, screen)
          |> Map.put(:phase, :idle)
          |> Map.put(:task_pid, nil)
          |> add_log(:ok, "Action finished, still at #{screen}")

        {:error, reason} ->
          state
          |> Map.put(:phase, :idle)
          |> Map.put(:task_pid, nil)
          |> add_log(:error, "Action failed: #{inspect(reason)}")
      end

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :select_team_on_screen, result}, state) do
    state =
      case result do
        {:ok, %{team: team?, order: order?}} ->
          add_log(state, :ok, "Applied on screen (team=#{team?}, order=#{order?})")

        {:error, reason} ->
          add_log(state, :error, "Failed: #{inspect(reason)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :claim_rewards, result}, state) do
    state =
      case result do
        {:ok, action} -> add_log(state, :ok, "Rewards: #{action}")
        {:error, reason} -> add_log(state, :error, "Rewards failed: #{inspect(reason)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :run_script, result}, state) do
    state =
      case result do
        {:ok, screen} -> add_log(state, :ok, "Script finished at #{screen}")
        {:error, reason} -> add_log(state, :error, "Script failed: #{inspect(reason)}")
        other -> add_log(state, :error, "Script returned unexpected result: #{inspect(other)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)

    broadcast(state)

    # A script can move through several screens before succeeding or
    # failing partway. Its return value alone doesn't say which one we
    # ended up on, so re-sync current_screen from live state instead of
    # guessing from the result.
    handle_cast(:localize, state)
  end

  @impl true
  def handle_info({:nav_log, kind, text}, state) do
    state = add_log(state, kind, text)
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:nav_paused, state) do
    state = %{state | phase: :paused}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp cancel_running(%{task_pid: nil} = state), do: %{state | phase: :idle}

  defp cancel_running(%{task_pid: pid} = state) do
    Task.Supervisor.terminate_child(StarlightBot.TaskSupervisor, pid)
    %{state | task_pid: nil, phase: :idle}
  end

  defp add_log(state, kind, text) do
    entry = %{at: System.monotonic_time(:millisecond), kind: kind, text: text}
    %{state | log: [entry | state.log] |> Enum.take(@log_limit)}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:nav_state, external(state)})
  end

  defp external(state) do
    %{
      current_screen: state.current_screen,
      goal: state.goal,
      phase: state.phase,
      log: state.log
    }
  end
end
