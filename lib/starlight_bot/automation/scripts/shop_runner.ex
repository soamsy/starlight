defmodule StarlightBot.Automation.Scripts.ShopRunner do
  import StarlightBot.Navigation.DSL, only: [any_of: 1, call: 3, result: 1]
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Automation.Shop.Actions.{Heal, Milestone}
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans, Teams}
  alias StarlightBot.GiftPlans.RefreshCosts
  alias StarlightBot.Navigation.Screens.Shop
  alias StarlightBot.Vision.Capture

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
    Ops.reset_buy_count(ctx)
    Ops.reset_chance_comet(ctx)
    RunMemory.put_cost(ctx, nil)
    Ops.detect_and_update_cost(ctx)
    cost_known? = not is_nil(RunMemory.cost(ctx))

    if not cost_known? do
      Ctx.log(ctx, :info, "shop runner: cost not read yet, assuming #{@assumed_starting_cost} until it is")
      RunMemory.put_cost(ctx, @assumed_starting_cost)
    end

    with {:ok, plan} <- fetch_plan(ctx),
         {:ok, milestones} <- fetch_milestones(plan),
         {:ok, state} <- prepare(milestones, initial_state(plan, ctx), cost_known?, mode, ctx) do
      Ctx.log(ctx, :info, "shop runner: floor #{state.floor}, #{state.shop_type} shop, #{length(milestones)} milestone(s)")
      {:steps, [call(__MODULE__, :work, [milestones, state, mode])]}
    else
      {:skip, reason} ->
        Ctx.log(ctx, :error, "shop runner: #{reason} — doing nothing")
        {:steps, [result({:ok, :no_milestone})]}

      {:error, _} = err ->
        err
    end
  end

  defp prepare(milestones, state, cost_known?, mode, ctx) do
    case quick_route(milestones, state, cost_known?, ctx) do
      :heal ->
        {:ok, state}

      :leave ->
        {:ok, %{state | left: true}}

      :full ->
        keep_open? = mode == :run and sell_first?(hd(milestones), state.floor)

        with {:ok, _} <- Ops.check_inventory(ctx, keep_open?), do: {:ok, %{state | sell_popup_open: keep_open?}}
    end
  end

  defp quick_route(milestones, state, cost_known?, ctx) do
    env = condition_env(state, ctx)

    if Enum.all?(milestones, &GiftPlans.milestone_reached?(state.plan, &1["id"], env)) do
      case heal_need(milestones, state) do
        0 ->
          Ctx.log(ctx, :info, "shop runner: every milestone is reached and nobody needs healing, leaving without checking the inventory")
          :leave

        needed ->
          if cost_known? and wallet(state, ctx) >= needed do
            Ctx.log(ctx, :info, "shop runner: every milestone is reached, healing for #{needed} cost without checking the inventory")
            :heal
          else
            :full
          end
      end
    else
      :full
    end
  end

  defp heal_need(milestones, state) do
    entries =
      milestones
      |> Enum.flat_map(&GiftPlans.resolved_entries(&1, state.floor))
      |> GiftPlans.heal_entries()

    if entries == [] do
      0
    else
      all = Teams.all_sinners()
      fullness_sinners = entries |> Enum.filter(&(&1.subject["action"] in ["heal", "heal_all"])) |> Enum.flat_map(&entry_sinners(&1, all)) |> Enum.uniq()
      sinners = entries |> Enum.flat_map(&entry_sinners(&1, all)) |> Enum.uniq()
      statuses = Heal.statuses(sinners, fullness_sinners)
      dead = for {sinner, %{dead: true}} <- statuses, do: sinner
      hurt = for sinner <- fullness_sinners, not statuses[sinner].dead, not statuses[sinner].full, do: sinner

      {needs, _} =
        Enum.map_reduce(entries, {dead, hurt}, fn entry, {dead, hurt} ->
          {entry_heal_need(entry, dead, hurt), after_entry(entry, dead, hurt)}
        end)

      Enum.sum(needs)
    end
  end

  defp after_entry(%{subject: %{"action" => "revive"}, sinners: sinners}, dead, hurt) do
    revived = Enum.filter(sinners, &(&1 in dead))
    {dead -- revived, Enum.uniq(hurt ++ revived)}
  end

  defp after_entry(_entry, dead, hurt), do: {dead, hurt}

  defp entry_sinners(%{subject: %{"action" => "heal_all"}}, all), do: all
  defp entry_sinners(%{sinners: sinners}, _all), do: sinners

  defp entry_heal_need(%{subject: %{"action" => "heal_all"}, repeat: repeat}, _dead, hurt) do
    times = if repeat == "until_full", do: 1, else: GiftPlans.heal_all_times(repeat)
    if hurt == [], do: 0, else: times * GiftPlans.heal_cost()
  end

  defp entry_heal_need(%{subject: %{"action" => "revive"}, sinners: sinners}, dead, _hurt), do: Enum.count(sinners, &(&1 in dead)) * GiftPlans.heal_cost()
  defp entry_heal_need(%{subject: %{"action" => "heal"}, sinners: sinners}, _dead, hurt), do: Enum.count(sinners, &(&1 in hurt)) * GiftPlans.heal_cost()

  def work([], state, mode, _frame, ctx), do: finish(state, mode, ctx)

  def work(_milestones, %{left: true} = state, mode, _frame, ctx), do: finish(state, mode, ctx)

  def work([milestone | rest], state, mode, _frame, ctx) do
    env = condition_env(state, ctx)

    cond do
      GiftPlans.milestone_reached?(state.plan, milestone["id"], env) and Milestone.heals?(milestone, state) and
          Enum.all?(rest, &GiftPlans.milestone_effectively_reached?(state.plan, &1["id"], env)) ->
        case run_milestone(milestone, close_sell_popup(state, ctx), mode, ctx, :heal_only) do
          :interrupted -> {:error, :window_not_focused}
          state -> {:steps, [call(__MODULE__, :work, [rest, state, mode])]}
        end

      GiftPlans.milestone_reached?(state.plan, milestone["id"], env) ->
        state = record(state, milestone, milestone["name"], :skipped, "required and goals already done, moving on", ctx)
        {:steps, [call(__MODULE__, :work, [rest, state, mode])]}

      true ->
        state = if sell_first?(milestone, state.floor), do: state, else: close_sell_popup(state, ctx)

        case run_milestone(milestone, state, mode, ctx, :full) do
          :interrupted -> {:error, :window_not_focused}
          state -> {:steps, [call(__MODULE__, :work, [remaining(milestone, rest, state, mode, ctx), state, mode])]}
        end
    end
  end

  defp fetch_plan(ctx) do
    case RunMemory.gift_plan(ctx) do
      nil -> {:skip, "no gift plan for this team"}
      data -> {:ok, GiftPlans.normalize(data)}
    end
  end

  defp remaining(%{"endless" => true}, _rest, _state, _mode, _ctx), do: []
  defp remaining(_milestone, rest, _state, :dry_run, _ctx), do: rest

  defp remaining(milestone, rest, state, :run, ctx) do
    if GiftPlans.milestone_reached?(state.plan, milestone["id"], condition_env(state, ctx)), do: rest, else: []
  end

  defp fetch_milestones(plan) do
    case plan["milestones"] do
      [] -> {:skip, "the gift plan has no milestones"}
      milestones -> {:ok, milestones}
    end
  end

  defp initial_state(plan, ctx) do
    gifts = EgoGifts.list_gifts()
    floor = RunMemory.floor(ctx)

    state = %{
      plan: plan,
      floor: floor,
      shop_type: Ops.shop_type(),
      reserve: 0,
      refreshes: 0,
      refresh_used: %{normal: 0, keyword: 0},
      replaced: MapSet.new(),
      failed_replace_options: MapSet.new(),
      sold: %{},
      bought: %{},
      healed: %{},
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1}),
      protected: GiftPlans.keep_set(plan, floor),
      sell_popup_open: false,
      heal_menu_open: false,
      last_heal: nil,
      left: false,
      steps: []
    }

    RunMemory.put_shop_plan(ctx, trace(state))
    state
  end

  defp sell_first?(milestone, floor), do: milestone |> GiftPlans.resolved_entries(floor) |> GiftPlans.sell_entries() != []

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

  defp finish(state, mode, ctx) do
    final = state |> close_sell_popup(ctx) |> close_heal_menu(ctx)
    if mode == :run, do: Ops.close_fuse_popup(ctx)
    RunMemory.put(ctx, :task, nil)
    {:steps, [result({:ok, trace(final)})]}
  end

  def condition_env(state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)

    %{
      wallet: wallet(state, ctx),
      owned: owned_names(inventory),
      inventory: inventory,
      plan: state.plan,
      floor: state.floor,
      gifts: state.gifts_by_name,
      gifts_by_id: state.gifts_by_id,
      refreshes: state.refreshes,
      refresh_costs: RefreshCosts.next_costs(state.plan["grace_picks"], state.refreshes, Map.get(state, :refresh_used, %{normal: 0, keyword: 0})),
      skill_replaces: RunMemory.skill_replaces(ctx),
      case_runs: Map.get(state, :case_runs, %{})
    }
  end

  defp run_milestone(milestone, state, mode, ctx, scope) do
    if mode == :run, do: Ops.close_fuse_popup(ctx)
    label = milestone["name"]
    RunMemory.put(ctx, :task, "shop: #{label}")

    {outcome, detail, state} =
      case {mode, scope} do
        {:dry_run, :heal_only} -> Milestone.heal_only_preview(milestone, state)
        {:dry_run, :full} -> Milestone.preview(nil, milestone, state, ctx)
        {:run, :heal_only} -> Milestone.heal_only(milestone, state, ctx)
        {:run, :full} -> Milestone.run(nil, milestone, state, ctx)
      end

    if mode == :run and outcome not in [:done, :skipped] and interrupted?(ctx) do
      Ctx.log(ctx, :info, "shop runner: #{label} — interrupted by a pause or focus loss, it will run again on resume")
      :interrupted
    else
      state = record(state, milestone, label, outcome, detail, ctx)
      after_step(outcome, ctx)
      if outcome == :failed, do: %{state | sell_popup_open: false, heal_menu_open: false}, else: state
    end
  end

  defp interrupted?(ctx), do: Ctx.pause_requested?(ctx) or not Capture.focused?()

  defp record(state, milestone, label, outcome, detail, ctx) do
    Ctx.log(ctx, log_kind(outcome), "shop runner: #{label} — #{outcome}: #{detail}")
    state = %{state | steps: state.steps ++ [%{id: milestone["id"], label: label, outcome: outcome, detail: detail}]}
    RunMemory.put_shop_plan(ctx, trace(state))
    state
  end

  defp after_step(:failed, ctx) do
    Ops.recover_to_shop(ctx)
    Ops.detect_and_update_cost(ctx)
  end

  defp after_step(outcome, ctx) when outcome in [:done, :partial], do: Ops.detect_and_update_cost(ctx)
  defp after_step(_outcome, _ctx), do: :ok

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

  defp trace(state) do
    %{
      floor: state.floor,
      shop_type: state.shop_type,
      reserve: state.reserve,
      steps: state.steps
    }
  end
end
