defmodule StarlightBot.Plans do
  require Logger
  import Ecto.Query
  alias StarlightBot.{BattlePlans, GiftPlans, PlanCounts, PlanTemplates, Repo, Teams}

  @tables ~w(gift_plans battle_plans pack_plans)a

  @doc "List all rows in `table`, `data` JSON-decoded, ordered by name."
  def list(table) when table in @tables do
    Repo.all(from r in Atom.to_string(table), order_by: [asc: r.name], select: %{id: r.id, name: r.name, data: r.data})
    |> Enum.map(&decode/1)
  rescue
    _ -> []
  end

  @doc "The team's own plans in `table`: `%{id, name, count}` ordered by name."
  def list_for_team(table, team_id) when table in @tables and is_integer(team_id) do
    Repo.all(from r in Atom.to_string(table), where: r.team_id == ^team_id, order_by: [asc: r.name], select: %{id: r.id, name: r.name, data: r.data})
    |> Enum.map(&decode/1)
    |> Enum.map(&%{id: &1.id, name: &1.name, count: PlanCounts.count(table, &1.data)})
  rescue
    _ -> []
  end

  def list_for_team(_table, _team_id), do: []

  def owned_by?(table, id, team_id) when table in @tables and is_integer(id) and is_integer(team_id) do
    Repo.exists?(from r in Atom.to_string(table), where: r.id == ^id and r.team_id == ^team_id)
  end

  def rename(table, id, name) when table in @tables and is_integer(id) and is_binary(name) and name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(r in Atom.to_string(table), where: r.id == ^id), set: [name: name, updated_at: now])
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  rescue
    e in Exqlite.Error ->
      if e.message =~ "UNIQUE", do: {:error, :name_taken}, else: reraise(e, __STACKTRACE__)
  end

  def delete_for_team(team_id) when is_integer(team_id) do
    Enum.each(@tables, &Repo.delete_all(from(r in Atom.to_string(&1), where: r.team_id == ^team_id)))
  end

  @doc "Get a single row by id. Returns nil if not found."
  def get(table, id) when table in @tables and is_integer(id) do
    Repo.one(from r in Atom.to_string(table), where: r.id == ^id, select: %{id: r.id, name: r.name, data: r.data})
    |> decode()
  rescue
    _ -> nil
  end

  @doc """
  The plan a team actually uses for `table`: the template it references when one is
  set and still exists, otherwise its own plan. Carries `:template_id` (nil for the
  team's own plan).
  """
  def for_team(nil, _table), do: nil

  def for_team(team, table) when table in @tables do
    field = plan_field(table)

    with template_id when is_integer(template_id) <- Map.get(team, Teams.template_field(field)),
         kind = Atom.to_string(table),
         %{kind: ^kind, name: name, data: %{} = data} <- PlanTemplates.get(template_id) do
      %{id: Map.get(team, field), name: name, data: data, template_id: template_id}
    else
      _ ->
        with id when is_integer(id) <- Map.get(team, field), %{} = plan <- get(table, id) do
          Map.put(plan, :template_id, nil)
        else
          _ -> nil
        end
    end
  end

  defp plan_field(:gift_plans), do: :gift_plan_id
  defp plan_field(:battle_plans), do: :battle_plan_id
  defp plan_field(:pack_plans), do: :pack_plan_id

  @doc """
  Insert or update a row. `attrs` must include `:name` (string) and `:data`
  (map, JSON-encoded before writing). If `attrs[:id]` is present and exists,
  updates in place; otherwise inserts a new row. Returns `{:ok, id}` or
  `{:error, reason}`.
  """
  def save(table, %{name: name, data: data} = attrs) when table in @tables and is_binary(name) and name != "" do
    table_str = Atom.to_string(table)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    json = Jason.encode!(data)

    case attrs[:id] do
      id when is_integer(id) ->
        {n, _} =
          Repo.update_all(from(r in table_str, where: r.id == ^id), set: [name: name, data: json, updated_at: now])

        if n > 0, do: {:ok, id}, else: {:error, :not_found}

      _ ->
        row = %{name: name, data: json, team_id: attrs[:team_id], inserted_at: now, updated_at: now}

        case Repo.insert_all(table_str, [row], returning: [:id]) do
          {1, [%{id: id}]} -> {:ok, id}
          _ -> {:error, :insert_failed}
        end
    end
  rescue
    e ->
      Logger.error("Plans DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def save(_table, _attrs), do: {:error, :name_and_data_required}

  @doc "Delete a row by id."
  def delete(table, id) when table in @tables and is_integer(id) do
    {n, _} = Repo.delete_all(from r in Atom.to_string(table), where: r.id == ^id)
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  rescue
    e ->
      Logger.error("Plans DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def blank(:gift_plans), do: GiftPlans.blank()
  def blank(:battle_plans), do: BattlePlans.blank()
  def blank(:pack_plans), do: %{"version" => 2, "mode_schedule" => [], "packs" => %{}, "search_floors" => []}

  def new_name(table, team_id) when table in @tables do
    base =
      case team_id && Teams.get_team(team_id) do
        %{name: name} -> name
        _ -> "New Plan"
      end

    unique_name(table, base)
  end

  def unique_name(table, base) when table in @tables do
    existing = Repo.all(from r in Atom.to_string(table), select: r.name) |> MapSet.new()

    if MapSet.member?(existing, base) do
      n = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(existing, "#{base} #{&1}")))
      "#{base} #{n}"
    else
      base
    end
  end

  defp decode(nil), do: nil

  defp decode(%{data: nil} = row), do: %{row | data: nil}

  defp decode(%{data: json} = row) do
    case Jason.decode(json) do
      {:ok, data} -> %{row | data: data}
      {:error, _} -> %{row | data: nil}
    end
  end
end
