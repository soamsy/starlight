defmodule StarlightBot.Automation.ChainStreak do
  @min_defense_run 3

  @type choice :: :top | :bottom | :defense

  @spec best_path([term], [term], %{non_neg_integer => :top | :bottom}, [term] | nil, non_neg_integer | nil) :: [choice]
  def best_path(top, bottom, forced \\ %{}, defense \\ nil, max_defenses \\ nil)

  def best_path([], [], _forced, _defense, _max_defenses), do: []

  def best_path(top, bottom, forced, defense, max_defenses) when length(top) == length(bottom) do
    weight = length(top) + 1
    defense = defense || List.duplicate(nil, length(top))

    [top, bottom, defense]
    |> Enum.zip()
    |> Enum.with_index()
    |> build_layers(weight, forced, max_defenses)
    |> backtrack(weight)
  end

  defp build_layers(columns, weight, forced, max_defenses) do
    start_layer = %{start: %{score: {0, 0, 0}, choice: nil, prev: nil}}

    {_last_layer, layers_rev} =
      Enum.reduce(columns, {start_layer, []}, fn {{top_color, bottom_color, defense_color}, index}, {prev_layer, acc} ->
        layer =
          case Map.get(forced, index) do
            :top ->
              extend(prev_layer, top_color, :top, weight, max_defenses)

            :bottom ->
              extend(prev_layer, bottom_color, :bottom, weight, max_defenses)

            nil ->
              [{top_color, :top}, {bottom_color, :bottom}, {defense_color, :defense}]
              |> Enum.reject(fn {color, _choice} -> is_nil(color) end)
              |> Enum.map(fn {color, choice} -> extend(prev_layer, color, choice, weight, max_defenses) end)
              |> Enum.reduce(%{}, &merge_layers/2)
          end

        {layer, [layer | acc]}
      end)

    Enum.reverse(layers_rev)
  end

  defp merge_layers(layer, acc) do
    Map.merge(acc, layer, fn _key, existing, candidate -> if candidate.score > existing.score, do: candidate, else: existing end)
  end

  defp extend(prev_layer, color, choice, weight, max_defenses) do
    prev_layer
    |> Enum.reject(fn {prev_key, _state} -> choice == :defense and max_defenses && defenses_used(prev_key) >= max_defenses end)
    |> Enum.reduce(%{}, fn {prev_key, %{score: prev_score}}, acc ->
      {new_key, new_score} = transition(prev_key, prev_score, color, choice, weight, max_defenses)
      new_score = if choice == :defense, do: put_elem(new_score, 1, elem(new_score, 1) - 1), else: new_score
      candidate = %{score: new_score, choice: choice, prev: prev_key}

      Map.update(acc, new_key, candidate, fn existing ->
        if candidate.score >= existing.score, do: candidate, else: existing
      end)
    end)
  end

  defp row_of(:defense), do: :bottom
  defp row_of(choice), do: choice

  defp defenses_used(:start), do: 0
  defp defenses_used({_color, _len, _row, _defense?, used}), do: used

  defp transition(:start, score, color, choice, _weight, max_defenses),
    do: {{color, 1, row_of(choice), choice == :defense, count_defense(0, choice, max_defenses)}, score}

  defp transition({prev_color, prev_len, prev_row, prev_defense?, used}, {streaks, defenses, steadiness}, color, choice, weight, max_defenses) do
    row = row_of(choice)
    steadiness = if prev_row == row, do: steadiness, else: steadiness - 1
    used = count_defense(used, choice, max_defenses)

    if prev_color == color do
      {{color, prev_len + 1, row, prev_defense? or choice == :defense, used}, {streaks, defenses, steadiness}}
    else
      {{color, 1, row, choice == :defense, used}, {streaks + run_value(prev_len, prev_defense?, weight), defenses, steadiness}}
    end
  end

  defp count_defense(used, :defense, max_defenses) when not is_nil(max_defenses), do: used + 1
  defp count_defense(used, _choice, _max_defenses), do: used

  defp run_value(len, true, weight) when len < @min_defense_run, do: len * weight
  defp run_value(len, _defense?, weight), do: Integer.pow(weight, len)

  defp backtrack(layers, weight) do
    last_layer = List.last(layers)

    {best_key, _} =
      Enum.max_by(last_layer, fn {{_color, len, _row, defense?, _used}, %{score: {streaks, defenses, steadiness}}} ->
        {streaks + run_value(len, defense?, weight), defenses, steadiness}
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
