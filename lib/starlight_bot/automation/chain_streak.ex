defmodule StarlightBot.Automation.ChainStreak do
  @defense_min_run 3

  @type choice :: :top | :bottom | :defense

  @spec best_path([term], [term], %{non_neg_integer => :top | :bottom}, [term] | nil, non_neg_integer | nil, keyword) :: [choice]
  def best_path(top, bottom, forced \\ %{}, defense \\ nil, max_defenses \\ nil, opts \\ [])

  def best_path([], [], _forced, _defense, _max_defenses, _opts), do: []

  def best_path(top, bottom, forced, defense, max_defenses, opts) when length(top) == length(bottom) do
    config = %{weight: length(top) + 1, max_defenses: max_defenses, stay: opts[:stay], min_run: opts[:min_run]}
    defense = defense || List.duplicate(nil, length(top))

    [top, bottom, defense]
    |> Enum.zip()
    |> Enum.with_index()
    |> build_layers(config, forced)
    |> backtrack(config)
  end

  @spec committed_columns([choice], [term], [term], [term] | nil, pos_integer) :: MapSet.t(non_neg_integer)
  def committed_columns(path, top, bottom, defense, min_run) do
    defense = defense || List.duplicate(nil, length(top))

    [path, top, bottom, defense]
    |> Enum.zip_with(fn
      [:top, color, _bottom, _defense] -> color
      [:bottom, _top, color, _defense] -> color
      [:defense, _top, _bottom, color] -> color
    end)
    |> Enum.with_index()
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.filter(&(length(&1) >= min_run))
    |> Enum.flat_map(fn run -> Enum.map(run, &elem(&1, 1)) end)
    |> MapSet.new()
  end

  defp build_layers(columns, config, forced) do
    start_layer = %{start: %{score: {0, 0, 0}, choice: nil, prev: nil}}

    {_last_layer, layers_rev} =
      Enum.reduce(columns, {start_layer, []}, fn {{top_color, bottom_color, defense_color}, index}, {prev_layer, acc} ->
        layer =
          case Map.get(forced, index) do
            :top ->
              extend(prev_layer, top_color, :top, config, index)

            :bottom ->
              extend(prev_layer, bottom_color, :bottom, config, index)

            nil ->
              [{top_color, :top}, {bottom_color, :bottom}, {defense_color, :defense}]
              |> Enum.reject(fn {color, _choice} -> is_nil(color) end)
              |> Enum.map(fn {color, choice} -> extend(prev_layer, color, choice, config, index) end)
              |> Enum.reduce(%{}, &merge_layers/2)
          end

        {layer, [layer | acc]}
      end)

    Enum.reverse(layers_rev)
  end

  defp merge_layers(layer, acc) do
    Map.merge(acc, layer, fn _key, existing, candidate -> if candidate.score > existing.score, do: candidate, else: existing end)
  end

  defp extend(prev_layer, color, choice, config, index) do
    prev_layer
    |> Enum.reject(fn {prev_key, _state} -> choice == :defense and config.max_defenses && defenses_used(prev_key) >= config.max_defenses end)
    |> Enum.reduce(%{}, fn {prev_key, %{score: prev_score}}, acc ->
      {new_key, new_score} = transition(prev_key, prev_score, color, choice, config, index)
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

  defp transition(:start, {streaks, defenses, steadiness}, color, choice, config, index) do
    steadiness = if config.stay, do: steadiness + stay_delta(choice, index, config.stay), else: steadiness
    {{color, 1, row_of(choice), choice == :defense, count_defense(0, choice, config)}, {streaks, defenses, steadiness}}
  end

  defp transition({prev_color, prev_len, prev_row, prev_defense?, used}, {streaks, defenses, steadiness}, color, choice, config, index) do
    row = row_of(choice)
    steadiness = steadiness + steadiness_delta(prev_row, row, choice, index, config.stay)
    used = count_defense(used, choice, config)

    if prev_color == color do
      {{color, prev_len + 1, row, prev_defense? or choice == :defense, used}, {streaks, defenses, steadiness}}
    else
      {{color, 1, row, choice == :defense, used}, {streaks + run_value(prev_len, prev_defense?, config), defenses, steadiness}}
    end
  end

  defp steadiness_delta(prev_row, row, _choice, _index, nil), do: if(prev_row == row, do: 0, else: -1)
  defp steadiness_delta(_prev_row, _row, choice, index, stay), do: stay_delta(choice, index, stay)

  defp stay_delta(:defense, _index, _stay), do: -1
  defp stay_delta(choice, index, stay), do: if(choice == Enum.at(stay, index), do: 0, else: -1)

  defp count_defense(used, :defense, %{max_defenses: max}) when not is_nil(max), do: used + 1
  defp count_defense(used, _choice, _config), do: used

  defp run_value(len, defense?, %{min_run: min_run, weight: weight}) do
    floor = min_run || if(defense?, do: @defense_min_run, else: 1)
    if len < floor, do: len * weight, else: Integer.pow(weight, len)
  end

  defp backtrack(layers, config) do
    last_layer = List.last(layers)

    {best_key, _} =
      Enum.max_by(last_layer, fn {{_color, len, _row, defense?, _used}, %{score: {streaks, defenses, steadiness}}} ->
        {streaks + run_value(len, defense?, config), defenses, steadiness}
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
