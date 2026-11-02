defmodule StarlightBot.BaseRepo.Migrations.PackTemplateFloorStatuses do
  use Ecto.Migration

  alias StarlightBot.PackPlans.Legacy

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM plan_templates WHERE kind = 'pack_plans' AND data IS NOT NULL|)
    eligible = eligible_floors()

    for [id, json] <- rows, data = Jason.decode!(json), Legacy.legacy?(data) do
      repo().query!("UPDATE plan_templates SET data = ? WHERE id = ?", [Jason.encode!(Legacy.convert(data, eligible)), id])
    end
  end

  def down, do: :ok

  defp eligible_floors do
    %{rows: rows} = repo().query!("SELECT id, normal_floors, hard_floors FROM theme_packs")
    floors = Map.new(rows, fn [id, normal, hard] -> {id, %{"normal" => decode(normal), "hard" => decode(hard)}} end)
    fn id, mode -> get_in(floors, [id, mode]) || [] end
  end

  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(_json), do: []
end
