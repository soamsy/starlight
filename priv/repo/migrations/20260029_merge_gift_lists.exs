defmodule StarlightBot.Repo.Migrations.MergeGiftLists do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM gift_strategies")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{"version" => 2} = data} <- Jason.decode(json || "") do
        repo().query!("UPDATE gift_strategies SET data = ? WHERE id = ?", [Jason.encode!(upgrade(data)), id])
      end
    end)
  end

  def down, do: :ok

  defp upgrade(data) do
    library = data["library"] || %{}
    {keep_lists, library} = Map.pop(library, "keep_lists", [])
    {shopping_lists, library} = Map.pop(library, "shopping_lists", [])
    done_at = Map.new(shopping_lists, &{&1["id"], &1["done_at"]})
    lists = Enum.map(keep_lists ++ shopping_lists, &Map.delete(&1, "done_at"))

    data
    |> Map.put("version", 3)
    |> Map.put("library", Map.put(library, "lists", lists))
    |> Map.update("workflows", [], fn workflows ->
      Enum.map(workflows, fn workflow -> Map.update(workflow, "steps", [], &Enum.map(&1, fn step -> upgrade_step(step, done_at) end)) end)
    end)
  end

  defp upgrade_step(%{"kind" => "buy_list"} = step, done_at) do
    {max_items, step} = Map.pop(step, "max_items")
    runs = ((step["repeat"] || 0) + 1) * max(max_items || 1, 1)
    step = Map.put(step, "done_at", done_at[step["list"]])

    if runs > 1, do: Map.put(step, "repeat", runs - 1), else: Map.delete(step, "repeat")
  end

  defp upgrade_step(step, _done_at), do: step
end
