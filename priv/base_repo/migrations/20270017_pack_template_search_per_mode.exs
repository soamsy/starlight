defmodule StarlightBot.BaseRepo.Migrations.PackTemplateSearchPerMode do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM plan_templates WHERE kind = 'pack_plans' AND data LIKE '%search_floors%'|)

    for [id, json] <- rows, data = Jason.decode!(json), is_list(data["search_floors"]) do
      floors = data["search_floors"]
      upgraded = Map.put(data, "search_floors", %{"normal" => floors, "hard" => floors})
      repo().query!("UPDATE plan_templates SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
    end
  end

  def down, do: :ok
end
