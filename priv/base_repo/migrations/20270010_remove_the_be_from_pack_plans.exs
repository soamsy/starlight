defmodule StarlightBot.BaseRepo.Migrations.RemoveTheBeFromPackPlans do
  use Ecto.Migration

  @pack_id "thm_116"

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM plan_templates WHERE kind = 'pack_plans' AND data LIKE '%thm_116%'|)

    for [id, json] <- rows, data = Jason.decode!(json), stripped = strip(data), stripped != data do
      repo().query!("UPDATE plan_templates SET data = ? WHERE id = ?", [Jason.encode!(stripped), id])
    end
  end

  def down, do: :ok

  defp strip(%{} = data) do
    data
    |> then(&if(is_map(&1["packs"]), do: Map.put(&1, "packs", Map.delete(&1["packs"], @pack_id)), else: &1))
    |> then(&if(is_map(&1["order"]), do: put_order(&1, strip_order(&1["order"])), else: &1))
  end

  defp strip_order(order) do
    order
    |> Map.new(fn {mode, floors} -> {mode, floors |> Map.new(fn {floor, ids} -> {floor, List.delete(ids, @pack_id)} end) |> Map.reject(fn {_floor, ids} -> ids == [] end)} end)
    |> Map.reject(fn {_mode, floors} -> floors == %{} end)
  end

  defp put_order(data, order) when order == %{}, do: Map.delete(data, "order")
  defp put_order(data, order), do: Map.put(data, "order", order)

  defp strip(other), do: other
end
