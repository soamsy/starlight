defmodule StarlightBot.Repo.Migrations.GiftConditionLeaves do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM gift_plans WHERE data LIKE '%"cost_%' OR data LIKE '%"refreshes_%' OR data LIKE '%_gift"%' OR data LIKE '%_not"%'|)

    for [id, json] <- rows, data = Jason.decode!(json), converted = convert(data), converted != data do
      repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
    end
  end

  def down, do: :ok

  defp convert(%{"op" => "cost_gte"} = leaf), do: %{"op" => "cost", "cmp" => "gte", "value" => leaf["value"]}
  defp convert(%{"op" => "cost_lt"} = leaf), do: %{"op" => "cost", "cmp" => "lte", "value" => leaf["value"] - 1}
  defp convert(%{"op" => "refreshes_gte"} = leaf), do: %{"op" => "refreshes", "cmp" => "gte", "value" => leaf["value"]}
  defp convert(%{"op" => "refreshes_lt"} = leaf), do: %{"op" => "refreshes", "cmp" => "lte", "value" => leaf["value"] - 1}
  defp convert(%{"op" => "has_gift"} = leaf), do: %{"op" => "owns", "gift" => leaf["gift"]}
  defp convert(%{"op" => "missing_gift"} = leaf), do: %{"op" => "owns", "gift" => leaf["gift"], "not" => true}
  defp convert(%{"op" => "milestone_not"} = leaf), do: %{"op" => "milestone", "milestone" => leaf["milestone"], "not" => true}
  defp convert(%{"op" => "goal_not"} = leaf), do: %{"op" => "goal", "milestone" => leaf["milestone"], "goal" => leaf["goal"], "not" => true}
  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other
end
