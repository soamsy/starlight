defmodule StarlightBot.Automation.Scripts.ShopRunner do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.{Actions, Ops}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}

  @actions %{
    "budget" => Actions.Budget,
    "refresh" => Actions.Refresh,
    "buy_list" => Actions.BuyList,
    "fixed_fusion" => Actions.FixedFusion,
    "tiered_fusion" => Actions.TieredFusion,
    "sell" => Actions.Sell,
    "uptie" => Actions.Uptie,
    "affinity_refresh" => Actions.AffinityRefresh
  }
  @previews %{
    "tiered_fusion" => Actions.TieredFusion,
    "sell" => Actions.Sell,
    "uptie" => Actions.Uptie
  }

  def run(ctx), do: execute(:run, ctx)

  def dry_run(ctx), do: execute(:dry_run, ctx)

  defp execute(mode, ctx) do
    Ops.detect_and_update_cost(ctx)

    with {:ok, _} <- Ops.check_inventory(ctx),
         {:ok, plan} <- fetch_plan(ctx),
         {:ok, workflow} <- fetch_workflow(plan, ctx) do
      state = initial_state(plan, workflow, ctx)
      Ctx.log(ctx, :info, "shop runner: floor #{state.floor}, #{state.shop_type} shop, workflow #{workflow["name"]}")

      final =
        workflow["steps"]
        |> Enum.filter(&(&1["enabled"] != false))
        |> Enum.reduce(state, &run_step(&1, &2, mode, ctx))

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

  defp initial_state(plan, workflow, ctx) do
    gifts = EgoGifts.list_gifts()

    state = %{
      plan: plan,
      workflow: workflow,
      floor: RunMemory.floor(ctx),
      shop_type: Ops.shop_type(),
      reserve: 0,
      gifts_by_name: Map.new(gifts, &{&1.name, &1}),
      gifts_by_id: Map.new(gifts, &{&1.id, &1}),
      protected: GiftPlans.protected_set(plan, workflow, gifts),
      steps: []
    }

    RunMemory.put_shop_plan(ctx, trace(state))
    state
  end

  defp run_step(step, state, mode, ctx) do
    label = GiftPlans.step_label(state.plan, step)
    env = %{wallet: wallet(state, ctx), owned: owned_names(ctx)}

    {outcome, detail, state} =
      cond do
        not GiftPlans.eval_condition(step["condition"], env) ->
          {:skipped, "condition not met: #{GiftPlans.condition_label(step["condition"])}", state}

        mode == :dry_run and step["kind"] != "budget" ->
          preview(step, state, ctx)

        true ->
          dispatch(step, state, ctx)
      end

    Ctx.log(ctx, log_kind(outcome), "shop runner: #{label} — #{outcome}: #{detail}")
    after_step(outcome, step, ctx)

    state = %{state | steps: state.steps ++ [%{id: step["id"], label: label, outcome: outcome, detail: detail}]}
    RunMemory.put_shop_plan(ctx, trace(state))
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

  defp after_step(outcome, %{"kind" => kind}, ctx) when outcome in [:done, :partial] and kind != "budget" do
    Ops.detect_and_update_cost(ctx)
  end

  defp after_step(_outcome, _step, _ctx), do: :ok

  defp wallet(state, ctx) do
    case RunMemory.cost(ctx) do
      nil -> nil
      cost -> cost - state.reserve
    end
  end

  defp owned_names(ctx), do: RunMemory.ego_gifts(ctx) |> Map.values() |> MapSet.new(& &1.name)

  defp log_kind(outcome) when outcome in [:done, :partial, :would_run], do: :ok
  defp log_kind(:failed), do: :error
  defp log_kind(_outcome), do: :info

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
