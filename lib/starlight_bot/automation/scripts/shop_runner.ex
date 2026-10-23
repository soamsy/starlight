defmodule StarlightBot.Automation.Scripts.ShopRunner do
  import StarlightBot.Navigation.DSL, only: [any_of: 1, call: 3, result: 1]
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Automation.Shop.{Actions, Ops}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}
  alias StarlightBot.Navigation.Screens.Shop
  alias StarlightBot.Vision.Capture

  @actions %{
    "budget" => Actions.Budget,
    "refresh" => Actions.Refresh,
    "buy_list" => Actions.BuyList,
    "fusion" => Actions.Fusion,
    "milestone" => Actions.Milestone,
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
    "milestone" => Actions.Milestone,
    "sell" => Actions.Sell,
    "uptie" => Actions.Uptie,
    "skill_replace" => Actions.SkillReplace,
    "revive" => Actions.Heal
  }

  @heal_kinds ["heal", "heal_all", "revive"]
  @fusion_kinds ["fusion"]
  @assumed_starting_cost 200

  def run(ctx), do: Engine.act(program(:run), ctx)

  def dry_run(ctx), do: Engine.act(program(:dry_run), ctx)

  def program(mode), do: [call(__MODULE__, :start, [mode])]

  def start(mode, _frame, ctx) do
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
      {:steps, [walk([{:steps, steps}], state, mode)]}
    else
      {:skip, reason} ->
        Ctx.log(ctx, :error, "shop runner: #{reason} — doing nothing")
        {:steps, [result({:ok, :no_workflow})]}

      {:error, _} = err ->
        err
    end
  end

  def walk(work, state, mode, _frame, ctx), do: walk_items(work, state, mode, ctx)

  def action(step, work, state, mode, _frame, ctx) do
    case run_action_step(step, state, mode, ctx) do
      :interrupted -> {:error, :window_not_focused}
      state -> {:steps, [walk(work, state, mode)]}
    end
  end

  defp fetch_plan(ctx) do
    case RunMemory.gift_plan(ctx) do
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
      refreshes: (progress && progress[:refreshes]) || 0,
      replaced: (progress && progress[:replaced]) || MapSet.new(),
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

  defp walk(work, state, mode), do: call(__MODULE__, :walk, [work, state, mode])

  defp walk_items([], state, mode, ctx) do
    final = state |> close_sell_popup(ctx) |> close_heal_menu(ctx)
    if mode == :run, do: Ops.close_fuse_popup(ctx)
    RunMemory.put(ctx, :task, nil)
    {:steps, [result({:ok, trace(final)})]}
  end

  defp walk_items([{:steps, []} | work], state, mode, ctx), do: walk_items(work, state, mode, ctx)

  defp walk_items([{:steps, [step | rest]} | work], state, mode, ctx) do
    if state.bailed or state.left,
      do: walk_items(work, state, mode, ctx),
      else: walk_items([{:repeated, step}, {:steps, rest} | work], state, mode, ctx)
  end

  defp walk_items([{:repeated, %{"kind" => "if"} = step} | work], state, mode, ctx), do: walk_items([{:step, step} | work], state, mode, ctx)

  defp walk_items([{:repeated, step} | work], state, mode, ctx) do
    case step["repeat"] do
      extra when is_integer(extra) and extra > 0 ->
        first_run_key = "#{state.label_prefix}(1/#{extra + 1}) #{step["id"]}"

        if Map.has_key?(state.done, first_run_key) or condition_met?(step, state, ctx),
          do: walk_items([{:repeat, Map.delete(step, "condition"), step["condition"], 1, extra + 1} | work], state, mode, ctx),
          else: walk_items([{:step, step} | work], state, mode, ctx)

      _ ->
        walk_items([{:step, step} | work], state, mode, ctx)
    end
  end

  defp walk_items([{:repeat, step, condition, run, total} | work], state, mode, ctx) do
    prefix = state.label_prefix
    repeat = [{:prefix, "#{prefix}(#{run}/#{total}) "}, {:step, step}, {:prefix, prefix}, {:after_repeat, step, condition, run, total}]
    walk_items(repeat ++ work, state, mode, ctx)
  end

  defp walk_items([{:after_repeat, step, condition, run, total} | work], state, mode, ctx) do
    cond do
      run >= total -> walk_items(work, state, mode, ctx)
      state.bailed or state.left -> walk_items(work, state, mode, ctx)
      List.last(state.steps).outcome == :failed -> walk_items(work, state, mode, ctx)
      milestone_reached?(step, state, ctx) -> walk_items(work, state, mode, ctx)
      true -> walk_items(between_work(step, condition, state, run, total) ++ work, state, mode, ctx)
    end
  end

  defp walk_items([{:after_between, step, condition, run, total, before, between_key} | work], state, mode, ctx) do
    failed? = state.steps |> Enum.drop(before) |> Enum.any?(&(&1.outcome == :failed))

    if state.left or failed? or Map.get(state.done, between_key) in [:skipped, :failed],
      do: walk_items(work, state, mode, ctx),
      else: walk_items([{:repeat, step, condition, run + 1, total} | work], state, mode, ctx)
  end

  defp walk_items([{:prefix, prefix} | work], state, mode, ctx), do: walk_items(work, %{state | label_prefix: prefix}, mode, ctx)

  defp walk_items([{:enter, call_stack, prefix} | work], state, mode, ctx),
    do: walk_items(work, %{state | call_stack: call_stack, label_prefix: prefix}, mode, ctx)

  defp walk_items([{:leave, call_stack, prefix} | work], state, mode, ctx),
    do: walk_items(work, %{state | call_stack: call_stack, label_prefix: prefix, bailed: false}, mode, ctx)

  defp walk_items([{:step, %{"kind" => "if"} = step} | work], state, mode, ctx) do
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)
    key = step_key(step, state)
    branch_key = key <> " branch"

    branch =
      case Map.get(state.done, branch_key) do
        nil -> if condition_met?(step, state, ctx), do: "then", else: "else"
        chosen -> chosen
      end

    steps = Enum.filter(step[branch] || [], &(&1["enabled"] != false))
    state = %{state | done: Map.put(state.done, branch_key, branch)}
    reason = if branch == "then", do: "condition met", else: "condition not met"
    condition = GiftPlans.condition_label(step["condition"], state.plan) || "always"

    state =
      if Map.has_key?(state.done, key),
        do: state,
        else: record(state, step, label, :done, "#{reason} (#{condition}), running #{branch}: #{length(steps)} step(s)", ctx)

    walk_items([{:prefix, "#{label} › #{branch} › "}, {:steps, steps}, {:prefix, state.label_prefix} | work], state, mode, ctx)
  end

  defp walk_items([{:step, %{"kind" => "workflow"} = step} | work], state, mode, ctx) do
    label = state.label_prefix <> GiftPlans.step_label(state.plan, step)
    previous = Map.get(state.done, step_key(step, state))

    cond do
      previous not in [nil, :done] ->
        walk_items(work, state, mode, ctx)

      previous == nil and not condition_met?(step, state, ctx) ->
        state = record(state, step, label, :skipped, "condition not met: #{GiftPlans.condition_label(step["condition"], state.plan)}", ctx)
        walk_items(work, state, mode, ctx)

      true ->
        case GiftPlans.definition_for(state.plan, step) do
          {:error, _} ->
            walk_items(work, record(state, step, label, :failed, "no workflow selected, or it was deleted", ctx), mode, ctx)

          {:ok, sub} ->
            if sub["id"] in state.call_stack do
              state = record(state, step, label, :failed, "#{sub["name"]} is already running, skipping to avoid a loop", ctx)
              walk_items(work, state, mode, ctx)
            else
              sub_steps = Enum.filter(sub["steps"], &(&1["enabled"] != false))
              state = if previous, do: state, else: record(state, step, label, :done, "running #{length(sub_steps)} step(s)", ctx)
              nested = [{:enter, [sub["id"] | state.call_stack], label <> " › "}, {:steps, sub_steps}, {:leave, state.call_stack, state.label_prefix}]
              walk_items(nested ++ work, state, mode, ctx)
            end
        end
    end
  end

  defp walk_items([{:step, %{"kind" => kind} = step} | work], state, mode, ctx) when kind in ["bail", "leave"] do
    state =
      case Map.get(state.done, step_key(step, state)) do
        nil -> run_exit_step(step, state, mode, ctx)
        :done -> exit_flag(kind, state)
        _ -> state
      end

    walk_items(work, state, mode, ctx)
  end

  defp walk_items([{:step, step} | work], state, mode, ctx) do
    if Map.has_key?(state.done, step_key(step, state)),
      do: walk_items(work, state, mode, ctx),
      else: {:steps, [call(__MODULE__, :action, [step, work, state, mode])]}
  end

  defp between_work(%{"between" => id} = step, condition, state, run, total) when is_binary(id) do
    prefix = state.label_prefix
    between = %{"id" => "#{step["id"]}:between", "kind" => "workflow", "workflow" => id, "condition" => condition}
    nested_prefix = "#{prefix}(between #{run}/#{total - 1}) "
    between_key = nested_prefix <> to_string(between["id"])
    [{:prefix, nested_prefix}, {:step, between}, {:prefix, prefix}, {:after_between, step, condition, run, total, length(state.steps), between_key}]
  end

  defp between_work(step, condition, _state, run, total), do: [{:repeat, step, condition, run + 1, total}]

  defp workflow_name(%{call_stack: [id | _]} = state) do
    case GiftPlans.find_workflow(state.plan, id) do
      nil -> "the workflow"
      workflow -> workflow["name"]
    end
  end

  defp condition_met?(step, state, ctx), do: GiftPlans.eval_condition(step["condition"], condition_env(state, ctx))

  defp condition_env(state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)
    %{wallet: wallet(state, ctx), owned: owned_names(inventory), inventory: inventory, plan: state.plan, gifts: state.gifts_by_name, refreshes: state.refreshes}
  end

  defp milestone_reached?(%{"kind" => "milestone", "milestone" => id}, state, ctx) when is_binary(id),
    do: GiftPlans.milestone_reached?(state.plan, id, condition_env(state, ctx))

  defp milestone_reached?(_step, _state, _ctx), do: false

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

    if mode == :run and outcome not in [:done, :skipped] and interrupted?(ctx) do
      Ctx.log(ctx, :info, "shop runner: #{label} — interrupted by a pause or focus loss, it will run again on resume")
      :interrupted
    else
      state = record(state, step, label, outcome, detail, ctx)
      after_step(outcome, step, ctx)
      if outcome == :failed, do: %{state | sell_popup_open: false, heal_menu_open: false}, else: state
    end
  end

  defp interrupted?(ctx), do: Ctx.pause_requested?(ctx) or not Capture.focused?()

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
      refreshes: state.refreshes,
      replaced: state.replaced,
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
