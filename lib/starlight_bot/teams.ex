defmodule StarlightBot.Teams do
  require Logger
  import Ecto.Query
  alias StarlightBot.Repo

  @team_types ~w(
    burn bleed tremor rupture sinking poise charge wrath lust sloth
    gluttony gloom pride envy slash pierce blunt
  )

  @doc "List all teams, with joined-in strategy names and a `:missing` field list for incomplete configs."
  def list_teams do
    Repo.all(
      from t in "teams",
        left_join: g in "gift_strategies",
        on: g.id == t.gift_strategy_id,
        left_join: b in "battle_strategies",
        on: b.id == t.battle_strategy_id,
        left_join: p in "theme_pack_plans",
        on: p.id == t.theme_pack_plan_id,
        order_by: [asc: t.name],
        select: %{
          id: t.id,
          name: t.name,
          hook: t.hook,
          sinner_order: t.sinner_order,
          gift_strategy_id: t.gift_strategy_id,
          gift_strategy_name: g.name,
          battle_strategy_id: t.battle_strategy_id,
          battle_strategy_name: b.name,
          theme_pack_plan_id: t.theme_pack_plan_id,
          theme_pack_plan_name: p.name
        }
    )
    |> Enum.map(&decorate/1)
  rescue
    _ -> []
  end

  @doc "Get a single team by id, sinner_order JSON-decoded. Returns nil if not found."
  def get_team(id) when is_integer(id) do
    Repo.one(
      from t in "teams",
        left_join: g in "gift_strategies",
        on: g.id == t.gift_strategy_id,
        where: t.id == ^id,
        select: %{
          id: t.id,
          name: t.name,
          hook: t.hook,
          sinner_order: t.sinner_order,
          gift_strategy_id: t.gift_strategy_id,
          gift_strategy_data: g.data,
          battle_strategy_id: t.battle_strategy_id,
          theme_pack_plan_id: t.theme_pack_plan_id
        }
    )
    |> decode_sinner_order()
    |> decode_affinity()
  rescue
    _ -> nil
  end

  def save_team(%{name: name} = attrs) when is_binary(name) and name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = %{
      name: name,
      hook: blank_to_nil(attrs[:hook]),
      sinner_order: Jason.encode!(attrs[:sinner_order] || []),
      gift_strategy_id: attrs[:gift_strategy_id],
      battle_strategy_id: attrs[:battle_strategy_id],
      theme_pack_plan_id: attrs[:theme_pack_plan_id]
    }

    case attrs[:id] do
      id when is_integer(id) ->
        {n, _} = Repo.update_all(from(t in "teams", where: t.id == ^id), set: Map.to_list(row) ++ [updated_at: now])
        if n > 0, do: {:ok, id}, else: {:error, :not_found}

      _ ->
        row = Map.merge(row, %{inserted_at: now, updated_at: now})

        case Repo.insert_all("teams", [row], returning: [:id]) do
          {1, [%{id: id}]} -> {:ok, id}
          _ -> {:error, :insert_failed}
        end
    end
  rescue
    e ->
      Logger.error("Teams DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def save_team(_), do: {:error, :name_required}

  @doc "Insert a new team with a unique default name and blank fields. Returns `{:ok, id}` or `{:error, reason}`."
  def create_default_team do
    save_team(%{name: unique_default_name()})
  end

  @doc "Delete a team by id."
  def delete_team(id) when is_integer(id) do
    {n, _} = Repo.delete_all(from t in "teams", where: t.id == ^id)
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  rescue
    e ->
      Logger.error("Teams DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def team_hooks do
    names = StarlightBot.Hooks.list_hooks() |> MapSet.new(& &1.name)

    @team_types
    |> Enum.map(&"team_#{&1}")
    |> Enum.filter(&MapSet.member?(names, &1))
    |> Enum.sort()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp unique_default_name do
    existing = Repo.all(from t in "teams", select: t.name) |> MapSet.new()

    if MapSet.member?(existing, "New Team") do
      n = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(existing, "New Team #{&1}")))
      "New Team #{n}"
    else
      "New Team"
    end
  end

  defp decode_sinner_order(nil), do: nil

  defp decode_sinner_order(%{sinner_order: json} = team) do
    order =
      case json && Jason.decode(json) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    %{team | sinner_order: order}
  end

  defp decode_affinity(nil), do: nil

  defp decode_affinity(%{gift_strategy_data: json} = team) do
    affinity =
      case json && Jason.decode(json) do
        {:ok, %{"affinity" => affinity}} when is_binary(affinity) -> affinity
        _ -> nil
      end

    team
    |> Map.put(:affinity, affinity)
    |> Map.delete(:gift_strategy_data)
  end

  defp decorate(team) do
    team = decode_sinner_order(team)

    missing =
      [
        team.hook in [nil, ""] and :hook,
        team.sinner_order == [] and :sinner_order,
        is_nil(team.gift_strategy_id) and :gift_strategy,
        is_nil(team.battle_strategy_id) and :battle_strategy,
        is_nil(team.theme_pack_plan_id) and :theme_pack_plan
      ]
      |> Enum.filter(& &1)

    Map.put(team, :missing, missing)
  end
end
