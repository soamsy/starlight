defmodule StarlightBot.Repo.Migrations.ClearAffinitylessFusions do
  use Ecto.Migration

  def up do
    blocked = blocked_gifts()

    if MapSet.size(blocked) > 0 do
      %{rows: rows} = repo().query!(~s|SELECT id, data FROM gift_plans WHERE data LIKE '%"tiered"%'|)

      for [id, json] <- rows, data = Jason.decode!(json), converted = convert(data, blocked), converted != data do
        repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
      end
    end
  end

  def down, do: :ok

  defp convert(%{"subject" => %{"gift" => name}, "fusion" => %{"type" => "tiered"}} = entry, blocked) do
    if MapSet.member?(blocked, name) do
      entry |> Map.put("fusion", nil) |> Map.update("floors", [], fn floors -> Enum.map(floors, &Map.put(&1, "fuse", false)) end)
    else
      convert_children(entry, blocked)
    end
  end

  defp convert(%{} = map, blocked), do: convert_children(map, blocked)
  defp convert(list, blocked) when is_list(list), do: Enum.map(list, &convert(&1, blocked))
  defp convert(other, _blocked), do: other

  defp convert_children(map, blocked), do: Map.new(map, fn {key, value} -> {key, convert(value, blocked)} end)

  defp blocked_gifts do
    {:ok, conn} = Exqlite.Sqlite3.open(StarlightBot.Data.paths().base, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT name FROM ego_gifts WHERE (affinity IS NULL OR affinity IN ('', 'none'))")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
      MapSet.new(rows, fn [name] -> name end)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end
end
