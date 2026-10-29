defmodule StarlightBot.PlanTemplates do
  import Ecto.Query
  alias StarlightBot.{Data, PlanCounts, PlanIcons}
  alias StarlightBot.BaseRepo, as: Repo

  @kinds ~w(gift_plans battle_plans pack_plans)a

  def writable?, do: Data.base_writable?()

  def list(kind) when kind in @kinds do
    Repo.all(from t in "plan_templates", where: t.kind == ^Atom.to_string(kind), order_by: [asc: t.name], select: %{id: t.id, name: t.name, data: t.data})
    |> then(fn rows ->
      context = PlanIcons.context(kind)

      Enum.map(rows, fn %{data: json} = row ->
        data = json && Jason.decode!(json)
        %{id: row.id, name: row.name, count: PlanCounts.count(kind, data), icons: PlanIcons.icons(kind, data || %{}, context)}
      end)
    end)
  rescue
    _ -> []
  end

  def get(id) when is_integer(id) do
    case Repo.one(from t in "plan_templates", where: t.id == ^id, select: %{id: t.id, kind: t.kind, name: t.name, data: t.data}) do
      %{data: json} = row -> %{row | data: json && Jason.decode!(json)}
      nil -> nil
    end
  end

  def create(kind, data) when kind in @kinds do
    if writable?(), do: insert(kind, new_name(kind), data), else: {:error, :read_only}
  end

  def rename(id, name) when is_integer(id) and is_binary(name) and name != "" do
    if writable?(), do: update_row(id, name: name), else: {:error, :read_only}
  end

  def delete(id) when is_integer(id) do
    if writable?() do
      {n, _} = Repo.delete_all(from t in "plan_templates", where: t.id == ^id)
      if n > 0, do: {:ok, id}, else: {:error, :not_found}
    else
      {:error, :read_only}
    end
  end

  defp insert(kind, name, data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    row = %{kind: Atom.to_string(kind), name: name, data: Jason.encode!(data), inserted_at: now, updated_at: now}

    case Repo.insert_all("plan_templates", [row], returning: [:id]) do
      {1, [%{id: id}]} -> {:ok, id}
      _ -> {:error, :insert_failed}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp update_row(id, fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {n, _} = Repo.update_all(from(t in "plan_templates", where: t.id == ^id), set: fields ++ [updated_at: now])
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  rescue
    e in Exqlite.Error ->
      if e.message =~ "UNIQUE", do: {:error, :name_taken}, else: reraise(e, __STACKTRACE__)
  end

  defp new_name(kind) do
    existing = Repo.all(from t in "plan_templates", where: t.kind == ^Atom.to_string(kind), select: t.name) |> MapSet.new()

    Stream.concat(["New template"], Stream.iterate(2, &(&1 + 1)) |> Stream.map(&"New template #{&1}"))
    |> Enum.find(&(not MapSet.member?(existing, &1)))
  end
end
