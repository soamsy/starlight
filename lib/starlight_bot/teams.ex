defmodule StarlightBot.Teams do
  require Logger
  import Ecto.Query
  alias StarlightBot.{BattlePlans, Data, PlanTemplates, Plans, Repo}
  alias StarlightBot.BaseRepo

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

  @template_fields [gift_plan_id: :gift_template_id, battle_plan_id: :battle_template_id, pack_plan_id: :pack_template_id]

  def all_sinners, do: @all_sinners
  def team_types, do: @team_types

  @doc "List the user's own teams (never the shipped templates), with joined-in plan names and a `:missing` field list for incomplete configs."
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
          notes: t.notes,
          gift_plan_id: t.gift_plan_id,
          gift_plan_name: g.name,
          gift_plan_data: g.data,
          battle_plan_id: t.battle_plan_id,
          battle_plan_name: b.name,
          battle_plan_data: b.data,
          pack_plan_id: t.pack_plan_id,
          pack_plan_name: p.name,
          gift_template_id: t.gift_template_id,
          battle_template_id: t.battle_template_id,
          pack_template_id: t.pack_template_id
        }
    )
    |> Enum.map(&decorate/1)
  rescue
    _ -> []
  end

  @doc "The user's own teams followed by the shipped template teams, which carry negative ids."
  def list_all_teams, do: list_teams() ++ list_templates()

  def list_templates do
    BaseRepo.all(from t in "teams", order_by: [asc: t.name], select: %{id: t.id})
    |> Enum.map(&template_team(&1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 |> Map.put(:battle_plan_data, nil) |> decorate() |> Map.put(:template, true)))
  rescue
    _ -> []
  end

  defp template_team(base_id) do
    BaseRepo.one(
      from t in "teams",
        where: t.id == ^base_id,
        select: %{
          id: t.id,
          name: t.name,
          notes: t.notes,
          gift_template_id: t.gift_template_id,
          battle_template_id: t.battle_template_id,
          pack_template_id: t.pack_template_id
        }
    )
    |> case do
      nil ->
        nil

      row ->
        row
        |> Map.put(:id, -row.id)
        |> Map.put(:gift_plan_id, row.gift_template_id && -row.id)
        |> Map.put(:battle_plan_id, row.battle_template_id && -row.id)
        |> Map.put(:pack_plan_id, row.pack_template_id && -row.id)
    end
  end

  @doc "Get a single team by id. Returns nil if not found."
  def get_team(id) when is_integer(id) and id < 0 do
    case template_team(-id) do
      nil -> nil
      team -> team |> Map.put(:gift_plan_data, nil) |> decode_affinity() |> Map.put(:template, true)
    end
  rescue
    _ -> nil
  end

  def get_team(id) when is_integer(id) do
    Repo.one(
      from t in "teams",
        left_join: g in "gift_plans",
        on: g.id == t.gift_plan_id,
        where: t.id == ^id,
        select: %{
          id: t.id,
          name: t.name,
          notes: t.notes,
          gift_plan_id: t.gift_plan_id,
          gift_plan_data: g.data,
          battle_plan_id: t.battle_plan_id,
          pack_plan_id: t.pack_plan_id,
          gift_template_id: t.gift_template_id,
          battle_template_id: t.battle_template_id,
          pack_template_id: t.pack_template_id
        }
    )
    |> decode_affinity()
  rescue
    _ -> nil
  end

  def save_team(%{id: id, name: name} = attrs) when is_integer(id) and id < 0 and is_binary(name) and name != "" do
    if Data.base_writable?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      set = [name: name, updated_at: now] ++ if(Map.has_key?(attrs, :notes), do: [notes: attrs.notes], else: [])
      {n, _} = BaseRepo.update_all(from(t in "teams", where: t.id == ^(-id)), set: set)
      if n > 0, do: {:ok, id}, else: {:error, :not_found}
    else
      {:error, :template_locked}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def save_team(%{id: id}) when is_integer(id) and id < 0, do: {:error, :template_locked}

  def save_team(%{name: name} = attrs) when is_binary(name) and name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = %{
      name: name,
      gift_plan_id: attrs[:gift_plan_id],
      battle_plan_id: attrs[:battle_plan_id],
      pack_plan_id: attrs[:pack_plan_id]
    }

    row = if Map.has_key?(attrs, :notes), do: Map.put(row, :notes, attrs.notes), else: row

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

  def template?(id) when is_integer(id), do: id < 0

  def locked?(%{template: true}), do: not Data.base_writable?()
  def locked?(_team), do: false

  def templatize(id) when is_integer(id) and id > 0 do
    with true <- Data.base_writable?() || {:error, :read_only},
         %{} = team <- get_team(id) || {:error, :not_found},
         {:ok, refs} <- move_plans_to_base(team),
         {:ok, _} <- insert_template_team(team, refs),
         {:ok, _} <- delete_team(id) do
      {:ok, id}
    end
  end

  def templatize(_id), do: {:error, :template_locked}

  defp move_plans_to_base(team) do
    Enum.reduce_while(@plan_fields, {:ok, %{}}, fn {field, table}, {:ok, refs} ->
      column = Keyword.fetch!(@template_fields, field)

      case Plans.for_team(team, table) do
        %{template_id: template_id} when is_integer(template_id) ->
          {:cont, {:ok, Map.put(refs, column, template_id)}}

        %{data: %{} = data} ->
          case PlanTemplates.create(table, data, team.name) do
            {:ok, template_id} -> {:cont, {:ok, Map.put(refs, column, template_id)}}
            {:error, _} = error -> {:halt, error}
          end

        _ ->
          {:cont, {:ok, Map.put(refs, column, nil)}}
      end
    end)
  end

  defp insert_template_team(team, refs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing = BaseRepo.all(from t in "teams", select: t.name) |> MapSet.new()
    name = unique_among(team.name, existing)
    row = Map.merge(refs, %{name: name, notes: team.notes, inserted_at: now, updated_at: now})

    case BaseRepo.insert_all("teams", [row], returning: [:id]) do
      {1, [%{id: id}]} -> {:ok, -id}
      _ -> {:error, :insert_failed}
    end
  end

  def create_from_template(id) when is_integer(id) and id < 0 do
    case get_team(id) do
      nil ->
        {:error, :not_found}

      team ->
        with {:ok, new_id} <- save_team(%{name: unique_name(team.name), notes: team.notes}),
             :ok <- copy_template_plans(team, new_id),
             :ok <- ensure_plans(new_id) do
          {:ok, new_id}
        end
    end
  end

  def create_from_template(_id), do: {:error, :not_found}

  defp copy_template_plans(team, new_id) do
    Enum.reduce_while(@plan_fields, :ok, fn {field, table}, :ok ->
      with %{data: %{} = data} <- Plans.for_team(team, table),
           {:ok, plan_id} <- Plans.save(table, %{name: Plans.new_name(table, new_id), data: data, team_id: new_id}),
           {:ok, _} <- set_plan(new_id, field, plan_id) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end

  def ensure_plans(team_id) when is_integer(team_id) do
    team = get_team(team_id)

    Enum.reduce_while(@plan_fields, :ok, fn {field, table}, :ok ->
      with nil <- Map.get(team, field),
           {:ok, plan_id} <- Plans.save(table, %{name: Plans.new_name(table, team_id), data: Plans.blank(table), team_id: team_id}),
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
      nil -> {:error, :not_found}
      %{template: true} -> {:error, :template_locked}
      team -> copy_team(team, unique_name("#{team.name} (copy)"))
    end
  end

  defp copy_team(team, name) do
    with {:ok, new_id} <- save_team(%{name: name, notes: team.notes}) do
      Enum.each(@plan_fields, &copy_plan(team, new_id, &1))
      Enum.each(@template_fields, fn {field, template_field} -> set_template(new_id, field, Map.get(team, template_field)) end)
      with :ok <- ensure_plans(new_id), do: {:ok, new_id}
    end
  end

  defp copy_plan(team, new_id, {field, table}) do
    active = Map.get(team, field)

    for %{id: plan_id} <- Plans.list_for_team(table, team.id),
        %{data: data} <- [Plans.get(table, plan_id)],
        {:ok, copy_id} <- [Plans.save(table, %{name: Plans.new_name(table, new_id), data: data, team_id: new_id})],
        plan_id == active do
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

  def template_field(field), do: Keyword.fetch!(@template_fields, field)

  def set_template(team_id, field, template_id) when is_integer(team_id) and team_id < 0 and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] and (is_integer(template_id) or is_nil(template_id)) do
    if Data.base_writable?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {n, _} = BaseRepo.update_all(from(t in "teams", where: t.id == ^(-team_id)), set: [{template_field(field), template_id}, updated_at: now])
      if n > 0, do: {:ok, team_id}, else: {:error, :not_found}
    else
      {:error, :template_locked}
    end
  end

  def set_template(team_id, field, template_id) when is_integer(team_id) and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] and (is_integer(template_id) or is_nil(template_id)) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(t in "teams", where: t.id == ^team_id), set: [{template_field(field), template_id}, updated_at: now])
    if n > 0, do: {:ok, team_id}, else: {:error, :not_found}
  end

  defp template_data(_table, nil), do: nil

  defp template_data(table, template_id) do
    kind = Atom.to_string(table)

    case PlanTemplates.get(template_id) do
      %{kind: ^kind, data: %{} = data} -> data
      _ -> nil
    end
  end

  def set_plan(team_id, field, plan_id) when is_integer(team_id) and field in [:gift_plan_id, :battle_plan_id, :pack_plan_id] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(t in "teams", where: t.id == ^team_id), set: [{field, plan_id}, updated_at: now])
    if n > 0, do: {:ok, team_id}, else: {:error, :not_found}
  end

  @doc "Delete a team by id. Shipped template teams can only be deleted while authoring."
  def delete_team(id) when is_integer(id) and id < 0 do
    if Data.base_writable?() do
      {n, _} = BaseRepo.delete_all(from t in "teams", where: t.id == ^(-id))
      if n > 0, do: {:ok, id}, else: {:error, :not_found}
    else
      {:error, :read_only}
    end
  end

  def delete_team(id) when is_integer(id) do
    team = get_team(id)
    {n, _} = Repo.delete_all(from t in "teams", where: t.id == ^id)

    if n > 0 do
      Plans.delete_for_team(id)

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

  defp unique_name(base), do: unique_among(base, Repo.all(from t in "teams", select: t.name) |> MapSet.new())

  defp unique_among(base, existing) do
    if MapSet.member?(existing, base) do
      n = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(existing, "#{base} #{&1}")))
      "#{base} #{n}"
    else
      base
    end
  end

  defp decode_affinity(nil), do: nil

  defp decode_affinity(%{gift_plan_data: json} = team) do
    data =
      case template_data(:gift_plans, team.gift_template_id) || (json && Jason.decode(json)) do
        {:ok, %{} = data} -> data
        %{} = data -> data
        _ -> %{}
      end

    affinity = if is_binary(data["affinity"]), do: data["affinity"], else: nil
    grace_picks = if is_list(data["grace_picks"]), do: data["grace_picks"], else: []

    team
    |> Map.put(:template, false)
    |> Map.put(:affinity, affinity)
    |> Map.put(:grace_picks, grace_picks)
    |> Map.delete(:gift_plan_data)
  end

  defp decorate(team) do
    {data, team} = Map.pop(team, :battle_plan_data)
    {gift_json, team} = Map.pop(team, :gift_plan_data)

    gift_data =
      case template_data(:gift_plans, team.gift_template_id) || (gift_json && Jason.decode(gift_json)) do
        {:ok, %{} = gift_data} -> gift_data
        %{} = gift_data -> gift_data
        _ -> %{}
      end

    team = Map.put(team, :affinity, if(is_binary(gift_data["affinity"]) and gift_data["affinity"] != "", do: gift_data["affinity"]))

    decoded =
      case template_data(:battle_plans, team.battle_template_id) || (data && Jason.decode(data)) do
        {:ok, %{} = data} -> data
        %{} = data -> data
        _ -> nil
      end

    lineup_issues = if decoded, do: BattlePlans.lineup_issues(decoded), else: []

    profile_ids =
      if decoded do
        assigned = BattlePlans.profiles(decoded)
        Enum.flat_map(@all_sinners, &Map.get(assigned, &1, []))
      else
        []
      end

    missing =
      [
        is_nil(team.gift_plan_id) and :gift_plan,
        is_nil(team.battle_plan_id) and :battle_plan,
        lineup_issues != [] and :lineup,
        is_nil(team.pack_plan_id) and :pack_plan
      ]
      |> Enum.filter(& &1)

    assigned = if decoded, do: BattlePlans.assigned_profiles(decoded), else: %{}

    team |> Map.put(:template, false) |> Map.put(:missing, missing) |> Map.put(:profile_ids, profile_ids) |> Map.put(:assigned, assigned)
  end
end
