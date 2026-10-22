defmodule StarlightBot.Teams do
  require Logger
  import Ecto.Query
  alias StarlightBot.{BattlePlans, Repo}

  @team_groups [
    {"Status", ~w(burn bleed tremor rupture sinking poise charge)},
    {"Sin", ~w(wrath lust sloth gluttony gloom pride envy)},
    {"Damage Type", ~w(slash pierce blunt)},
    {"Fixer", ~w(zwei shi cinq liu seven devyat dieci oufi)},
    {"Syndicate", ~w(fingers thumb index middle ring pinky)}
  ]

  @team_types Enum.flat_map(@team_groups, &elem(&1, 1))

  @all_sinners ~w(
    yi_sang faust don_quixote ryoshu meursault hong_lu
    heathcliff ishmael rodion sinclair outis gregor
  )

  def all_sinners, do: @all_sinners
  def team_types, do: @team_types

  @doc "List all teams, with joined-in plan names and a `:missing` field list for incomplete configs."
  def list_teams do
    Repo.all(
      from t in "teams",
        left_join: g in "gift_plans",
        on: g.id == t.gift_plan_id,
        left_join: b in "battle_plans",
        on: b.id == t.battle_plan_id,
        left_join: p in "pack_plans",
        on: p.id == t.pack_plan_id,
        order_by: [asc: t.name],
        select: %{
          id: t.id,
          name: t.name,
          hooks: t.hooks,
          gift_plan_id: t.gift_plan_id,
          gift_plan_name: g.name,
          battle_plan_id: t.battle_plan_id,
          battle_plan_name: b.name,
          battle_plan_data: b.data,
          pack_plan_id: t.pack_plan_id,
          pack_plan_name: p.name
        }
    )
    |> Enum.map(&(&1 |> decode_hooks() |> decorate()))
  rescue
    _ -> []
  end

  @doc "Get a single team by id. Returns nil if not found."
  def get_team(id) when is_integer(id) do
    Repo.one(
      from t in "teams",
        left_join: g in "gift_plans",
        on: g.id == t.gift_plan_id,
        where: t.id == ^id,
        select: %{
          id: t.id,
          name: t.name,
          hooks: t.hooks,
          gift_plan_id: t.gift_plan_id,
          gift_plan_data: g.data,
          battle_plan_id: t.battle_plan_id,
          pack_plan_id: t.pack_plan_id
        }
    )
    |> decode_hooks()
    |> decode_affinity()
  rescue
    _ -> nil
  end

  def save_team(%{name: name} = attrs) when is_binary(name) and name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = %{
      name: name,
      hooks: Jason.encode!(attrs[:hooks] || []),
      gift_plan_id: attrs[:gift_plan_id],
      battle_plan_id: attrs[:battle_plan_id],
      pack_plan_id: attrs[:pack_plan_id]
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
    save_team(%{name: unique_name("New Team")})
  end

  def duplicate_team(id) when is_integer(id) do
    case get_team(id) do
      nil -> {:error, :not_found}
      team -> team |> Map.take([:hooks, :gift_plan_id, :battle_plan_id, :pack_plan_id]) |> Map.put(:name, unique_name("#{team.name} (copy)")) |> save_team()
    end
  end

  def set_plan(team_id, field, plan_id) when is_integer(team_id) and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(t in "teams", where: t.id == ^team_id), set: [{field, plan_id}, updated_at: now])
    if n > 0, do: {:ok, team_id}, else: {:error, :not_found}
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
    names = StarlightBot.Hooks.list_names("team")
    grouped = Enum.map(@team_types, &"team_#{&1}")

    groups =
      for {label, types} <- @team_groups,
          hooks = types |> Enum.map(&"team_#{&1}") |> Enum.filter(&(&1 in names)),
          hooks != [],
          do: {label, hooks}

    case names -- grouped do
      [] -> groups
      other -> groups ++ [{"Other", other}]
    end
  end

  def hook_label("team_" <> type), do: String.upcase(type)
  def hook_label(hook), do: hook

  def pick_hook(%{hooks: hooks}, hook) do
    if hook in hooks, do: hook, else: List.first(hooks)
  end

  defp unique_name(base) do
    existing = Repo.all(from t in "teams", select: t.name) |> MapSet.new()

    if MapSet.member?(existing, base) do
      n = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(existing, "#{base} #{&1}")))
      "#{base} #{n}"
    else
      base
    end
  end

  defp decode_hooks(nil), do: nil

  defp decode_hooks(%{hooks: json} = team) do
    hooks =
      case Jason.decode(json || "") do
        {:ok, hooks} when is_list(hooks) -> hooks
        _ -> []
      end

    %{team | hooks: hooks}
  end

  defp decode_affinity(nil), do: nil

  defp decode_affinity(%{gift_plan_data: json} = team) do
    data =
      case json && Jason.decode(json) do
        {:ok, %{} = data} -> data
        _ -> %{}
      end

    affinity = if is_binary(data["affinity"]), do: data["affinity"], else: nil
    grace_picks = if is_list(data["grace_picks"]), do: data["grace_picks"], else: []

    team
    |> Map.put(:affinity, affinity)
    |> Map.put(:grace_picks, grace_picks)
    |> Map.delete(:gift_plan_data)
  end

  defp decorate(team) do
    {data, team} = Map.pop(team, :battle_plan_data)

    lineup_issues =
      case data && Jason.decode(data) do
        {:ok, %{} = data} -> BattlePlans.lineup_issues(data)
        _ -> []
      end

    missing =
      [
        team.hooks == [] and :hook,
        is_nil(team.gift_plan_id) and :gift_plan,
        is_nil(team.battle_plan_id) and :battle_plan,
        lineup_issues != [] and :lineup,
        is_nil(team.pack_plan_id) and :pack_plan
      ]
      |> Enum.filter(& &1)

    Map.put(team, :missing, missing)
  end
end
