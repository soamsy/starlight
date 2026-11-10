defmodule StarlightBot.BaseRepo.Migrations.GoalLeafCurrentMilestone do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM plan_templates WHERE kind = 'gift_plans' AND data LIKE '%"goal"%' AND data LIKE '%"op":"goal"%'|)

    for [id, json] <- rows, data = Jason.decode!(json), converted = convert(data), converted != data do
      repo().query!("UPDATE plan_templates SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
    end
  end

  def down, do: :ok

  defp convert(%{"op" => "goal"} = leaf), do: Map.delete(leaf, "milestone")
  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other
end
