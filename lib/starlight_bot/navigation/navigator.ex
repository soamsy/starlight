defmodule StarlightBot.Navigation.Navigator do
  use GenServer
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Scripts.ShopRunner
  alias StarlightBot.{Ctx, LogStore, RunHistory, Teams}
  alias StarlightBot.Automation.Scripts.{ClaimRewards, EnkephalinConversion, LuxcavationRunner, MirrorDungeonRunner, SelectTeamOnScreen}
  alias StarlightBot.Navigation.{Catalog, DSL, Machine, RunClock, RunSplits, Runner, ScreenTimes}

  @topic "navigation"
  @log_limit 1000

  defstruct [
    current_screen: nil,   # nil = never localized | :unknown | screen atom
    goal: nil,             # atom | nil
    phase: :idle,          # :idle | :localizing | :running | :paused
    log: [],               # newest first
    run_memory: %{},       # snapshot of the current mirror dungeon run's RunMemory, cleared per run
    task_pid: nil,
    run_memory_agent: nil,
    run_kind: nil,
    origin: :manual,
    last_run: nil,
    pause_flag: nil,
    run_clock: nil,
    run_splits: [],
    screen_times: %ScreenTimes{},
    next_run: nil
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def status, do: GenServer.call(__MODULE__, :status)

  def localize, do: GenServer.cast(__MODULE__, :localize)

  def run_to(screen_name), do: GenServer.cast(__MODULE__, {:run_to, screen_name})

  def run_action(action_name), do: GenServer.cast(__MODULE__, {:run_action, action_name})

  def run_transition(transition_name), do: GenServer.cast(__MODULE__, {:run_transition, transition_name})

  def run_script(script_name), do: GenServer.cast(__MODULE__, {:run_script, script_name})

  def run_luxcavation(
        team,
        exp_waves,
        thread_waves,
        collect_xp?,
        collect_enkephalin?,
        enkephalin_convert_count
      ),
      do:
        GenServer.cast(
          __MODULE__,
          {:run_luxcavation, team, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count}
        )

  def run_mirror_dungeon(picks, run_count, config),
    do: GenServer.cast(__MODULE__, {:run_mirror_dungeon, picks, run_count, config})

  def run_scheduled(action), do: GenServer.cast(__MODULE__, {:scheduled, action})

  def origin, do: GenServer.call(__MODULE__, :origin)

  def queue_after_run({:run_mirror_dungeon, _picks, _run_count, _config} = next),
    do: GenServer.cast(__MODULE__, {:queue_after_run, next})

  def charge_enkephalin(convert_count), do: GenServer.cast(__MODULE__, {:charge_enkephalin, convert_count})

  def select_team_on_screen(team_id, hook),
    do: GenServer.cast(__MODULE__, {:select_team_on_screen, team_id, hook})

  def run_shop_dry_run(team, floor), do: GenServer.cast(__MODULE__, {:run_shop_dry_run, team, floor})

  def run_shop(team, floor), do: GenServer.cast(__MODULE__, {:run_shop, team, floor})

  def claim_rewards(config), do: GenServer.cast(__MODULE__, {:claim_rewards, config})

  def cancel, do: GenServer.cast(__MODULE__, :cancel)

  def pause, do: GenServer.cast(__MODULE__, :pause)

  def resume_luxcavation, do: GenServer.cast(__MODULE__, :resume_luxcavation)

  def resume_mirror_dungeon, do: GenServer.cast(__MODULE__, :resume_mirror_dungeon)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:origin, _from, state), do: {:reply, state.origin, state}

  def handle_call(:status, _from, state) do
    {:reply, external(state), state}
  end

  @impl true
  def handle_cast(:localize, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Localizing…")
    pid = start_machine(Runner.localize_program(Catalog.all_screens()), :localize)

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
            pid = start_machine(Runner.plan_program(transitions), :run_to)

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
            pid = start_machine(Runner.action_program(from, action), :run_action)

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
            pid = start_machine(Runner.plan_program([transition]), :run_to)

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
        program = if program?(module), do: module.program(), else: [DSL.invoke(module, :run, [])]
        state = launch(state, :run_script, program, nav_ctx())
        state = %{state | phase: :running, goal: nil}
        broadcast(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:charge_enkephalin, _count}, %{task_pid: pid} = state) when is_pid(pid),
    do: refuse_run(state, "enkephalin charge", "another run")

  def handle_cast({:charge_enkephalin, convert_count}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Charging enkephalin (#{convert_count}x lunacy)")
    state = launch(state, :run_script, EnkephalinConversion.program(convert_count), nav_ctx(), nil)
    state = %{state | phase: :running, goal: nil, run_kind: :enkephalin}
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:scheduled, action}, state) do
    idle? = state.task_pid == nil
    {:noreply, started} = handle_cast(action, state)
    {:noreply, if(idle? and started.task_pid != nil, do: %{started | origin: :scheduler}, else: started)}
  end

  def handle_cast({:run_luxcavation, _, _, _, _, _, _}, %{run_kind: :mirror_dungeon, task_pid: pid} = state) when is_pid(pid),
    do: refuse_run(state, "luxcavation", "mirror dungeon")

  def handle_cast({:run_mirror_dungeon, _, _, _}, %{run_kind: :luxcavation, task_pid: pid} = state) when is_pid(pid),
    do: refuse_run(state, "mirror dungeon", "luxcavation")

  def handle_cast(
        {:run_luxcavation, team, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count},
        state
      ) do
    state = cancel_running(state)

    state =
      add_log(
        state,
        :info,
        "Running luxcavation: exp_team=#{team_label(team.exp)} thread_team=#{team_label(team.thread)} exp_waves=#{exp_waves} thread_waves=#{thread_waves} " <>
          "collect_xp=#{collect_xp?} collect_enkephalin=#{collect_enkephalin?} enkephalin_convert_count=#{enkephalin_convert_count}"
      )

    pause_flag = :atomics.new(1, [])

    program =
      LuxcavationRunner.program(
        team,
        exp_waves,
        thread_waves,
        collect_xp?,
        collect_enkephalin?,
        enkephalin_convert_count
      )

    ctx = nav_ctx(paused_to: {self(), :nav_paused}, pause_flag: pause_flag)
    state = launch(state, :run_script, program, ctx, [])
    state = %{state | phase: :running, goal: nil, run_kind: :luxcavation, pause_flag: pause_flag}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_mirror_dungeon, picks, run_count, config}, state) do
    state = cancel_running(state)
    state = %{state | run_memory: %{}}
    state = add_log(state, :info, "Running mirror dungeon: teams=#{inspect(picks)} runs=#{run_count} config=#{inspect(config)}")
    pause_flag = :atomics.new(1, [])
    ctx = nav_ctx(paused_to: {self(), :nav_paused}, pause_flag: pause_flag, run_memory_to: {self(), :nav_run_memory})
    state = launch(state, :run_script, MirrorDungeonRunner.program(picks, run_count, config), ctx, [])

    state = %{state | phase: :running, goal: nil, run_kind: :mirror_dungeon, pause_flag: pause_flag, run_clock: RunClock.start(now_ms()), run_splits: [], screen_times: ScreenTimes.track(%ScreenTimes{}, %{run: 1}, 0, DateTime.utc_now())}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_mirror_dungeon, %{phase: :paused, task_pid: pid} = state) when is_pid(pid) do
    clear_pause_request(state)
    state = %{state | phase: :running} |> update_clock(&RunClock.start/2)
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_mirror_dungeon, state), do: {:noreply, state}

  @impl true
  def handle_cast({:select_team_on_screen, team_id, hook}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Selecting team #{team_id} on screen with #{hook}")
    program = [DSL.invoke(SelectTeamOnScreen, :run, [team_id, "md_battle", 1])]
    state = launch(state, :select_team_on_screen, program, nav_ctx(), put_team: %{id: team_id, hook: hook})
    state = %{state | phase: :running, goal: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_shop_dry_run, team, floor}, state) do
    state = cancel_running(state)
    state = %{state | run_memory: %{}}
    state = add_log(state, :info, "Shop dry run: team=#{team.id} hook=#{team.hook} floor=#{floor}")
    state = launch_shop(state, :shop_dry_run, :dry_run, team, floor)
    state = %{state | phase: :running, goal: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_shop, team, floor}, state) do
    state = cancel_running(state)
    state = %{state | run_memory: %{}}
    state = add_log(state, :info, "Shop runner (full run): team=#{team.id} hook=#{team.hook} floor=#{floor}")
    state = launch_shop(state, :shop_runner, :run, team, floor)
    state = %{state | phase: :running, goal: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:claim_rewards, config}, state) do
    state = cancel_running(state)
    state = add_log(state, :info, "Claiming rewards: #{inspect(config)}")
    state = launch(state, :claim_rewards, ClaimRewards.steps(config), nav_ctx())
    state = %{state | phase: :running, goal: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:queue_after_run, next}, %{task_pid: pid} = state) when is_pid(pid) do
    state = %{state | next_run: next} |> add_log(:info, "Queued to run next: #{next_run_label(next)}")
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:queue_after_run, next}, state) do
    state = add_log(state, :error, "Nothing is running, so #{next_run_label(next)} wasn't queued")
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:cancel, state) do
    if state.run_kind in [:luxcavation, :mirror_dungeon], do: RunHistory.record_canceled(state.run_kind)
    state = cancel_running(state)
    state = %{state | run_memory: %{}}
    state = add_log(state, :info, "Cancelled")
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_luxcavation, %{phase: :paused, task_pid: pid} = state) when is_pid(pid) do
    clear_pause_request(state)
    state = %{state | phase: :running}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resume_luxcavation, state), do: {:noreply, state}

  @impl true
  def handle_cast(:pause, %{phase: :running, pause_flag: pause_flag} = state) when pause_flag != nil do
    :atomics.put(pause_flag, 1, 1)
    state = add_log(state, :info, "Pause requested, pausing before the next step")
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state), do: {:noreply, state}

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
  def handle_info({:nav_result, :shop_dry_run, result}, state) do
    state =
      case result do
        {:ok, %{steps: steps}} -> add_log(state, :ok, "Dry run complete: #{Enum.count(steps, &(&1.outcome == :would_run))} step(s) would run")
        {:ok, _} -> add_log(state, :ok, "Dry run complete: no milestones to run")
        {:error, reason} -> add_log(state, :error, "Dry run failed: #{inspect(reason)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_result, :shop_runner, result}, state) do
    state =
      case result do
        {:ok, %{steps: steps}} -> add_log(state, :ok, "Shop runner finished: #{length(steps)} milestone(s) handled")
        {:ok, _} -> add_log(state, :ok, "Shop runner finished: no milestones to run")
        {:error, reason} -> add_log(state, :error, "Shop runner failed: #{inspect(reason)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)

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
    finished = %{kind: state.run_kind, ok?: match?({:ok, _}, result)}
    state = persist_last_run(state, if(match?({:ok, _}, result), do: "success", else: "failure"))

    state =
      case result do
        {:ok, screen} -> add_log(state, :ok, "Script finished at #{screen}")
        {:error, reason} -> add_log(state, :error, "Script failed: #{inspect(reason)}")
        other -> add_log(state, :error, "Script returned unexpected result: #{inspect(other)}")
      end
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)
      |> Map.put(:run_kind, nil)
      |> Map.put(:last_run, finished)
      |> Map.put(:pause_flag, nil)
      |> update_clock(&RunClock.stop/2)

    {next, state} = {state.next_run, %{state | next_run: nil}}

    case {next, result} do
      {nil, _} ->
        localize_after_script(%{state | origin: :manual})

      {next, {:ok, _}} ->
        state = add_log(state, :info, "Starting the queued #{next_run_label(next)}")
        broadcast(state)
        origin = state.origin
        {:noreply, state} = handle_cast(next, state)
        {:noreply, %{state | origin: origin}}

      {next, _} ->
        state = add_log(state, :error, "Skipping the queued #{next_run_label(next)} because the run before it didn't finish")
        localize_after_script(%{state | origin: :manual})
    end
  end

  @impl true
  def handle_info({{:nav_machine, kind}, result}, state), do: handle_info({:nav_result, kind, result}, release_run(state))

  @impl true
  def handle_info({:nav_log, :step, _text}, state), do: {:noreply, state}

  def handle_info({:nav_log, kind, text}, state) do
    state = remember_log(state, kind, text)
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nav_run_memory, snapshot}, state) do
    state = state |> track_screen(snapshot) |> Map.put(:run_memory, snapshot) |> track_split(snapshot)
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:nav_paused, state) do
    state = %{state | phase: :paused} |> update_clock(&RunClock.stop/2)
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{task_pid: pid} = state) do
    state =
      state
      |> release_run()
      |> persist_last_run("failure")
      |> Map.put(:phase, :idle)
      |> Map.put(:task_pid, nil)
      |> Map.put(:run_kind, nil)
      |> Map.put(:pause_flag, nil)
      |> Map.put(:next_run, nil)
      |> Map.put(:origin, :manual)
      |> Map.put(:last_run, nil)
      |> update_clock(&RunClock.stop/2)
      |> add_log(:error, "Run crashed: #{inspect(reason)}")

    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp team_label(nil), do: "none"
  defp team_label(%{id: id, hook: hook}), do: "#{id}/#{hook}"

  defp nav_ctx(fields \\ []), do: Ctx.new([log_to: {self(), :nav_log}] ++ fields)

  defp start_machine(program, kind, ctx \\ nav_ctx()) do
    opts = [reply_to: {self(), {:nav_machine, kind}}, label: to_string(kind)]
    {:ok, pid} = DynamicSupervisor.start_child(StarlightBot.MachineSupervisor, {Machine, {program, ctx, opts}})
    Process.monitor(pid)
    pid
  end

  defp launch(state, kind, program, ctx, run_memory_seeds \\ nil) do
    ctx = with_run_memory(ctx, run_memory_seeds)
    %{state | task_pid: start_machine(program, kind, ctx), run_memory_agent: ctx.run_memory}
  end

  defp launch_shop(state, kind, mode, team, floor) do
    ctx = nav_ctx(run_memory_to: {self(), :nav_run_memory})
    launch(state, kind, ShopRunner.program(mode), ctx, put_team: team, put_floor: floor)
  end

  defp with_run_memory(ctx, nil), do: ctx

  defp with_run_memory(ctx, seeds) do
    {:ok, agent} = RunMemory.start_link()
    ctx = %{ctx | run_memory: agent}
    Enum.each(seeds, fn {put, value} -> apply(RunMemory, put, [ctx, value]) end)
    ctx
  end

  defp release_run(state) do
    if state.run_memory_agent && Process.alive?(state.run_memory_agent), do: Agent.stop(state.run_memory_agent)
    %{state | run_memory_agent: nil}
  end

  defp program?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :program, 0)

  defp localize_after_script(state) do
    broadcast(state)

    # A script can move through several screens before succeeding or
    # failing partway. Its return value alone doesn't say which one we
    # ended up on, so re-sync current_screen from live state instead of
    # guessing from the result.
    handle_cast(:localize, state)
  end

  defp next_run_label({:run_mirror_dungeon, picks, run_count, _config}),
    do: "mirror dungeon (#{run_count} run(s), #{length(picks)} team(s))"

  defp refuse_run(state, wanted, active) do
    state = add_log(state, :error, "Not starting #{wanted}: #{active} is running. Cancel it first.")
    broadcast(state)
    {:noreply, state}
  end

  defp cancel_running(%{task_pid: nil} = state), do: update_clock(%{state | phase: :idle, run_kind: nil, origin: :manual, last_run: nil, pause_flag: nil, next_run: nil}, &RunClock.stop/2)

  defp cancel_running(%{task_pid: pid} = state) do
    DynamicSupervisor.terminate_child(StarlightBot.MachineSupervisor, pid)
    state = state |> release_run() |> persist_last_run("interrupted")
    update_clock(%{state | task_pid: nil, phase: :idle, run_kind: nil, origin: :manual, last_run: nil, pause_flag: nil, next_run: nil}, &RunClock.stop/2)
  end

  defp track_split(%{run_kind: :mirror_dungeon, run_clock: %RunClock{} = clock} = state, %{run_progress: %{current: run}, floor: floor} = snapshot) do
    team = get_in(snapshot, [:team, :name])
    %{state | run_splits: RunSplits.track(state.run_splits, run, floor, RunClock.elapsed_ms(clock, now_ms()), team)}
  end

  defp track_split(state, _snapshot), do: state

  defp track_screen(%{run_kind: :mirror_dungeon, run_clock: %RunClock{} = clock} = state, snapshot) do
    key = %{
      screen: snapshot[:screen],
      task: snapshot[:task],
      step: snapshot[:step],
      run: get_in(snapshot, [:run_progress, :current]) || 1,
      floor: snapshot[:floor]
    }

    previous_run = ScreenTimes.current_run(state.screen_times)
    state = %{state | screen_times: ScreenTimes.track(state.screen_times, key, RunClock.elapsed_ms(clock, now_ms()), DateTime.utc_now())}
    if previous_run != key.run, do: persist_run(state, previous_run, if(previous_run in Map.get(snapshot, :failed_runs, []), do: "failure", else: "success"))
    state
  end

  defp track_screen(state, _snapshot), do: state

  defp persist_last_run(%{run_kind: :mirror_dungeon, screen_times: times} = state, result) do
    persist_run(state, ScreenTimes.current_run(times), result)
    state
  end

  defp persist_last_run(state, _result), do: state

  defp persist_run(%{run_clock: %RunClock{} = clock, screen_times: times, run_memory: run_memory}, run, result) when is_integer(run) do
    segments = times |> ScreenTimes.segments(RunClock.elapsed_ms(clock, now_ms())) |> Enum.filter(&(&1.run == run))
    team_id = get_in(run_memory, [:team, :id])

    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      team_name = team_id && Teams.get_team(team_id)[:name]
      RunHistory.save_run(%{team_id: team_id, team_name: team_name, result: result}, segments)
    end)
  end

  defp persist_run(_state, _run, _result), do: :ok

  defp update_clock(%{run_clock: nil} = state, _fun), do: state
  defp update_clock(%{run_clock: clock} = state, fun), do: %{state | run_clock: fun.(clock, now_ms())}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp clear_pause_request(%{pause_flag: nil}), do: :ok
  defp clear_pause_request(%{pause_flag: pause_flag}), do: :atomics.put(pause_flag, 1, 0)

  defp pause_requested?(%{pause_flag: nil}), do: false
  defp pause_requested?(%{pause_flag: pause_flag}), do: :atomics.get(pause_flag, 1) == 1

  defp add_log(state, kind, text) do
    LogStore.append(kind, text)
    remember_log(state, kind, text)
  end

  defp remember_log(state, kind, text) do
    entry = %{at: LogStore.now(), kind: kind, text: text}
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
      log: state.log,
      run_memory: state.run_memory,
      run_kind: state.run_kind,
      last_run: state.last_run,
      next_run: state.next_run,
      pause_requested: pause_requested?(state),
      run_clock: state.run_clock && %{elapsed_ms: RunClock.elapsed_ms(state.run_clock, now_ms()), running?: RunClock.running?(state.run_clock)},
      run_splits: state.run_splits,
      screen_times: state.screen_times
    }
  end
end
