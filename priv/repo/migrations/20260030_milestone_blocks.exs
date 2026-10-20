defmodule StarlightBot.Repo.Migrations.MilestoneBlocks do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM gift_strategies")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{"version" => 3, "milestones" => milestones} = data} when is_list(milestones) <- Jason.decode(json || "") do
        repo().query!("UPDATE gift_strategies SET data = ? WHERE id = ?", [Jason.encode!(upgrade(data)), id])
      end
    end)
  end

  def down, do: :ok

  defp upgrade(data) do
    library = data["library"] || %{}

    assigned =
      for(lib <- ["fusions", "upties"], definition <- library[lib] || [], {ms, group} <- groups(definition["milestones"]), do: {ms, group, %{"lib" => lib, "id" => definition["id"]}}) ++
        for list <- library["lists"] || [], gift <- list["gifts"] || [], {ms, group} <- groups(groups(list["milestones"])[gift]),
            do: {ms, group, %{"lib" => "lists", "id" => list["id"], "gift" => gift}}

    milestones =
      Enum.map(data["milestones"], fn milestone ->
        entries = for {ms, group, ref} <- assigned, ms == milestone["id"], do: {group, ref}
        {min, milestone} = Map.pop(milestone, "group_min")
        Map.put(milestone, "blocks", blocks(entries, min || %{}))
      end)

    data
    |> Map.put("milestones", milestones)
    |> Map.put("library", Map.new(library, fn {lib, defs} -> {lib, Enum.map(defs, &Map.delete(&1, "milestones"))} end))
  end

  defp groups(map) when is_map(map), do: map
  defp groups(_other), do: %{}

  defp blocks(entries, min) do
    entries
    |> Enum.reduce([], fn
      {nil, ref}, blocks ->
        blocks ++ [%{"type" => "entry", "ref" => ref}]

      {letter, ref}, blocks ->
        if Enum.any?(blocks, &(&1["letter"] == letter)),
          do: Enum.map(blocks, &if(&1["letter"] == letter, do: Map.update!(&1, "refs", fn refs -> refs ++ [ref] end), else: &1)),
          else: blocks ++ [%{"type" => "group", "letter" => letter, "min" => min[letter] || 1, "refs" => [ref]}]
    end)
  end
end
