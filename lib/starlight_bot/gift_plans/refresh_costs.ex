defmodule StarlightBot.GiftPlans.RefreshCosts do
  @base %{normal: 15, keyword: 90}
  @step 15
  @max_columns 15
  @normal_grace 0
  @keyword_grace 5
  @kinds %{"refresh" => :normal, "affinity_refresh" => :keyword}

  def max_columns, do: @max_columns

  def free(grace_picks) do
    {free_for(grace_picks, @normal_grace), free_for(grace_picks, @keyword_grace)}
  end

  defp free_for(grace_picks, index) do
    case Enum.find(grace_picks || [], &(&1["index"] == index)) do
      nil -> 0
      %{"enhance" => 2} -> 2
      _pick -> 1
    end
  end

  def columns(cases) do
    caps = for refresh_case <- cases, Map.has_key?(@kinds, refresh_case["action"]), do: refresh_case["max"]
    if Enum.any?(caps, &is_nil/1), do: @max_columns, else: caps |> Enum.sum() |> min(@max_columns)
  end

  def default_path(cases) do
    columns = columns(cases)

    cases
    |> Enum.filter(&Map.has_key?(@kinds, &1["action"]))
    |> Enum.flat_map(&List.duplicate(@kinds[&1["action"]], &1["max"] || @max_columns))
    |> Enum.take(columns)
  end

  def kind("normal"), do: :normal
  def kind("keyword"), do: :keyword

  def grid(path, {free_normal, free_keyword}, columns) do
    free = %{normal: free_normal, keyword: free_keyword}
    start = %{used: %{normal: 0, keyword: 0}, total: 0}

    {cells, _} =
      Enum.map_reduce(0..(columns - 1)//1, start, fn position, %{used: used, total: total} ->
        chosen = Enum.at(path, position)
        normal = price(:normal, position, used, free)
        keyword = price(:keyword, position, used, free)
        picked = %{normal: normal, keyword: keyword}[chosen]
        total = if picked, do: total + elem(picked, 0), else: nil
        used = if chosen, do: Map.update!(used, chosen, &(&1 + 1)), else: used
        {%{position: position, normal: normal, keyword: keyword, chosen: chosen, total: total}, %{used: used, total: total || 0}}
      end)

    cells
  end

  def total(path, free) do
    path |> Enum.with_index() |> Enum.reduce({0, %{normal: 0, keyword: 0}}, fn {kind, position}, {sum, used} ->
      {cost, _free?} = price(kind, position, used, free_map(free))
      {sum + cost, Map.update!(used, kind, &(&1 + 1))}
    end) |> elem(0)
  end

  def counts(path), do: {Enum.count(path, &(&1 == :normal)), Enum.count(path, &(&1 == :keyword))}

  def cheapest(path, free) do
    {normals, keywords} = counts(path)
    free = free_map(free)

    table =
      for normal <- 0..normals, keyword <- 0..keywords, {normal, keyword} != {0, 0}, reduce: %{{0, 0} => {0, []}} do
        table ->
          step = fn kind, from ->
            {cost, sequence} = table[from]
            {price_cost, _free?} = price(kind, normal + keyword - 1, %{normal: elem(from, 0), keyword: elem(from, 1)}, free)
            {cost + price_cost, [kind | sequence]}
          end

          options =
            Enum.filter(
              [normal > 0 && step.(:normal, {normal - 1, keyword}), keyword > 0 && step.(:keyword, {normal, keyword - 1})],
              & &1
            )

          Map.put(table, {normal, keyword}, Enum.min_by(options, &elem(&1, 0)))
      end

    {cost, sequence} = table[{normals, keywords}]
    {cost, Enum.reverse(sequence)}
  end

  defp free_map({free_normal, free_keyword}), do: %{normal: free_normal, keyword: free_keyword}
  defp free_map(%{} = free), do: free

  defp price(kind, position, used, free) do
    if used[kind] < free[kind], do: {0, true}, else: {@base[kind] + @step * position, false}
  end
end
