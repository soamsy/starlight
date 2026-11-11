defmodule StarlightBot.Automation.SlotPlan do
  alias StarlightBot.Automation.ChainStreak
  alias StarlightBot.BattlePlans

  @run_modes ~w(a_res a_res_def)
  @min_run 3

  def needs_classified?(holder),
    do: Enum.any?(BattlePlans.holders(holder), &(&1["row"] == "priority" or is_map(&1["where"])))

  def plan(holder, env) do
    {assigned, assign_notes} = assign(holder, env)
    {steps, step_notes} = steps(assigned, env)
    {steps, tray_notes(env.classified) ++ assign_notes ++ step_notes ++ Enum.map(steps, &describe/1)}
  end

  def assign(holder, env), do: chain(holder, env.columns, env, "action")

  def steps(assigned, env) do
    {steps, _carried} =
      Enum.flat_map_reduce(assigned, {0, nil}, fn
        {%{"type" => "nothing"} = holder, taken}, carried ->
          {Enum.map(taken, &%{action: "nothing", holder: holder, column: &1, row: nil, enemy: nil, notes: []}), carried}

        {holder, taken}, {offset, previous} ->
          {enemy, continued?} = resolve_enemy(holder["enemy"], previous)
          start = if continued?, do: offset, else: 0
          holder = Map.put(holder, "enemy", enemy)
          bottom_result = if skips_target?(holder) or needs_in_use?(holder), do: env.bottom_columns.()
          bottom_columns = if skips_target?(holder), do: bottom_columns_to_skip(bottom_result)
          {env, run_note} = with_rows(holder, taken, bottom_result, env)

          {steps, next} =
            Enum.map_reduce(taken, start, fn column, index ->
              planned = step(holder, enemy, column, index, env)

              if keeps_target?(planned, bottom_columns),
                do: {kept_step(planned, holder, column, index, env), index},
                else: {planned, index + 1}
            end)

          {add_note(steps, run_note), {next, enemy}}
      end)

    {steps, Enum.flat_map(steps, & &1.notes)}
  end

  defp skips_target?(%{"enemy" => %{"pick" => pick}} = holder), do: pick != "none" and Map.get(holder, "skip_bottom_target", true)
  defp skips_target?(_holder), do: false

  defp needs_in_use?(holder) do
    order = List.wrap(get_in(holder, ["priority", "order"]))
    holder["mode"] in @run_modes or "in_use" in order
  end

  defp bottom_columns_to_skip({:ok, bottom_columns}), do: bottom_columns
  defp bottom_columns_to_skip(_result), do: nil

  defp with_rows(%{"row" => "priority"} = holder, taken, {:ok, bottom_columns}, %{classified: {top, _bottom}} = env) do
    in_use = Map.new(0..(length(top) - 1)//1, &{&1, if(&1 in bottom_columns, do: :bottom, else: :top)})
    {committed, note} = committed_rows(holder, taken, in_use, env)
    {Map.merge(env, %{in_use: in_use, committed: committed}), note}
  end

  defp with_rows(%{"mode" => mode}, _taken, _bottom_result, env) when mode in @run_modes,
    do: {env, "#{mode_label(mode)}: can't read which skills are in use, picking by priority"}

  defp with_rows(_holder, _taken, _bottom_result, env), do: {env, nil}

  defp committed_rows(%{"mode" => mode} = holder, taken, in_use, %{classified: {top, bottom}} = env) when mode in @run_modes do
    columns = Enum.to_list(0..(length(top) - 1)//1)
    top_sins = Enum.map(top, & &1.sin)
    bottom_sins = Enum.map(bottom, & &1.sin)
    defense = if mode == "a_res_def", do: env.defense_sins.()
    stay = Enum.map(columns, &Map.fetch!(in_use, &1))
    forced = for column <- columns, column not in taken, into: %{}, do: {column, Map.fetch!(in_use, column)}

    path = ChainStreak.best_path(top_sins, bottom_sins, forced, defense, holder["max_defenses"], stay: stay, min_run: @min_run)
    committed = ChainStreak.committed_columns(path, top_sins, bottom_sins, defense, @min_run)
    rows = for column <- taken, MapSet.member?(committed, column), into: %{}, do: {column, row_of_choice(Enum.at(path, column))}

    {rows, run_note(mode, rows)}
  end

  defp committed_rows(_holder, _taken, _in_use, _env), do: {%{}, nil}

  defp row_of_choice(:defense), do: :dodge
  defp row_of_choice(choice), do: choice

  defp run_note(mode, rows) when map_size(rows) == 0, do: "#{mode_label(mode)}: no run of #{@min_run}+ reachable, picking by priority"

  defp run_note(mode, rows) do
    picks = rows |> Enum.sort() |> Enum.map_join(", ", fn {column, row} -> "#{column + 1} #{row}" end)
    "#{mode_label(mode)}: runs of #{@min_run}+ on slot(s) #{picks}"
  end

  defp mode_label("a_res"), do: "a-res"
  defp mode_label("a_res_def"), do: "a-res+def"

  defp add_note(steps, nil), do: steps
  defp add_note([], _note), do: []
  defp add_note([first | rest], note), do: [%{first | notes: [note | first.notes]} | rest]

  defp kept_step(%{action: "target", row: row} = planned, holder, column, _index, _env) when row in [:top, :bottom],
    do: %{action: "nothing", holder: holder, column: column, row: nil, enemy: nil, notes: planned.notes}

  defp kept_step(_planned, holder, column, index, env), do: step(holder, %{"pick" => "none"}, column, index, env)

  defp keeps_target?(_step, nil), do: false
  defp keeps_target?(%{row: :top, column: column}, bottom_columns), do: column not in bottom_columns
  defp keeps_target?(%{column: column}, bottom_columns), do: column in bottom_columns

  def describe(%{action: "nothing", column: column}), do: "plan: slot #{column + 1} left alone"
  def describe(%{action: "dodge", column: column, enemy: enemy}), do: "plan: slot #{column + 1} dodge#{enemy_text(enemy)}"
  def describe(%{action: "ego", column: column, holder: holder}), do: "plan: slot #{column + 1} #{holder["grade"]} EGO#{if holder["corrode"], do: " (corroded)"}"
  def describe(%{action: "target", column: column, row: row, enemy: enemy}), do: "plan: slot #{column + 1} #{row} skill#{enemy_text(enemy)}"

  defp enemy_text(%{"pick" => "none"}), do: ""
  defp enemy_text(%{"index" => index} = enemy), do: " -> enemy #{BattlePlans.enemy_label(enemy)} (slot order #{index + 1})"
  defp enemy_text(_enemy), do: ""

  defp tray_notes(nil), do: []

  defp tray_notes({top, bottom}) do
    cells = top |> Enum.zip(bottom) |> Enum.with_index(1) |> Enum.map_join(", ", fn {{t, b}, slot} -> "#{slot}: #{BattlePlans.cell_label(t)} | #{BattlePlans.cell_label(b)}" end)
    ["tray (top | bottom) #{cells}"]
  end

  defp step(holder, enemy, column, index, env) do
    {row, notes} = if holder["type"] == "target", do: row_for(holder, column, env), else: {nil, []}
    enemy = if is_map(enemy), do: Map.put(enemy, "index", index)
    %{action: holder["type"], holder: Map.put(holder, "enemy", enemy), column: column, row: row, enemy: enemy, notes: notes}
  end

  defp row_for(%{"row" => "priority"} = holder, column, %{classified: {top, bottom}} = env) do
    case Map.fetch(Map.get(env, :committed, %{}), column) do
      {:ok, row} ->
        {row, []}

      :error ->
        top_cell = Enum.at(top, column)
        bottom_cell = Enum.at(bottom, column)
        row = BattlePlans.pick_row(holder, top_cell, bottom_cell, env |> Map.get(:in_use, %{}) |> Map.get(column))
        {row, ["slot #{column + 1} #{BattlePlans.row_label(holder)}: top #{BattlePlans.cell_label(top_cell)}, bottom #{BattlePlans.cell_label(bottom_cell)} -> #{row}"]}
    end
  end

  defp row_for(holder, _column, _env), do: {BattlePlans.pick_row(holder, nil, nil), []}

  defp resolve_enemy(own, previous) do
    cond do
      is_map(own) and own["pick"] != "continue" -> {own, false}
      is_map(previous) -> {previous, true}
      true -> {%{"pick" => "none"}, false}
    end
  end

  defp chain(nil, _available, _env, _label), do: {[], []}

  defp chain(holder, available, env, label) do
    {taken, notes} = take(holder, available, env)
    notes = if label == "rest" and taken != [], do: notes ++ ["rest takes slot(s) #{slots_text(taken)}"], else: notes
    {rest, rest_notes} = chain(holder["rest"], available -- taken, env, "rest")
    {if(taken == [], do: rest, else: [{holder, taken} | rest]), notes ++ rest_notes}
  end

  defp take(%{"skill" => skill} = holder, available, env) do
    case select(holder, env) do
      {:ok, groups, notes} ->
        {groups, notes} = narrow(groups, holder["where"], notes, env)

        pooled =
          groups
          |> Enum.flat_map(fn {columns, _who} -> Enum.filter(columns, &(&1 in available)) end)
          |> Enum.sort()

        name = groups |> Enum.map(&elem(&1, 1).name) |> Enum.uniq() |> Enum.join(", ")
        pick(pooled, skill, name, notes)

      {:skip, notes} ->
        {[], notes}
    end
  end

  defp narrow(groups, nil, notes, _env), do: {groups, notes}

  defp narrow(groups, filter, notes, env) do
    case env.bottom_columns.() do
      {:ok, bottom_columns} ->
        allowed = BattlePlans.chosen_columns(filter, bottom_columns, length(env.columns), env.classified)
        label = BattlePlans.chosen_filter_label(filter)

        narrowed =
          Enum.flat_map(groups, fn {columns, who} ->
            case Enum.filter(columns, &(&1 in allowed)) do
              [] -> []
              kept -> [{kept, Map.update!(who, :name, &if(&1 == "everyone", do: label, else: "#{&1} (#{label})"))}]
            end
          end)

        {narrowed, notes ++ ["bottom skill chosen in slot(s) [#{slots_text(bottom_columns, " ")}]"]}

      :skip ->
        {[], notes}
    end
  end

  defp pick([], _skill, name, notes), do: {[], notes ++ ["#{name} -> no free slot(s) left"]}

  defp pick(pooled, skill, name, notes) do
    case BattlePlans.pick_columns(pooled, skill) do
      [] -> {[], notes ++ ["#{name} has #{length(pooled)} slot(s), none in #{BattlePlans.skill_label(skill)}, skipping"]}
      picked -> {picked, notes ++ ["#{name} -> slot(s) #{slots_text(picked)}"]}
    end
  end

  defp select(%{"who" => "everyone"}, env), do: {:ok, Enum.map(env.tray_groups, &{&1, %{name: "everyone"}}), []}

  defp select(holder, env) do
    case env.sinner_groups.(holder) do
      {:ok, groups} -> {:ok, groups, []}
      :skip -> {:skip, []}
    end
  end

  defp slots_text(columns, separator \\ ", "), do: Enum.map_join(columns, separator, &(&1 + 1))
end
