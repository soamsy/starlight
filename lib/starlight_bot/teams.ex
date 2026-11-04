defmodule StarlightBot.Teams do
  require Logger
  import Ecto.Query
  alias StarlightBot.{BattlePlans, Plans, Repo}

  @team_groups [
    {"Status", "affinity", ~w(burn bleed tremor rupture sinking poise charge ammo discard)},
    {"Sin", "sin", ~w(wrath lust sloth gluttony gloom pride envy)},
    {"Damage Type", "affinity", ~w(slash pierce blunt)},
    {"Fixer", "fixer", ~w(zwei shi cinq liu seven devyat dieci oufi)},
    {"Syndicate", "syndicate", ~w(fingers thumb index middle ring pinky)},
    {"Other", "other", ~w(heishou ego_gear le_rouge le_noir sisyphe)}
  ]

  @icon_dir_overrides %{"ammo" => "other", "discard" => "other", "fingers" => "other"}

  @icon_dirs for {_label, dir, types} <- @team_groups, type <- types, into: %{}, do: {type, Map.get(@icon_dir_overrides, type, dir)}

  @team_types Enum.flat_map(@team_groups, &elem(&1, 2))

  @all_sinners ~w(
    yi_sang faust don_quixote ryoshu meursault hong_lu
    heathcliff ishmael rodion sinclair outis gregor
  )

  @plan_fields [gift_plan_id: :gift_plans, battle_plan_id: :battle_plans, pack_plan_id: :pack_plans]

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
        order_by: [asc: t.position, asc: t.id],
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
        next_position = (Repo.one(from t in "teams", select: max(t.position)) || -1) + 1
        row = Map.merge(row, %{position: next_position, inserted_at: now, updated_at: now})

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
    with {:ok, id} <- save_team(%{name: unique_name("New Team")}),
         :ok <- ensure_plans(id) do
      {:ok, id}
    end
  end

  def ensure_plans(team_id) when is_integer(team_id) do
    team = get_team(team_id)

    Enum.reduce_while(@plan_fields, :ok, fn {field, table}, :ok ->
      with nil <- Map.get(team, field),
           {:ok, plan_id} <- Plans.save(table, %{name: Plans.new_name(table, team_id), data: Plans.blank(table)}),
           {:ok, _} <- set_plan(team_id, field, plan_id) do
        {:cont, :ok}
      else
        plan_id when is_integer(plan_id) -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def paste_plan(team_id, field, data) when is_integer(team_id) and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] do
    table = Keyword.fetch!(@plan_fields, field)

    with %{} = team <- get_team(team_id),
         target when is_integer(target) <- Map.get(team, field),
         %{name: name} <- Plans.get(table, target) do
      Plans.save(table, %{id: target, name: name, data: data})
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def duplicate_team(id) when is_integer(id) do
    case get_team(id) do
      nil ->
        {:error, :not_found}

      team ->
        with {:ok, new_id} <- team |> Map.take([:hooks]) |> Map.put(:name, unique_name("#{team.name} (copy)")) |> save_team() do
          Enum.each(@plan_fields, &copy_plan(team, new_id, &1))
          with :ok <- ensure_plans(new_id), do: {:ok, new_id}
        end
    end
  end

  defp copy_plan(team, new_id, {field, table}) do
    with plan_id when is_integer(plan_id) <- Map.get(team, field),
         %{data: data} <- Plans.get(table, plan_id),
         {:ok, copy_id} <- Plans.save(table, %{name: Plans.new_name(table, new_id), data: data}) do
      set_plan(new_id, field, copy_id)
    end
  end

  def reorder_teams(ids) when is_list(ids) do
    Repo.transaction(fn ->
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, position} -> Repo.update_all(from(t in "teams", where: t.id == ^id), set: [position: position]) end)
    end)
  end

  def set_plan(team_id, field, plan_id) when is_integer(team_id) and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(t in "teams", where: t.id == ^team_id), set: [{field, plan_id}, updated_at: now])
    if n > 0, do: {:ok, team_id}, else: {:error, :not_found}
  end

  @doc "Delete a team by id."
  def delete_team(id) when is_integer(id) do
    team = get_team(id)
    {n, _} = Repo.delete_all(from t in "teams", where: t.id == ^id)

    if n > 0 do
      Enum.each(@plan_fields, fn {field, table} ->
        if plan_id = Map.get(team, field), do: Plans.delete(table, plan_id)
      end)

      {:ok, id}
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Teams DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def team_hooks do
    names = StarlightBot.Hooks.list_names("team")
    grouped = Enum.map(@team_types, &"team_#{&1}")

    groups =
      for {label, _dir, types} <- @team_groups,
          hooks = types |> Enum.map(&"team_#{&1}") |> Enum.filter(&(&1 in names)),
          hooks != [],
          do: {label, hooks}

    case names -- grouped do
      [] -> groups
      other -> groups ++ [{"Other", other}]
    end
  end

  def hook_label("team_" <> type), do: type |> String.replace("_", " ") |> String.upcase()
  def hook_label(hook), do: hook

  def hook_icon("team_" <> type) do
    case @icon_dirs do
      %{^type => dir} -> "/images/#{dir}/#{type}.webp"
      _ -> nil
    end
  end

  def hook_icon(_hook), do: nil

  def default_hook_icon, do: "/images/other/default.webp"

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

    decoded =
      case data && Jason.decode(data) do
        {:ok, %{} = data} -> data
        _ -> nil
      end

    lineup_issues = if decoded, do: BattlePlans.lineup_issues(decoded), else: []

    profile_ids =
      if decoded do
        assigned = BattlePlans.profiles(decoded)
        for sinner <- @all_sinners, is_integer(assigned[sinner]), do: assigned[sinner]
      else
        []
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

    team |> Map.put(:missing, missing) |> Map.put(:profile_ids, profile_ids)
  end
end
