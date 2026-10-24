defmodule StarlightBot.Repo.Migrations.ProtectedLists do
  use Ecto.Migration

  @max_floor 15

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM gift_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{"workflows" => workflows} = data} when is_list(workflows) <- Jason.decode(json || ""),
           false <- Map.has_key?(data, "protected_floors") do
        repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(protect_keeps(data)), id])
      end
    end)
  end

  def down, do: :ok

  defp protect_keeps(data) do
    lists = get_in(data, ["library", "lists"]) || []
    keep_by_floor = Map.new(1..@max_floor, &{&1, floor_keep(data, lists, &1)})
    keep_ids = keep_by_floor |> Map.values() |> Enum.reject(&is_nil/1) |> MapSet.new(& &1["id"])
    gifts = lists |> Enum.filter(&MapSet.member?(keep_ids, &1["id"])) |> Enum.flat_map(& &1["gifts"]) |> Enum.uniq()

    protected_floors =
      gifts
      |> Enum.map(fn gift -> {gift, for({floor, keep} <- keep_by_floor, keep && gift in keep["gifts"], do: floor)} end)
      |> Enum.map(fn {gift, floors} -> {gift, Enum.min(floors), Enum.max(floors)} end)
      |> Enum.reject(fn {_gift, from, to} -> from == 1 and to == @max_floor end)
      |> Map.new(fn {gift, from, to} -> {gift, %{"from" => from, "to" => if(to == @max_floor, do: nil, else: to)}} end)

    lists = Enum.map(lists, &if(MapSet.member?(keep_ids, &1["id"]), do: Map.put(&1, "protected", true), else: &1))

    data
    |> Map.update!("workflows", fn workflows -> Enum.map(workflows, &Map.delete(&1, "keep")) end)
    |> put_in(["library", "lists"], lists)
    |> Map.put("protected_floors", protected_floors)
  end

  defp floor_keep(data, lists, floor) do
    with %{"workflow" => workflow_id} <-
           (data["floor_schedule"] || []) |> Enum.filter(&(&1["from_floor"] <= floor)) |> Enum.max_by(& &1["from_floor"], fn -> nil end),
         %{"keep" => keep_id} <- Enum.find(data["workflows"], &(&1["id"] == workflow_id)) do
      Enum.find(lists, &(&1["id"] == keep_id))
    else
      _ -> nil
    end
  end
end
