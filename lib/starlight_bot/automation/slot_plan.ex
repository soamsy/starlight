defmodule StarlightBot.Automation.SlotPlan do
  alias StarlightBot.BattlePlans

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
          untargeted = untargeted_columns(holder, taken, env)

          {steps, next} =
            Enum.map_reduce(taken, start, fn column, index ->
              if column in untargeted,
                do: {step(holder, %{"pick" => "none"}, column, index, env), index},
                else: {step(holder, enemy, column, index, env), index + 1}
            end)

          {steps, {next, enemy}}
      end)

    {steps, Enum.flat_map(steps, & &1.notes)}
  end

  defp untargeted_columns(%{"type" => "dodge", "enemy" => %{"pick" => pick}} = holder, taken, env) do
    if pick != "none" and Map.get(holder, "skip_bottom_target", true) do
      case env.bottom_columns.() do
        {:ok, bottom_columns} -> Enum.filter(taken, &(&1 in bottom_columns))
        :skip -> []
      end
    else
      []
    end
  end

  defp untargeted_columns(_holder, _taken, _env), do: []

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

  defp row_for(%{"row" => "priority"} = holder, column, %{classified: {top, bottom}}) do
    top_cell = Enum.at(top, column)
    bottom_cell = Enum.at(bottom, column)
    row = BattlePlans.pick_row(holder, top_cell, bottom_cell)
    {row, ["slot #{column + 1} #{BattlePlans.row_label(holder)}: top #{BattlePlans.cell_label(top_cell)}, bottom #{BattlePlans.cell_label(bottom_cell)} -> #{row}"]}
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
