defmodule StarlightBot.PlanClipboard do
  alias StarlightBot.{BattlePlans, SinnerProfiles, ThemePacks}
  alias StarlightBot.PackPlans.{Legacy, Resolver}

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

  def encode_milestone(milestone), do: Jason.encode!(%{"starlight_milestone" => milestone})

  def decode_milestone(text) do
    case Jason.decode(text) do
      {:ok, %{"starlight_milestone" => %{"id" => id, "name" => name} = milestone}} when is_binary(id) and is_binary(name) -> validate_milestone(milestone)
      {:ok, %{"starlight_plan" => kind}} when is_binary(kind) -> {:error, "That clipboard holds a whole #{kind} plan, not a milestone."}
      _ -> {:error, "The clipboard doesn't hold a Starlight milestone."}
    end
  end

  def encode_playbook(playbook), do: Jason.encode!(%{"starlight_playbook" => playbook})

  def decode_playbook(text, kind) do
    case Jason.decode(text) do
      {:ok, %{"starlight_playbook" => %{"id" => id, "name" => name, "kind" => ^kind, "actions" => actions} = playbook}} when is_binary(id) and is_binary(name) ->
        if valid_actions?(actions), do: {:ok, playbook}, else: {:error, "That playbook is malformed and can't be pasted."}

      {:ok, %{"starlight_playbook" => %{"kind" => other}}} when is_binary(other) ->
        {:error, "That clipboard holds a #{other} playbook, not a #{kind} playbook."}

      {:ok, %{"starlight_plan" => plan_kind}} when is_binary(plan_kind) ->
        {:error, "That clipboard holds a whole #{plan_kind} plan, not a playbook."}

      _ ->
        {:error, "The clipboard doesn't hold a Starlight playbook."}
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
  defp validate(:pack_plans, data), do: {:ok, Legacy.upgrade(data, &legacy_eligible/2)}
  defp validate(_table, data), do: {:ok, data}

  defp legacy_eligible(id, mode) do
    case Enum.find(ThemePacks.list_theme_packs(), &(&1.id == id)) do
      nil -> []
      pack -> Resolver.eligible_floors(pack, mode)
    end
  end

  defp validate_milestone(milestone) do
    lists = for key <- ["goals", "entries", "refresh", "refresh_floors"], value = milestone[key], do: is_list(value)
    entries = milestone["entries"] || []

    if Enum.all?(lists) and Enum.all?(entries, &(is_map(&1) and is_list(&1["floors"]))),
      do: {:ok, milestone},
      else: {:error, "That milestone is malformed and can't be pasted."}
  end

  defp valid_actions?(actions) when is_list(actions), do: Enum.all?(actions, &valid_action?/1)
  defp valid_actions?(_actions), do: false

  defp valid_action?(%{"type" => "if", "then" => then_actions, "else" => else_actions}), do: valid_actions?(then_actions) and valid_actions?(else_actions)
  defp valid_action?(%{"type" => "schedule", "segments" => segments}) when is_list(segments), do: Enum.all?(segments, &(is_map(&1) and valid_actions?(&1["actions"])))
  defp valid_action?(%{"type" => type}) when type not in ["if", "schedule"], do: is_binary(type)
  defp valid_action?(_action), do: false

  defp usable?(%{locator_hook: hook}) when is_binary(hook) and hook != "", do: true
  defp usable?(_profile), do: false
end
