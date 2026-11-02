defmodule StarlightBot.Repo.Migrations.PackPlanFloorStatuses do
  use Ecto.Migration

  alias StarlightBot.PackPlans.Legacy

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM pack_plans WHERE data IS NOT NULL|)
    eligible = eligible_floors()

    for [id, json] <- rows, data = Jason.decode!(json), Legacy.legacy?(data) do
      repo().query!("UPDATE pack_plans SET data = ? WHERE id = ?", [Jason.encode!(Legacy.convert(data, eligible)), id])
    end
  end

  def down, do: :ok

  defp eligible_floors do
    {:ok, conn} = Exqlite.Sqlite3.open(StarlightBot.Data.paths().base, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT id, normal_floors, hard_floors FROM theme_packs")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
      floors = Map.new(rows, fn [id, normal, hard] -> {id, %{"normal" => decode(normal), "hard" => decode(hard)}} end)
      fn id, mode -> get_in(floors, [id, mode]) || [] end
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(_json), do: []
end
