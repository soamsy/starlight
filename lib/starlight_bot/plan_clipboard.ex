defmodule StarlightBot.PlanClipboard do
  alias StarlightBot.{BattlePlans, SinnerProfiles}

  @kinds %{gift_plans: "gift", battle_plans: "battle", pack_plans: "pack"}

  def encode(table, team_name, data) do
    Jason.encode!(%{"starlight_plan" => Map.fetch!(@kinds, table), "name" => team_name, "data" => data})
  end

  def decode(text, table) do
    kind = Map.fetch!(@kinds, table)

    case Jason.decode(text) do
      {:ok, %{"starlight_plan" => ^kind, "data" => %{} = data}} -> validate(table, data)
      {:ok, %{"starlight_plan" => other}} when is_binary(other) -> {:error, "That clipboard holds a #{other} plan, not a #{kind} plan."}
      _ -> {:error, "The clipboard doesn't hold a Starlight plan."}
    end
  end

  def warnings(:battle_plans, data) do
    by_id = Map.new(SinnerProfiles.list(), &{&1.id, &1})

    case for({sinner, id} <- BattlePlans.profiles(data), not usable?(by_id[id]), do: SinnerProfiles.label(sinner)) do
      [] -> []
      sinners -> ["No usable sinner profile here for #{sinners |> Enum.sort() |> Enum.join(", ")}. Their rules are skipped until you pick one."]
    end
  end

  def warnings(_table, _data), do: []

  defp validate(:battle_plans, %{"version" => 4, "playbooks" => [_ | _], "profiles" => profiles} = data) when is_map(profiles), do: {:ok, data}
  defp validate(:battle_plans, %{"version" => 4, "playbooks" => [_ | _]} = data) when not is_map_key(data, "profiles"), do: {:ok, data}
  defp validate(:battle_plans, _data), do: {:error, "That battle plan isn't a version 4 plan this app can read."}
  defp validate(_table, data), do: {:ok, data}

  defp usable?(%{locator_hook: hook}) when is_binary(hook) and hook != "", do: true
  defp usable?(_profile), do: false
end
