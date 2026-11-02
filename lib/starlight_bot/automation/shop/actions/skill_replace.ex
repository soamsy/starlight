defmodule StarlightBot.Automation.Shop.Actions.SkillReplace do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(%{"sinner" => nil}, _definition, state, _ctx), do: {:failed, "no sinner selected", state}

  def run(%{"sinner" => sinner, "target" => target, "lock_s2" => lock_s2?}, _definition, state, ctx) do
    cost = RunMemory.cost(ctx)
    wanted = GiftPlans.useful_skill_options(distribution(sinner, ctx), target, lock_s2?)
    options = Enum.filter(wanted, &(affordable?(&1, cost) and not MapSet.member?(state.failed_replace_options, {sinner, &1})))

    cond do
      wanted == [] ->
        {:skipped, "#{sinner} already has the wanted skills", state}

      MapSet.member?(state.replaced, sinner) ->
        {:skipped, "#{sinner} was already replaced in this shop", state}

      is_integer(cost) and cost < GiftPlans.skill_replace_cost() ->
        {:skipped, "cost #{cost} is below #{GiftPlans.skill_replace_cost()}", state}

      options == [] ->
        {:skipped, "cost #{cost} can't afford #{Enum.map_join(wanted, ", ", &option_label/1)}, or they already failed this shop", state}

      true ->
        replace(sinner, options, state, ctx)
    end
  end

  defp affordable?(option, cost), do: not is_integer(cost) or cost >= GiftPlans.skill_option_cost(option)

  def run_entries(entries, state, ctx) do
    attempts = for entry <- entries, sinner <- entry.sinners, do: %{"sinner" => sinner, "target" => entry.target, "lock_s2" => entry.lock_s2}

    Enum.reduce_while(attempts, {[], false, state}, fn step, {lines, _acted?, state} ->
      case run(step, nil, state, ctx) do
        {:done, detail, state} -> {:halt, {lines ++ [detail], true, state}}
        {:failed, detail, state} -> {:cont, {lines ++ ["skill replace: #{detail}"], false, state}}
        {:skipped, "skill replacement already purchased in this shop", state} -> {:halt, {lines, false, state}}
        {:skipped, _detail, state} -> {:cont, {lines, false, state}}
      end
    end)
  end

  defp replace(sinner, options, state, ctx) do
    case Ops.replace_skill(sinner, options, ctx) do
      {:ok, option} ->
        RunMemory.add_skill_replace(ctx, sinner, option)
        {:done, "replaced #{sinner} #{option_label(option)}", %{state | replaced: MapSet.put(state.replaced, sinner)}}

      {:error, :no_hook} ->
        {:failed, "no shop_replace hook for #{sinner}", state}

      {:error, :not_offered} ->
        {:skipped, "this shop's skill replacement isn't for #{sinner}", state}

      {:error, :already_purchased} ->
        {:skipped, "skill replacement already purchased in this shop", state}

      {:error, {:no_option_available, tried}} ->
        Ops.recover_to_shop(ctx)
        failed = Enum.reduce(tried, state.failed_replace_options, &MapSet.put(&2, {sinner, &1}))
        {:skipped, "none of #{Enum.map_join(tried, ", ", &option_label/1)} could be confirmed", %{state | failed_replace_options: failed}}

      {:error, reason} ->
        {:failed, inspect(reason), state}
    end
  end

  def pending?(sinner, entry, ctx), do: GiftPlans.useful_skill_options(distribution(sinner, ctx), entry.target, entry.lock_s2) != []

  defp distribution(sinner, ctx), do: ctx |> RunMemory.skill_replaces() |> Map.get(sinner) |> GiftPlans.skill_distribution()

  def preview(%{"sinner" => sinner}, _definition, state, _ctx) when is_binary(sinner) do
    case Ops.skill_replace_offer(sinner) do
      :offered -> {:would_run, "offer is for #{sinner}", state}
      :already_purchased -> {:would_run, "already purchased in this shop", state}
      :not_offered -> {:would_run, "offer isn't for #{sinner}", state}
      :no_hook -> {:failed, "no shop_replace hook for #{sinner}", state}
    end
  end

  def preview(_step, _definition, state, _ctx), do: {:failed, "no sinner selected", state}

  defp option_label("s" <> <<from::binary-size(1)>> <> "_s" <> to), do: "S#{from}→S#{to}"
end
