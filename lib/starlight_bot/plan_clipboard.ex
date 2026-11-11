defmodule StarlightBot.PlanClipboard do
  alias StarlightBot.{BattlePlans, SinnerProfiles, ThemePacks}
  alias StarlightBot.PackPlans.{Legacy, Resolver}

  @gift_version StarlightBot.GiftPlans.version()
  @kinds %{gift_plans: "gift", battle_plans: "battle", pack_plans: "pack"}
  @format_version 1
  @pack_version 2
  @battle_version 4
  @newer "That clipboard was made by a newer version of Starlight. Update the app to paste it."

  def encode(table, team_name, data) do
    Jason.encode!(%{"v" => @format_version, "starlight_plan" => Map.fetch!(@kinds, table), "name" => team_name, "data" => data})
  end

  def decode(text, table) do
    kind = Map.fetch!(@kinds, table)

    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
      {:ok, %{"starlight_plan" => ^kind, "data" => %{} = data}} -> validate(table, data)
      {:ok, %{"starlight_plan" => other}} when is_binary(other) -> {:error, "That clipboard holds a #{other} plan, not a #{kind} plan."}
      _ -> {:error, "The clipboard doesn't hold a Starlight plan."}
    end
  end

  def encode_milestone(milestone), do: Jason.encode!(%{"v" => @format_version, "starlight_milestone" => milestone})

  def decode_milestone(text) do
    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
      {:ok, %{"starlight_milestone" => %{"id" => id, "name" => name} = milestone}} when is_binary(id) and is_binary(name) -> validate_milestone(milestone)
      {:ok, %{"starlight_plan" => kind}} when is_binary(kind) -> {:error, "That clipboard holds a whole #{kind} plan, not a milestone."}
      _ -> {:error, "The clipboard doesn't hold a Starlight milestone."}
    end
  end

  def encode_entries(entries), do: Jason.encode!(%{"v" => @format_version, "starlight_entries" => entries})

  def decode_entries(text) do
    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
      {:ok, %{"starlight_entries" => [_ | _] = entries}} when is_list(entries) ->
        if Enum.all?(entries, &(is_map(&1) and is_list(&1["floors"]))),
          do: {:ok, entries},
          else: {:error, "Those entries are malformed and can't be pasted."}

      _ ->
        {:error, "The clipboard doesn't hold Starlight entries."}
    end
  end

  def encode_playbook(playbook), do: Jason.encode!(%{"v" => @format_version, "starlight_playbook" => playbook})

  def decode_playbook(text, kind) do
    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
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

  def encode_actions(kind, actions), do: Jason.encode!(%{"v" => @format_version, "starlight_actions" => %{"kind" => kind, "actions" => actions}})

  def decode_actions(text, kind) do
    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
      {:ok, %{"starlight_actions" => %{"kind" => ^kind, "actions" => [_ | _] = actions}}} ->
        if valid_actions?(actions), do: {:ok, actions}, else: {:error, "Those actions are malformed and can't be pasted."}

      {:ok, %{"starlight_actions" => %{"kind" => other}}} when is_binary(other) ->
        {:error, "That clipboard holds #{other} actions, not #{kind} actions."}

      {:ok, %{"starlight_playbook" => _}} ->
        {:error, "That clipboard holds a whole playbook, not actions."}

      _ ->
        {:error, "The clipboard doesn't hold Starlight actions."}
    end
  end

  def encode_lineup(lineup), do: Jason.encode!(%{"v" => @format_version, "starlight_lineup" => lineup})

  def decode_lineup(text) do
    case Jason.decode(text) do
      {:ok, %{"v" => v}} when is_integer(v) and v > @format_version -> {:error, @newer}
      {:ok, %{"starlight_lineup" => %{"name" => name, "sinners" => sinners} = lineup}} when is_binary(name) and is_list(sinners) ->
        if Enum.all?(sinners, &is_binary/1), do: {:ok, lineup}, else: {:error, "That lineup is malformed and can't be pasted."}

      {:ok, %{"starlight_plan" => plan_kind}} when is_binary(plan_kind) ->
        {:error, "That clipboard holds a whole #{plan_kind} plan, not a lineup."}

      _ ->
        {:error, "The clipboard doesn't hold a Starlight lineup."}
    end
  end

  def warnings(:battle_plans, data) do
    by_id = Map.new(SinnerProfiles.list(), &{&1.id, &1})

    case for({sinner, ids} <- BattlePlans.profiles(data), not Enum.any?(ids, &usable?(by_id[&1])), do: SinnerProfiles.label(sinner)) do
      [] -> []
      sinners -> ["No usable sinner profile here for #{sinners |> Enum.sort() |> Enum.join(", ")}. Their rules are skipped until you pick one."]
    end
  end

  def warnings(_table, _data), do: []

  defp validate(:battle_plans, %{"version" => v}) when is_integer(v) and v > @battle_version, do: {:error, @newer}
  defp validate(:pack_plans, %{"version" => v}) when is_integer(v) and v > @pack_version, do: {:error, @newer}
  defp validate(:gift_plans, %{"version" => v}) when is_integer(v) and v > @gift_version, do: {:error, @newer}
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

  defp valid_action?(%{"type" => "if", "then" => then_actions} = block),
    do: valid_actions?(then_actions) and (is_nil(block["else"]) or valid_actions?(block["else"])) and valid_elifs?(block["elifs"])
  defp valid_action?(%{"type" => "schedule", "segments" => segments}) when is_list(segments), do: Enum.all?(segments, &(is_map(&1) and valid_actions?(&1["actions"])))
  defp valid_action?(%{"type" => type}) when type not in ["if", "schedule"], do: is_binary(type)
  defp valid_action?(_action), do: false

  defp valid_elifs?(nil), do: true
  defp valid_elifs?(elifs) when is_list(elifs), do: Enum.all?(elifs, &(is_map(&1) and is_binary(&1["id"]) and valid_actions?(&1["actions"])))
  defp valid_elifs?(_elifs), do: false

  defp usable?(nil), do: false
  defp usable?(profile), do: SinnerProfiles.locator_hooks(profile) != []
end
