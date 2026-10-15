defmodule StarlightBot.Automation.ChainStreak do
  @type choice :: :top | :bottom

  @spec best_path([term], [term], %{non_neg_integer => choice}) :: [choice]
  def best_path(top, bottom, forced \\ %{})

  def best_path([], [], _forced), do: []

  def best_path(top, bottom, forced) when length(top) == length(bottom) do
    weight = length(top) + 1

    top
    |> Enum.zip(bottom)
    |> Enum.with_index()
    |> build_layers(weight, forced)
    |> backtrack(weight)
  end

  defp build_layers(columns, weight, forced) do
    start_layer = %{start: %{score: 0, choice: nil, prev: nil}}

    {_last_layer, layers_rev} =
      Enum.reduce(columns, {start_layer, []}, fn {{top_color, bottom_color}, index}, {prev_layer, acc} ->
        layer =
          case Map.get(forced, index) do
            :top ->
              extend(prev_layer, top_color, :top, weight)

            :bottom ->
              extend(prev_layer, bottom_color, :bottom, weight)

            nil ->
              prev_layer
              |> extend(top_color, :top, weight)
              |> Map.merge(extend(prev_layer, bottom_color, :bottom, weight), fn _key, a, b ->
                if a.score >= b.score, do: a, else: b
              end)
          end

        {layer, [layer | acc]}
      end)

    Enum.reverse(layers_rev)
  end

  defp extend(prev_layer, color, choice, weight) do
    Enum.reduce(prev_layer, %{}, fn {prev_key, %{score: prev_score}}, acc ->
      {new_key, new_score} = transition(prev_key, prev_score, color, weight)
      candidate = %{score: new_score, choice: choice, prev: prev_key}

      Map.update(acc, new_key, candidate, fn existing ->
        if candidate.score >= existing.score, do: candidate, else: existing
      end)
    end)
  end

  defp transition(:start, score, color, _weight), do: {{color, 1}, score}

  defp transition({prev_color, prev_len}, score, color, weight) do
    if prev_color == color do
      {{color, prev_len + 1}, score}
    else
      {{color, 1}, score + Integer.pow(weight, prev_len)}
    end
  end

  defp backtrack(layers, weight) do
    last_layer = List.last(layers)

    {best_key, _} =
      Enum.max_by(last_layer, fn {{_color, len}, %{score: score}} ->
        score + Integer.pow(weight, len)
      end)

    layers
    |> Enum.reverse()
    |> do_backtrack(best_key, [])
  end

  defp do_backtrack([], :start, acc), do: acc

  defp do_backtrack([layer | rest], key, acc) do
    %{choice: choice, prev: prev} = Map.fetch!(layer, key)
    do_backtrack(rest, prev, [choice | acc])
  end
end
