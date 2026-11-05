defmodule StarlightBot.TeamTemplates do
  import Ecto.Query
  alias StarlightBot.{Data, Plans, Teams}
  alias StarlightBot.BaseRepo, as: Repo

  @plan_fields [gift_plan_id: :gift_plans, battle_plan_id: :battle_plans, pack_plan_id: :pack_plans]
  @columns [gift_plan_id: :gift_plan, battle_plan_id: :battle_plan, pack_plan_id: :pack_plan]

  def writable?, do: Data.base_writable?()

  def list do
    Repo.all(from t in "team_templates", order_by: [asc: t.name], select: %{id: t.id, name: t.name, hooks: t.hooks})
    |> Enum.map(&%{&1 | hooks: decode_list(&1.hooks)})
  rescue
    _ -> []
  end

  def get(id) when is_integer(id) do
    Repo.one(
      from t in "team_templates",
        where: t.id == ^id,
        select: %{id: t.id, name: t.name, hooks: t.hooks, gift_plan: t.gift_plan, battle_plan: t.battle_plan, pack_plan: t.pack_plan}
    )
    |> case do
      nil -> nil
      row -> %{row | hooks: decode_list(row.hooks), gift_plan: decode_map(row.gift_plan), battle_plan: decode_map(row.battle_plan), pack_plan: decode_map(row.pack_plan)}
    end
  end

  def create_from_team(team_id) when is_integer(team_id) do
    with true <- writable?() || {:error, :read_only},
         %{} = team <- Teams.get_team(team_id) || {:error, :not_found} do
      plans =
        for {field, table} <- @plan_fields, into: %{} do
          data =
            case Plans.for_team(team, table) do
              %{data: %{} = data} -> data
              _ -> nil
            end

          {Keyword.fetch!(@columns, field), data && Jason.encode!(data)}
        end

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row = Map.merge(plans, %{name: new_name(team.name), hooks: Jason.encode!(team.hooks), inserted_at: now, updated_at: now})

      case Repo.insert_all("team_templates", [row], returning: [:id]) do
        {1, [%{id: id}]} -> {:ok, id}
        _ -> {:error, :insert_failed}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def delete(id) when is_integer(id) do
    if writable?() do
      {n, _} = Repo.delete_all(from t in "team_templates", where: t.id == ^id)
      if n > 0, do: {:ok, id}, else: {:error, :not_found}
    else
      {:error, :read_only}
    end
  end

  defp new_name(base) do
    existing = Repo.all(from t in "team_templates", select: t.name) |> MapSet.new()

    Stream.concat([base], Stream.iterate(2, &(&1 + 1)) |> Stream.map(&"#{base} #{&1}"))
    |> Enum.find(&(not MapSet.member?(existing, &1)))
  end

  defp decode_list(json) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_map(nil), do: nil

  defp decode_map(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end
end
