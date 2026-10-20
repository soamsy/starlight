defmodule StarlightBot.Automation.Scripts.ShopRunner do
  import StarlightBot.Navigation.DSL, only: [any_of: 1]
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Automation.Shop.{Actions, Ops}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}
  alias StarlightBot.Navigation.Screens.Shop

  @actions %{
    "budget" => Actions.Budget,
    "refresh" => Actions.Refresh,
    "buy_list" => Actions.BuyList,
    "fusion" => Actions.Fusion,
    "sell" => Actions.Sell,
    "uptie" => Actions.Uptie,
    "affinity_refresh" => Actions.AffinityRefresh,
    "heal" => Actions.Heal,
    "heal_all" => Actions.Heal,
    "revive" => Actions.Heal,
    "skill_replace" => Actions.SkillReplace
  }
  @previews %{
    "fusion" => Actions.Fusion,
    "sell" => Actions.Sell,
    "uptie" => Actions.Uptie,
    "skill_replace" => Actions.SkillReplace,
    "revive" => Actions.Heal
  }

  @heal_kinds ["heal", "heal_all", "revive"]
  @fusion_kinds ["fusion"]
  @assumed_starting_cost 200

  def run(ctx), do: execute(:run, ctx)

  def dry_run(ctx), do: execute(:dry_run, ctx)

  defp execute(mode, ctx) do
    if Engine.check(any_of(Shop.popup_screens())) do
      Ctx.log(ctx, :info, "shop runner: a shop popup is open, backing out to the shop first")
      Ops.recover_to_shop(ctx)
    end

    Ops.forget_shelf(ctx)
    Ops.reset_chance_comet(ctx)
    RunMemory.put_cost(ctx, nil)
    Ops.detect_and_update_cost(ctx)

    if is_nil(RunMemory.cost(ctx)) do
      Ctx.log(ctx, :info, "shop runner: cost not read yet, assuming #{@assumed_starting_cost} until it is")
      RunMemory.put_cost(ctx, @assumed_starting_cost)
    end

    with {:ok, plan} <- fetch_plan(ctx),
         {:ok, workflow} <- fetch_workflow(plan, ctx),
         steps = Enum.filter(workflow["steps"], &(&1["enabled"] != false)),
         keep_open? = mode == :run and sell_first?(GiftPlans.expand_steps(plan, workflow)),
         {:ok, _} <- Ops.check_inventory(ctx, keep_open?) do
      state = %{initial_state(plan, workflow, mode, ctx) | sell_popup_open: keep_open?}
      Ctx.log(ctx, :info, "shop runner: floor #{state.floor}, #{state.shop_type} shop, workflow #{workflow["name"]}")

      final = steps |> run_steps(state, mode, ctx) |> close_sell_popup(ctx) |> close_heal_menu(ctx)
      if mode == :run, do: Ops.close_fuse_popup(ctx)
      RunMemory.put(ctx, :task, nil)

      {:ok, trace(final)}
    else
      {:skip, reason} ->
        Ctx.log(ctx, :error, "shop runner: #{reason} — doing nothing")
        {:ok, :no_workflow}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_plan(ctx) do
    case RunMemory.gift_strategy(ctx) do
      nil -> {:skip, "no gift plan for this team"}
      data -> {:ok, GiftPlans.normalize(data)}
    end
  end

  defp fetch_workflow(plan, ctx) do
    floor = RunMemory.floor(ctx)

    case GiftPlans.workflow_for_floor(plan, floor) do
      nil -> {:skip, "no workflow scheduled for floor #{floor}"}
      workflow -> {:ok, workflow}
    end
  end

  defp initial_state(plan, workflow, mode, ctx) do
    gifts = EgoGifts.list_gifts()
    floor = RunMemory.floor(ctx)
    progress = if mode == :run, do: resumable_progress(workflow, floor, ctx)

    state = %{
      plan: plan,
      workflow: workflow,
      floor: floor,
      shop_type: Ops.shop_type(),
      reserve: (progress && progress.reserve) || 0,
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1}),
      protected: GiftPlans.protected_set(plan, workflow, gifts),
      sell_popup_open: false,
      heal_menu_open: false,
      last_heal: nil,
      call_stack: [workflow["id"]],
      label_prefix: "",
      bailed: false,
      left: false,
      steps: (progress && progress.steps) || [],
      done: (progress && progress.done) || %{},
      track_progress?: mode == :run
    }

    RunMemory.put_shop_plan(ctx, trace(state))
    state
  end

  defp resumable_progress(workflow, floor, ctx) do
    workflow_id = workflow["id"]

    case RunMemory.shop_progress(ctx) do
      %{workflow_id: ^workflow_id, floor: ^floor, done: done} = progress when map_size(done) > 0 ->
        Ctx.log(ctx, :info, "shop runner: resuming floor #{floor}, #{map_size(done)} step(s) already handled")
        progress

      _ ->
        nil
    end
  end

  defp step_key(step, state), do: state.label_prefix <> to_string(step["id"])

  defp sell_first?(steps) do
    case Enum.reject(steps, &(&1["kind"] == "budget")) do
      [%{"kind" => "sell"} | _] -> true
      _ -> false
    end
  end

  defp close_sell_popup(%{sell_popup_open: true} = state, ctx) do
    Ops.close_sell_popup(ctx)
    %{state | sell_popup_open: false}
  end

  defp close_sell_popup(state, _ctx), do: state

  defp close_heal_menu(%{heal_menu_open: true} = state, ctx) do
    Ops.close_heal_menu(ctx)
    Ops.detect_and_update_cost(ctx)
    %{state | heal_menu_open: false}
  end

  defp close_heal_menu(state, _ctx), do: state

  defp run_steps(steps, state, mode, ctx) do
    Enum.reduce_while(steps, state, fn step, state ->
      state = run_repeated(step, state, mode, ctx)
      if state.bailed or state.left, do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp run_repeated(step, state, mode, ctx) do
    case step["repeat"] do
      extra when is_integer(extra) and extra > 0 ->
        first_run_key = "#{state.label_prefix}(1/#{extra + 1}) #{step["id"]}"

        if Map.has_key?(state.done, first_run_key) or condition_met?(step, state, ctx),
          do: repeat_step(Map.delete(step, "condition"), state, mode, ctx, 1, extra + 1),
          else: run_step(step, state, mode, ctx)

      _ ->
        run_step(step, state, mode, ctx)
    end
  end

  defp workflow_name(%{call_stack: [id | _]} = state) do
    case GiftPlans.find_workflow(state.plan, id) do
      nil -> "the workflow"
      workflow -> workflow["name"]
    end
  end

  defp condition_met?(step, state, ctx), do: GiftPlans.eval_condition(step["condition"], condition_env(state, ctx))

  defp condition_env(state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)
    %{wallet: wallet(state, ctx), owned: owned_names(inventory), inventory: inventory, plan: state.plan}
  end

  defp repeat_step(step, state, mode, ctx, run, total) when is_integer(run) and is_integer(total) do
    prefix = state.label_prefix
    state = run_step(step, %{state | label_prefix: "#{prefix}(#{run}/#{total}) "}, mode, ctx)
    state = %{state | label_prefix: prefix}

    cond do
      run >= total -> state
      state.bailed or state.left -> state
      List.last(state.steps).outcome == :failed -> state
      true -> repeat_step(step, state, mode, ctx, run + 1, total)
    end
  end

  defp run_step(%{"kind" => "workflow"} = step, state, mode, ctx) do
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)
    previous = Map.get(state.done, step_key(step, state))

    cond do
      previous not in [nil, :done] ->
        state

      previous == nil and not condition_met?(step, state, ctx) ->
        record(state, step, label, :skipped, "condition not met: #{GiftPlans.condition_label(step["condition"], state.plan)}", ctx)

      true ->
        case GiftPlans.definition_for(state.plan, step) do
          {:error, _} ->
            record(state, step, label, :failed, "no workflow selected, or it was deleted", ctx)

          {:ok, sub} ->
            if sub["id"] in state.call_stack do
              record(state, step, label, :failed, "#{sub["name"]} is already running, skipping to avoid a loop", ctx)
            else
              sub_steps = Enum.filter(sub["steps"], &(&1["enabled"] != false))
              state = if previous, do: state, else: record(state, step, label, :done, "running #{length(sub_steps)} step(s)", ctx)
              nested = %{state | call_stack: [sub["id"] | state.call_stack], label_prefix: label <> " › "}
              finished = run_steps(sub_steps, nested, mode, ctx)
              %{finished | call_stack: state.call_stack, label_prefix: state.label_prefix, bailed: false}
            end
        end
    end
  end

  defp run_step(%{"kind" => kind} = step, state, mode, ctx) when kind in ["bail", "leave"] do
    case Map.get(state.done, step_key(step, state)) do
      nil -> run_exit_step(step, state, mode, ctx)
      :done -> exit_flag(kind, state)
      _ -> state
    end
  end

  defp run_step(step, state, mode, ctx) do
    if Map.has_key?(state.done, step_key(step, state)),
      do: state,
      else: run_action_step(step, state, mode, ctx)
  end

  defp exit_flag("bail", state), do: %{state | bailed: true}
  defp exit_flag("leave", state), do: %{state | left: true}

  defp run_exit_step(%{"kind" => "bail"} = step, state, mode, ctx) do
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)

    if condition_met?(step, state, ctx) do
      verb = if mode == :dry_run, do: "would leave", else: "leaving"
      state = record(state, step, label, :done, "#{verb} #{workflow_name(state)}", ctx)
      %{state | bailed: true}
    else
      record(state, step, label, :skipped, "condition not met: #{GiftPlans.condition_label(step["condition"], state.plan)}", ctx)
    end
  end

  defp run_exit_step(%{"kind" => "leave"} = step, state, mode, ctx) do
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)

    if condition_met?(step, state, ctx) do
      verb = if mode == :dry_run, do: "would leave", else: "leaving"
      state = record(state, step, label, :done, "#{verb} the shop", ctx)
      %{state | left: true}
    else
      record(state, step, label, :skipped, "condition not met: #{GiftPlans.condition_label(step["condition"], state.plan)}", ctx)
    end
  end

  defp run_action_step(step, state, mode, ctx) do
    state = if step["kind"] in ["sell", "budget"], do: state, else: close_sell_popup(state, ctx)
    state = if step["kind"] in @heal_kinds ++ ["budget"], do: state, else: close_heal_menu(state, ctx)
    if mode == :run and step["kind"] not in @fusion_kinds ++ ["budget"], do: Ops.close_fuse_popup(ctx)
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)
    RunMemory.put(ctx, :task, "shop: #{label}")

    {outcome, detail, state} =
      cond do
        not condition_met?(step, state, ctx) ->
          {:skipped, "condition not met: #{GiftPlans.condition_label(step["condition"], state.plan)}", state}

        mode == :dry_run and step["kind"] != "budget" ->
          preview(step, state, ctx)

        true ->
          dispatch(step, state, ctx)
      end

    state = record(state, step, label, outcome, detail, ctx)
    after_step(outcome, step, ctx)
    if outcome == :failed, do: %{state | sell_popup_open: false, heal_menu_open: false}, else: state
  end

  defp record(state, step, label, outcome, detail, ctx) do
    Ctx.log(ctx, log_kind(outcome), "shop runner: #{label} — #{outcome}: #{detail}")
    state = %{
      state
      | steps: state.steps ++ [%{id: step["id"], label: label, outcome: outcome, detail: detail}],
        done: Map.put(state.done, step_key(step, state), outcome)
    }

    RunMemory.put_shop_plan(ctx, trace(state))
    if state.track_progress?, do: RunMemory.put_shop_progress(ctx, progress(state))
    state
  end

  defp dispatch(step, state, ctx) do
    with {:ok, module} <- Map.fetch(@actions, step["kind"]),
         {:ok, definition} <- GiftPlans.definition_for(state.plan, step) do
      module.run(step, definition, state, ctx)
    else
      :error -> {:not_implemented, "no automation for #{step["kind"]} yet", state}
      {:error, :missing_definition} -> {:failed, "references a deleted definition", state}
      {:error, :no_definitions} -> {:failed, "no definitions selected", state}
    end
  end

  defp preview(step, state, ctx) do
    with {:ok, module} <- Map.fetch(@previews, step["kind"]),
         {:ok, definition} <- GiftPlans.definition_for(state.plan, step) do
      module.preview(step, definition, state, ctx)
    else
      {:error, :missing_definition} -> {:failed, "references a deleted definition", state}
      {:error, :no_definitions} -> {:failed, "no definitions selected", state}
      :error -> {:would_run, "condition passes", state}
    end
  end

  defp after_step(:failed, _step, ctx) do
    Ops.recover_to_shop(ctx)
    Ops.detect_and_update_cost(ctx)
  end

  defp after_step(outcome, %{"kind" => kind}, ctx) when outcome in [:done, :partial] and kind not in ["budget" | @heal_kinds] and kind not in @fusion_kinds do
    Ops.detect_and_update_cost(ctx)
  end

  defp after_step(_outcome, _step, _ctx), do: :ok

  defp wallet(state, ctx) do
    case RunMemory.cost(ctx) do
      nil -> nil
      cost -> cost - state.reserve
    end
  end

  defp owned_names(inventory), do: inventory |> Map.values() |> MapSet.new(& &1.name)

  defp log_kind(outcome) when outcome in [:done, :partial, :would_run], do: :ok
  defp log_kind(:failed), do: :error
  defp log_kind(_outcome), do: :info

  defp progress(state) do
    %{
      workflow_id: state.workflow["id"],
      floor: state.floor,
      reserve: state.reserve,
      steps: state.steps,
      done: state.done
    }
  end

  defp trace(state) do
    %{
      workflow: state.workflow["name"],
      floor: state.floor,
      shop_type: state.shop_type,
      reserve: state.reserve,
      steps: state.steps
    }
  end
end
