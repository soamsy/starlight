defmodule StarlightBot.Automation.Shop.Actions.SkillReplace do
  alias StarlightBot.Automation.Shop.Ops

  def run(%{"sinner" => nil}, _definition, state, _ctx), do: {:failed, "no sinner selected", state}
  def run(%{"options" => []}, _definition, state, _ctx), do: {:failed, "no replacement options selected", state}

  def run(%{"sinner" => sinner, "options" => options}, _definition, state, ctx) do
    case Ops.replace_skill(sinner, options, ctx) do
      {:ok, option} ->
        {:done, "replaced #{sinner} #{option_label(option)}", state}

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
