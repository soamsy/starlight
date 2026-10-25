defmodule StarlightBot.Automation.Shop.Actions.SkillReplace do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(%{"sinner" => nil}, _definition, state, _ctx), do: {:failed, "no sinner selected", state}
  def run(%{"options" => []}, _definition, state, _ctx), do: {:failed, "no replacement options selected", state}

  def run(%{"sinner" => sinner, "options" => options}, _definition, state, ctx) do
    cost = RunMemory.cost(ctx)

    cond do
      MapSet.member?(state.replaced, sinner) ->
        {:skipped, "#{sinner} was already replaced in this shop", state}

      is_integer(cost) and cost < GiftPlans.skill_replace_cost() ->
        {:skipped, "cost #{cost} is below #{GiftPlans.skill_replace_cost()}", state}

      true ->
        replace(sinner, options, state, ctx)
    end
  end

  def run_entries(entries, state, ctx) do
    attempts = for entry <- entries, sinner <- entry.sinners, entry.options != [], do: %{"sinner" => sinner, "options" => entry.options}

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
        {:done, "replaced #{sinner} #{option_label(option)}", %{state | replaced: MapSet.put(state.replaced, sinner)}}

      {:error, :no_hook} ->
        {:failed, "no shop_replace hook for #{sinner}", state}

      {:error, :not_offered} ->
        {:skipped, "this shop's skill replacement isn't for #{sinner}", state}

      {:error, :already_purchased} ->
        {:skipped, "skill replacement already purchased in this shop", state}

      {:error, :no_option_available} ->
        Ops.recover_to_shop(ctx)
        {:skipped, "none of #{Enum.map_join(options, ", ", &option_label/1)} could be confirmed", state}

      {:error, reason} ->
        {:failed, inspect(reason), state}
    end
  end

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
