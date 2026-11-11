defmodule StarlightBot.BattlePlans do
  alias StarlightBot.BattlePlans.Resolver
  alias StarlightBot.Conditions
  alias StarlightBot.GiftPlans
  alias StarlightBot.SinnerProfiles

  @tracks ~w(normal_chain hard_chain normal_focused hard_focused lux_chain lux_focused)
  @venues ~w(md_battle md_boss lux)
  @front_line_size 7
  @backup_size 5
  @max_floor 15
  @default_max_retries 5
  @max_turn 20
  @ignore_sides ~w(left right top bottom)
  @enemy_picks ~w(none first last)
  @enemy_steps ~w(left right)
  @chain_actions ~w(chain)
  @action_types %{
    "chain" => ~w(chain win_rate damage_rate ego dodge if commit retry),
    "focused" => ~w(win_rate damage_rate target if commit retry)
  }
  @default_leaf %{"op" => "tray_count", "sinners" => [], "matches" => [], "cmp" => "gte", "value" => 1}
  @sinner_count_op "sinner_count"
  @tray_count_op "tray_count"
  @position_op "sinner_position"
  @fight_op "boss_fight"
  @count_cmps ~w(eq gte lte)
  @grades ~w(zayin teth he waw)
  @rows ~w(top bottom priority)
  @chosen_value_kinds ~w(using bottom_is top_is has)
  @negated_kinds %{"not_using" => "using", "bottom_is_not" => "bottom_is", "top_is_not" => "top_is", "has_no" => "has"}
  @negated_labels %{"using" => "not using", "bottom_is" => "bottom is not", "top_is" => "top is not", "has" => "has no"}
  @chosen_kinds [
    {"using", "using"},
    {"bottom_is", "bottom is"},
    {"top_is", "top is"},
    {"has", "has"}
  ]
  @sins ~w(wrath lust sloth gluttony gloom pride envy)
  @tiers ~w(s3 s2 s1)
  @priority_values @tiers ++ @sins ++ ["dodge", "top", "bottom", "in_use"]
  @default_priority_order @tiers

  def tracks, do: @tracks
  def venues, do: @venues
  def front_line_size, do: @front_line_size

  def formation(sinners) do
    {front, rest} = Enum.split(sinners, @front_line_size)
    %{front: front, backup: Enum.take(rest, @backup_size)}
  end
  def max_floor, do: @max_floor
  def max_turn, do: @max_turn
  def enemy_picks, do: @enemy_picks
  def enemy_steps, do: @enemy_steps

  def target_index(count, enemy) do
    offset = if enemy["pick"] == "percent", do: 0, else: max(enemy["offset"] || 0, 0)
    start = if enemy["pick"] == "last", do: count - 1 - offset, else: offset
    step = Map.get(%{"left" => -1, "right" => 1}, enemy["step"], 0)
    (clamp(start, count) + step * (enemy["index"] || 0)) |> clamp(count)
  end

  defp clamp(index, count), do: index |> max(0) |> min(count - 1)

  def enemy_label(%{"pick" => "none"}), do: "none"

  def enemy_label(%{"pick" => pick} = enemy) do
    step = if enemy["step"] in ~w(left right), do: ", then #{enemy["step"]}", else: ""
    "#{if pick == "last", do: "last", else: "first"}#{offset_label(pick, enemy["offset"])}#{step}#{ignore_label(enemy["ignore"])}"
  end

  defp offset_label("last", offset) when is_integer(offset) and offset > 0, do: "-#{offset}"
  defp offset_label(_pick, offset) when is_integer(offset) and offset > 0, do: "+#{offset}"
  defp offset_label(_pick, _offset), do: ""

  def parse_enemy(pick, offset, step) when pick in ~w(first last) do
    %{"pick" => pick, "offset" => parse_count(offset) || 0}
    |> Map.put("step", if(step in ["same" | @enemy_steps], do: step, else: default_step(pick)))
  end

  def parse_enemy("none", _n, _step), do: %{"pick" => "none"}
  def parse_enemy("continue", _n, _step), do: %{"pick" => "continue"}
  def parse_enemy(_pick, n, step), do: parse_enemy("first", n, step)

  def default_step("first"), do: "right"
  def default_step("last"), do: "left"

  def ignore_sides, do: @ignore_sides

  def apply_ignores(targets, ignores) when is_list(ignores), do: Enum.reduce(ignores, targets, &ignore_targets(&2, &1))
  def apply_ignores(targets, _ignores), do: targets

  defp ignore_targets(targets, %{"side" => side, "n" => n}) when side in @ignore_sides and targets != [] do
    cut =
      targets
      |> Enum.with_index()
      |> Enum.sort_by(fn {%{icon: {x, y}}, _index} -> ignore_key(side, x, y) end)
      |> Enum.take(min(n, length(targets) - 1))
      |> MapSet.new(&elem(&1, 1))

    targets |> Enum.with_index() |> Enum.reject(fn {_target, index} -> index in cut end) |> Enum.map(&elem(&1, 0))
  end

  defp ignore_targets(targets, _ignore), do: targets

  defp ignore_key("left", x, _y), do: x
  defp ignore_key("right", x, _y), do: -x
  defp ignore_key("top", _x, y), do: y
  defp ignore_key("bottom", _x, y), do: -y

  def ignore_label(ignores) when is_list(ignores) and ignores != [],
    do: ", ignoring " <> Enum.map_join(ignores, ", ", fn %{"side" => side, "n" => n} -> "#{side} #{n}" end)

  def ignore_label(_ignores), do: ""

  def put_ignores(enemy, entries, add) do
    kept =
      (entries || %{})
      |> Enum.sort_by(fn {index, _entry} -> parse_count(index) || 0 end)
      |> Enum.flat_map(fn
        {_index, %{"side" => side} = entry} when side in @ignore_sides -> [%{"side" => side, "n" => (parse_count(entry["n"]) || 1) |> max(1) |> min(99)}]
        _ -> []
      end)

    ignores = if add in @ignore_sides, do: kept ++ [%{"side" => add, "n" => 1}], else: kept
    if ignores == [], do: Map.delete(enemy, "ignore"), else: Map.put(enemy, "ignore", ignores)
  end

  def remove_ignore(enemy, index) do
    case List.delete_at(enemy["ignore"] || [], index) do
      [] -> Map.delete(enemy, "ignore")
      ignores -> Map.put(enemy, "ignore", ignores)
    end
  end
  def grades, do: @grades
  def rows, do: @rows
  def tiers, do: @tiers
  def priority_values, do: @priority_values
  def priority_values(chain?), do: if(chain?, do: @priority_values -- ["in_use"], else: @priority_values)
  def run_modes, do: ~w(none a_res a_res_def)
  def count_cmps, do: @count_cmps

  def put_row(holder, "priority", order) do
    order =
      if is_map(holder["priority"]),
        do: order |> List.wrap() |> Enum.filter(&priority_term?/1) |> Enum.uniq(),
        else: @default_priority_order

    holder |> Map.put("row", "priority") |> Map.put("priority", %{"order" => order})
  end

  def put_row(holder, row, _order) do
    holder |> Map.put("row", if(row == "top", do: "top", else: "bottom")) |> Map.drop(~w(priority mode max_defenses))
  end

  def put_run_mode(%{"row" => "priority"} = holder, %{"mode" => mode} = params) when mode in ~w(none a_res a_res_def) do
    case mode do
      "none" -> Map.drop(holder, ~w(mode max_defenses))
      "a_res" -> holder |> Map.put("mode", mode) |> Map.delete("max_defenses")
      "a_res_def" -> holder |> Map.put("mode", mode) |> put_max_defenses(params)
    end
  end

  def put_run_mode(holder, _params), do: holder

  defp put_max_defenses(holder, %{"max_defenses" => value}) do
    case Integer.parse(to_string(value)) do
      {n, _} when n >= 0 -> Map.put(holder, "max_defenses", n)
      _ -> Map.delete(holder, "max_defenses")
    end
  end

  defp put_max_defenses(holder, _params), do: holder

  @row_keys ~w(type who sinners where skill row priority grade corrode enemy skip_bottom_target mode max_defenses)

  def put_rest(holder, "true"), do: Map.put_new(holder, "rest", new_rest())
  def put_rest(holder, "false"), do: Map.delete(holder, "rest")
  def put_rest(holder, _automate_rest), do: holder

  def new_rest do
    put_row(%{"type" => "target", "who" => "everyone", "sinners" => [], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "continue"}}, "priority", nil)
  end

  def reorder_rows(holder, order) do
    holders = holders(holder)

    if Enum.sort(order) == Enum.to_list(0..(length(holders) - 1)//1) do
      rows = Enum.map(holders, &Map.take(&1, @row_keys))

      order
      |> Enum.map(&Enum.at(rows, &1))
      |> Enum.zip(holders)
      |> Enum.with_index()
      |> Enum.map(fn {{row, original}, index} -> original |> Map.drop(@row_keys) |> Map.merge(row) |> fix_head_enemy(index) end)
      |> chain_rows()
    else
      holder
    end
  end

  defp fix_head_enemy(%{"enemy" => %{"pick" => "continue"}} = row, 0),
    do: Map.put(row, "enemy", if(row["type"] == "target", do: parse_enemy("first", 0, nil), else: %{"pick" => "none"}))

  defp fix_head_enemy(row, _index), do: row

  defp chain_rows(rows), do: rows |> Enum.map(&Map.delete(&1, "rest")) |> Enum.reverse() |> Enum.reduce(nil, fn row, rest -> if rest, do: Map.put(row, "rest", rest), else: row end)

  def holders(%{"rest" => rest} = holder), do: [holder | holders(rest)]
  def holders(holder), do: [holder]

  def uses_priority?(holder), do: Enum.any?(holders(holder), &(&1["row"] == "priority"))

  def first_slot, do: %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}], "gaps" => %{"lead" => true, "mid" => [], "trail" => true}}

  def parse_skill(%{"pick" => "all"}), do: %{"pick" => "all"}

  def parse_skill(%{"pick" => pick} = params) when pick in ~w(first last) do
    chips =
      (params["chip"] || %{})
      |> Enum.sort_by(fn {index, _} -> parse_count(index) || 0 end)
      |> Enum.map(fn {_index, chip} -> {parse_count(chip["at"]) || 0, chip["on"] == "true"} end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {at, ons} -> %{"at" => at, "on" => Enum.any?(ons)} end)
      |> Enum.sort_by(& &1["at"])

    if chips == [] do
      %{first_slot() | "pick" => pick}
    else
      mid =
        (params["gap_mid"] || %{})
        |> Enum.sort_by(fn {index, _} -> parse_count(index) || 0 end)
        |> Enum.map(fn {_index, value} -> value == "true" end)

      %{"pick" => pick, "chips" => chips, "gaps" => %{"lead" => params["gap_lead"] != "false", "mid" => mid, "trail" => params["gap_trail"] != "false"}}
    end
  end

  def parse_skill(_params), do: first_slot()

  def normalize_skill(%{"pick" => "all"} = skill), do: skill

  def normalize_skill(%{"chips" => chips} = skill) when chips != [] do
    gaps = Map.merge(%{"lead" => true, "mid" => [], "trail" => true}, skill["gaps"] || %{})
    %{skill | "chips" => Enum.sort_by(chips, & &1["at"]), "gaps" => gaps}
  end

  def normalize_skill(%{"pick" => pick} = skill) do
    start = max(skill["start"] || 1, 1)
    stop = max(skill["end"] || start, start)
    %{"pick" => pick, "chips" => for(at <- (start - 1)..(stop - 1), do: %{"at" => at, "on" => true}), "gaps" => %{"lead" => false, "mid" => [], "trail" => false}}
  end

  def add_skill_chip(skill) do
    %{"chips" => chips} = skill = normalize_skill(skill)
    %{skill | "chips" => chips ++ [%{"at" => List.last(chips)["at"] + 1, "on" => true}]}
  end

  def step_skill_chip(skill, index, delta) do
    %{"chips" => chips} = skill = normalize_skill(skill)

    stepped =
      chips
      |> List.update_at(index, &%{&1 | "at" => max(&1["at"] + delta, 0)})
      |> Enum.group_by(& &1["at"], & &1["on"])
      |> Enum.map(fn {at, ons} -> %{"at" => at, "on" => Enum.any?(ons)} end)
      |> Enum.sort_by(& &1["at"])

    %{skill | "chips" => stepped}
  end

  def gap_ranges(chips) do
    ats = Enum.map(chips, & &1["at"])
    lead = if hd(ats) > 0, do: [{:lead, 0, hd(ats) - 1}], else: []

    mid =
      ats
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> b - a >= 2 end)
      |> Enum.with_index()
      |> Enum.map(fn {[a, b], index} -> {{:mid, index}, a + 1, b - 1} end)

    lead ++ mid ++ [{:trail, List.last(ats) + 1, :inf}]
  end

  def gap_on?(gaps, :lead), do: Map.get(gaps, "lead", true)
  def gap_on?(gaps, :trail), do: Map.get(gaps, "trail", true)
  def gap_on?(gaps, {:mid, index}), do: Enum.at(Map.get(gaps, "mid", []), index, true)

  def skill_view(skill) do
    %{"chips" => chips, "gaps" => gaps} = normalize_skill(skill)
    ranges = Map.new(gap_ranges(chips), fn {key, lo, hi} -> {key, {lo, hi}} end)
    gap = fn key -> {lo, hi} = ranges[key]; {:gap, key, gap_on?(gaps, key), lo, hi} end
    last = length(chips) - 1

    {items, _mid} =
      chips
      |> Enum.with_index()
      |> Enum.reduce({if(Map.has_key?(ranges, :lead), do: [gap.(:lead)], else: []), 0}, fn {chip, index}, {acc, mid} ->
        at = chip["at"]
        acc = acc ++ [{:chip, index, at, chip["on"]}]

        case Enum.at(chips, index + 1) do
          %{"at" => next} when index < last and next - at >= 2 -> {acc ++ [gap.({:mid, mid})], mid + 1}
          _ -> {acc, mid}
        end
      end)

    items ++ [gap.(:trail)]
  end

  def pick_columns(columns, %{"pick" => "all"}), do: columns

  def pick_columns(columns, skill) do
    %{"pick" => pick, "chips" => chips, "gaps" => gaps} = normalize_skill(skill)
    ranges = for {key, lo, hi} <- gap_ranges(chips), gap_on?(gaps, key), do: {lo, hi}
    ats = for %{"at" => at, "on" => true} <- chips, do: at
    ordered = if pick == "last", do: Enum.reverse(columns), else: columns

    ordered
    |> Enum.with_index()
    |> Enum.filter(fn {_column, position} -> position in ats or Enum.any?(ranges, fn {lo, hi} -> position >= lo and (hi == :inf or position <= hi) end) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  def skill_label(%{"pick" => "all"}), do: "all"

  def skill_label(skill) do
    case skill_tokens(skill) do
      [] -> "slots none"
      tokens -> "slots " <> Enum.join(tokens, ", ")
    end
  end

  def skill_tokens(skill) do
    %{"pick" => pick, "chips" => chips, "gaps" => gaps} = normalize_skill(skill)

    skill_view(%{"pick" => pick, "chips" => chips, "gaps" => gaps})
    |> Enum.flat_map(fn
      {:chip, _index, at, true} -> [chip_name(pick, at)]
      {:gap, :trail, true, _lo, _hi} -> ["rest"]
      {:gap, _key, true, _lo, _hi} -> ["..."]
      _ -> []
    end)
  end

  def chip_name(pick, 0), do: pick
  def chip_name("last", at), do: "last-#{at}"
  def chip_name(pick, at), do: "#{pick}+#{at}"

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_count(_value), do: nil

  def pick_row(holder, top, bottom, in_use \\ nil)

  def pick_row(%{"row" => "top"}, _top, _bottom, _in_use), do: :top

  def pick_row(%{"row" => "priority", "priority" => %{"order" => order}}, top, bottom, in_use) do
    Enum.find_value(order, :bottom, fn
      "in_use" ->
        in_use

      "dodge" ->
        :dodge

      "top" ->
        :top

      "bottom" ->
        :bottom

      value ->
        cond do
          priority_match?(value, bottom) -> :bottom
          priority_match?(value, top) -> :top
          true -> nil
        end
    end)
  end

  def pick_row(_holder, _top, _bottom, _in_use), do: :bottom

  def cell_label(%{sin: sin, tier: tier}), do: "#{sin}/#{tier_name(tier)}"

  defp priority_match?(value, cell), do: value |> String.split("+") |> Enum.all?(&part_match?(&1, cell))

  defp part_match?(part, %{tier: tier}) when part in @tiers, do: tier_name(tier) == part
  defp part_match?(part, %{sin: sin}), do: Atom.to_string(sin) == part

  defp tier_name(tier), do: tier |> Atom.to_string() |> String.replace_prefix("skill", "s")

  def holder_label(holder, names \\ %{}, enemy? \\ true), do: holder |> holder_parts(enemy?) |> parts_text(names)

  def rows_label(holder, names \\ %{}, enemy? \\ true), do: holder |> rows_parts(enemy?) |> Enum.map(&parts_text(&1, names))

  def rows_parts(holder, enemy? \\ true) do
    for {row, index} <- Enum.with_index(holders(holder)) do
      parts = holder_parts(row, enemy?)
      if index == 0, do: parts, else: ["remaining skills: " | parts]
    end
  end

  def parts_text(parts, names), do: Enum.map_join(parts, "", fn
    {:sinner, id} -> Map.get(names, id, id)
    {:term, value} -> value
    {:slot, name} -> name
    :not -> "not"
    text -> text
  end)

  def holder_parts(holder, enemy? \\ true) do
    selection = Enum.reject([who_parts(holder), skill_parts(holder["skill"]), where_parts(holder["where"])], &is_nil/1)
    effect = Enum.reject([action_parts(holder), enemy? && enemy_parts(holder)], &(is_nil(&1) or &1 == false))
    join_parts(selection, ", ") ++ [": "] ++ join_parts(effect, ", ")
  end

  defp join_parts(lists, separator), do: lists |> Enum.intersperse([separator]) |> Enum.concat()

  defp terms(values, separator), do: values |> Enum.map(&[{:term, &1}]) |> join_parts(separator)

  defp who_parts(%{"who" => "everyone"}), do: ["everyone"]
  defp who_parts(%{"sinners" => []}), do: ["no sinners"]

  defp who_parts(holder) do
    prefix =
      case holder["who"] do
        "except" -> ["all but "]
        "before" -> ["all before "]
        "after" -> ["all after "]
        _ -> []
      end

    prefix ++ join_parts(Enum.map(holder["sinners"] || [], &[{:sinner, &1}]), " ")
  end

  defp skill_parts(nil), do: ["all slots"]
  defp skill_parts(%{"pick" => "all"}), do: ["all slots"]
  defp skill_parts(skill) do
    case skill_tokens(skill) do
      [] -> ["slots none"]
      [only] when only in ~w(first last) -> [{:slot, only}, " slot"]
      tokens -> ["slots " | tokens |> Enum.map(&[{:slot, &1}]) |> join_parts(" ")]
    end
  end

  defp where_parts(%{"conditions" => _} = filter) do
    %{"join" => join, "conditions" => conditions} = normalize_chosen_filter(filter)

    parts =
      Enum.map(conditions, fn %{"kind" => kind, "values" => values} = condition ->
        {_kind, label} = List.keyfind(@chosen_kinds, kind, 0)
        negation = if condition["not"], do: [:not, " "], else: []
        negation ++ [label <> " " | terms(values, " ")]
      end)

    ["where " | join_parts(parts, " #{join} ")]
  end

  defp where_parts(_where), do: nil

  defp action_parts(%{"type" => "dodge"}), do: ["dodge"]
  defp action_parts(%{"type" => "nothing"}), do: ["leave as is"]

  defp action_parts(%{"type" => "ego"} = holder),
    do: ["EGO #{String.upcase(holder["grade"] || "zayin")}" <> if(holder["corrode"], do: " corrode", else: "")]

  defp action_parts(%{"row" => "priority", "priority" => %{"order" => order}} = holder) when order != [] do
    case run_mode_label(holder) do
      nil -> ["pick " | terms(order, " > ")]
      label -> [label <> ", else pick " | terms(order, " > ")]
    end
  end

  defp action_parts(%{"row" => "priority"}), do: ["pick priority (empty)"]
  defp action_parts(%{"row" => row}), do: ["pick #{row}"]
  defp action_parts(_holder), do: nil

  def run_mode_label(%{"mode" => "a_res"}), do: "a-res runs"
  def run_mode_label(%{"mode" => "a_res_def"} = holder), do: "a-res+def runs" <> if(is_integer(holder["max_defenses"]), do: " (up to #{holder["max_defenses"]} defenses)", else: "")
  def run_mode_label(_holder), do: nil

  defp enemy_parts(%{"enemy" => %{"pick" => "none"}}), do: nil
  defp enemy_parts(%{"enemy" => %{"pick" => "continue"}}), do: ["keep targeting"]

  defp enemy_parts(%{"enemy" => %{"pick" => pick} = enemy}) when pick in ~w(first last) do
    start = "target #{pick}#{offset_label(pick, enemy["offset"])}"
    step = if enemy["step"] in ~w(left right), do: ", then #{enemy["step"]}", else: ""
    ignored = Enum.map_join(enemy["ignore"] || [], "", &", ignoring #{&1["side"]} #{&1["n"]}")
    [start <> step <> ignored]
  end

  defp enemy_parts(_holder), do: nil

  def row_label(%{"row" => "priority", "priority" => %{"order" => []}}), do: "priority (empty)"
  def row_label(%{"row" => "priority", "priority" => %{"order" => order}}), do: "priority #{Enum.join(order, " > ")}"
  def row_label(%{"row" => row}), do: row

  def max_retries(%{"max_retries" => n}) when is_integer(n) and n >= 0, do: n
  def max_retries(_data), do: @default_max_retries

  def lux_track?(track), do: String.starts_with?(track, "lux_")

  def lux_venue?(venue), do: venue == "lux"

  def lineups(data), do: (is_map(data) && data["lineups"]) || []

  def lineup_track(data, venue), do: get_in(data, ["lineup_tracks", venue]) || []

  def find_lineup(data, id), do: Enum.find(lineups(data), &(&1["id"] == id))

  def new_lineup(name), do: %{"id" => GiftPlans.new_id("ln"), "name" => name, "sinners" => []}

  def venues_using(data, lineup_id) do
    Enum.filter(@venues, fn venue -> Enum.any?(lineup_track(data, venue), &(&1["lineup"] == lineup_id)) end)
  end

  def lineup_issues(data) do
    lineups = lineups(data)

    if lineups == [] do
      ["No lineups yet. Add one so the bot knows who to field."]
    else
      unassigned =
        for venue <- @venues,
            is_nil(find_lineup(data, Resolver.lineup_id_at(lineup_track(data, venue), 1))),
            do: "#{venue_label(venue)} has no lineup on floor 1."

      empty = for lineup <- lineups, lineup["sinners"] == [], do: "Lineup '#{lineup["name"]}' has no sinners."

      unassigned ++ empty
    end
  end

  def venue_label("md_battle"), do: "MD Battle"
  def venue_label("md_boss"), do: "MD Boss"
  def venue_label("lux"), do: "Lux"

  def track_kind(track) do
    if String.ends_with?(track, "_chain"), do: "chain", else: "focused"
  end

  def action_types(kind), do: Map.fetch!(@action_types, kind)

  def branches(block), do: ["then" | Enum.map(elifs(block), & &1["id"])] ++ if(has_else?(block), do: ["else"], else: [])

  def has_else?(block), do: is_list(block["else"])

  def add_else(items, block_id), do: update_list_containing(items, block_id, fn list -> Enum.map(list, &if(&1["id"] == block_id and is_nil(&1["else"]), do: Map.put(&1, "else", []), else: &1)) end)

  def remove_else(items, block_id), do: update_list_containing(items, block_id, fn list -> Enum.map(list, &if(&1["id"] == block_id, do: Map.put(&1, "else", nil), else: &1)) end)

  def elifs(block), do: block["elifs"] || []

  def branch_actions(block, "then"), do: block["then"]
  def branch_actions(block, "else"), do: block["else"] || []
  def branch_actions(block, id), do: Enum.find_value(elifs(block), [], &if(&1["id"] == id, do: &1["actions"]))

  def update_branch_actions(block, "then", fun), do: Map.update!(block, "then", fun)
  def update_branch_actions(block, "else", fun), do: Map.put(block, "else", fun.(block["else"] || []))

  def update_branch_actions(block, id, fun) do
    Map.put(block, "elifs", Enum.map(elifs(block), &if(&1["id"] == id, do: Map.update!(&1, "actions", fun), else: &1)))
  end

  def branch_conditions(block), do: [block["condition"] | Enum.map(elifs(block), & &1["condition"])]

  def action_conditions(%{"type" => "if"} = block), do: branch_conditions(block)
  def action_conditions(action), do: [action["condition"]]

  def new_elif, do: %{"id" => GiftPlans.new_id("ei"), "condition" => Conditions.add(nil, "", @default_leaf), "actions" => []}

  def add_elif(items, block_id, after_branch) do
    update_list_containing(items, block_id, fn list ->
      Enum.map(list, fn
        %{"id" => ^block_id} = block ->
          {before, rest} = Enum.split(elifs(block), elif_insert_index(block, after_branch))
          Map.put(block, "elifs", before ++ [new_elif() | rest])

        item ->
          item
      end)
    end)
  end

  defp elif_insert_index(_block, "then"), do: 0
  defp elif_insert_index(block, id), do: 1 + Enum.find_index(elifs(block), &(&1["id"] == id))

  def remove_elif(items, elif_id) do
    Enum.map(items, fn
      %{"type" => "if"} = block ->
        block
        |> Map.put("elifs", elifs(block) |> Enum.reject(&(&1["id"] == elif_id)) |> Enum.map(&Map.update!(&1, "actions", fn actions -> remove_elif(actions, elif_id) end)))
        |> Map.update!("then", &remove_elif(&1, elif_id))
        |> Map.update("else", nil, &(&1 && remove_elif(&1, elif_id)))

      %{"type" => "schedule"} = schedule ->
        Map.update!(schedule, "segments", fn segments -> Enum.map(segments, &Map.update!(&1, "actions", fn actions -> remove_elif(actions, elif_id) end)) end)

      item ->
        item
    end)
  end

  def update_elif_condition(items, elif_id, fun) do
    Enum.map(items, fn
      %{"type" => "if"} = block ->
        block
        |> Map.put("elifs", Enum.map(elifs(block), fn elif ->
          elif = Map.update!(elif, "actions", fn actions -> update_elif_condition(actions, elif_id, fun) end)
          if elif["id"] == elif_id, do: Map.update!(elif, "condition", fun), else: elif
        end))
        |> Map.update!("then", &update_elif_condition(&1, elif_id, fun))
        |> Map.update("else", nil, &(&1 && update_elif_condition(&1, elif_id, fun)))

      %{"type" => "schedule"} = schedule ->
        Map.update!(schedule, "segments", fn segments -> Enum.map(segments, &Map.update!(&1, "actions", fn actions -> update_elif_condition(actions, elif_id, fun) end)) end)

      item ->
        item
    end)
  end
  def default_leaf, do: @default_leaf

  def chain_action?(type), do: type in @chain_actions

  def terminal?(%{"type" => type}), do: chain_action?(type)

  def chain_last(actions) do
    {terminal, other} = actions |> Enum.map(&sort_branches/1) |> Enum.split_with(&terminal?/1)
    other ++ terminal
  end

  defp sort_branches(%{"type" => "if"} = block), do: Enum.reduce(branches(block), block, &update_branch_actions(&2, &1, fn actions -> chain_last(actions) end))
  defp sort_branches(action), do: action

  def flatten_actions(actions) do
    Enum.flat_map(actions, fn
      %{"type" => "if"} = block -> [block | Enum.flat_map(branches(block), &flatten_actions(branch_actions(block, &1)))]
      %{"type" => "schedule"} = schedule -> Enum.flat_map(schedule["segments"], &flatten_actions(&1["actions"]))
      action -> [action]
    end)
  end

  def duplicate_action(items, id) do
    update_list_containing(items, id, fn list ->
      Enum.flat_map(list, fn
        %{"id" => ^id} = action -> [action, refresh_ids(action)]
        action -> [action]
      end)
    end)
  end

  def duplicable?(%{"type" => type}), do: not chain_action?(type)

  def refresh_ids(%{"type" => "if"} = block) do
    elifs = Enum.map(elifs(block), &Map.put(&1, "id", GiftPlans.new_id("ei")))
    block = block |> Map.put("id", GiftPlans.new_id("ac")) |> Map.put("elifs", elifs)
    Enum.reduce(branches(block), block, &update_branch_actions(&2, &1, fn actions -> Enum.map(actions, fn a -> refresh_ids(a) end) end))
  end

  def refresh_ids(%{"type" => "schedule"} = schedule) do
    segments = Enum.map(schedule["segments"], &Map.update!(&1, "actions", fn actions -> Enum.map(actions, fn a -> refresh_ids(a) end) end))
    %{schedule | "id" => GiftPlans.new_id("sc"), "segments" => segments}
  end

  def refresh_ids(action), do: Map.put(action, "id", GiftPlans.new_id("ac"))

  def import_playbook(data, source) do
    taken = MapSet.new(data["playbooks"], & &1["name"])
    name = Stream.iterate(source["name"], &(&1 <> " copy")) |> Enum.find(&(not MapSet.member?(taken, &1)))
    playbook = %{source | "id" => GiftPlans.new_id("pb"), "name" => name, "actions" => Enum.map(source["actions"], &refresh_ids/1)}
    {Map.update!(data, "playbooks", &(&1 ++ [playbook])), playbook}
  end

  def import_lineup(data, source) do
    taken = MapSet.new(lineups(data), & &1["name"])
    name = Stream.iterate(source["name"], &(&1 <> " copy")) |> Enum.find(&(not MapSet.member?(taken, &1)))
    lineup = %{"id" => GiftPlans.new_id("ln"), "name" => name, "sinners" => Enum.filter(source["sinners"], &(&1 in SinnerProfiles.sinners()))}
    {Map.put(data, "lineups", lineups(data) ++ [lineup]), lineup}
  end

  def reorder_lineups(lineups, ids) do
    by_id = Map.new(lineups, &{&1["id"], &1})
    ordered = for id <- ids, lineup = by_id[id], do: lineup
    if length(ordered) == length(lineups), do: ordered, else: lineups
  end

  def hook_names(playbook) do
    for action <- flatten_actions(playbook["actions"]), condition <- action_conditions(action), leaf <- Conditions.leaves(condition), is_binary(leaf["hook"]), leaf["hook"] != "", uniq: true, do: leaf["hook"]
  end

  def condition_label(tree, profile_names \\ %{})
  def condition_label(nil, _profile_names), do: "always"
  def condition_label(tree, profile_names), do: Conditions.label(tree, &leaf_label(&1, profile_names))

  def sinner_leaf?(%{"op" => @sinner_count_op}), do: true
  def sinner_leaf?(_node), do: false

  def tray_leaf?(%{"op" => @tray_count_op}), do: true
  def tray_leaf?(_node), do: false

  def position_leaf?(%{"op" => @position_op}), do: true
  def position_leaf?(_node), do: false

  def fight_leaf?(%{"op" => @fight_op}), do: true
  def fight_leaf?(_node), do: false

  def position_matches?(%{"position" => position}, indexes, count) do
    allowed = pick_columns(Enum.to_list(0..(count - 1)), position)
    Enum.all?(indexes, &(&1 in allowed))
  end

  def sins, do: @sins

  def tray_count(%{"matches" => matches}, {top, bottom}, columns) do
    top
    |> Enum.zip(bottom)
    |> Enum.with_index()
    |> Enum.count(fn {{top_cell, bottom_cell}, column} ->
      (columns == :all or column in columns) and slot_matches?(matches, top_cell, bottom_cell)
    end)
  end

  def new_chosen_filter(pin? \\ false), do: %{"join" => "and", "conditions" => [new_chosen_condition(pin?)]}

  def new_chosen_condition(true), do: %{"kind" => "has", "values" => []}
  def new_chosen_condition(_pin?), do: %{"kind" => "using", "values" => ["top"]}

  def where_extras, do: ~w(top bottom)

  def normalize_chosen_filter(%{"conditions" => conditions} = filter), do: %{filter | "conditions" => Enum.map(conditions, &normalize_chosen_condition/1)}

  def normalize_chosen_condition(%{"kind" => kind}) when kind in ~w(top bottom), do: %{"kind" => "using", "values" => [kind]}

  def normalize_chosen_condition(%{"kind" => kind} = condition) when is_map_key(@negated_kinds, kind),
    do: %{condition | "kind" => @negated_kinds[kind]} |> Map.put("not", true)

  def normalize_chosen_condition(condition), do: condition

  def chosen_kinds(true), do: List.keydelete(@chosen_kinds, "using", 0)
  def chosen_kinds(_pin?), do: @chosen_kinds

  def chosen_value_kinds, do: @chosen_value_kinds

  def chip_values, do: @tiers ++ @sins

  def priority_term?(value), do: value in ~w(dodge top bottom in_use) or chip_term?(value)

  def chip_term?(value) when is_binary(value) do
    case String.split(value, "+") do
      [tier, sin] -> tier in @tiers and sin in @sins
      [single] -> single in @tiers or single in @sins
      _ -> false
    end
  end

  def chip_term?(_value), do: false

  def parse_chosen_filter(params) do
    case params["where_c"] do
      conditions when is_map(conditions) ->
        parsed =
          conditions
          |> Enum.sort_by(fn {index, _} -> parse_count(index) || 0 end)
          |> Enum.map(fn {_index, condition} -> parse_chosen_condition(condition) end)

        %{"join" => if(params["where_join"] == "or", do: "or", else: "and"), "conditions" => parsed}

      _ ->
        new_chosen_filter()
    end
  end

  defp parse_chosen_condition(%{"kind" => kind} = condition) when kind in @chosen_value_kinds or is_map_key(@negated_kinds, kind) do
    negated? = condition["not"] in [true, "true"] or is_map_key(@negated_kinds, kind)
    kind = Map.get(@negated_kinds, kind, kind)
    values = condition["values"] |> List.wrap() |> Enum.filter(&(chip_term?(&1) or (kind == "using" and &1 in ~w(top bottom)))) |> Enum.uniq()
    base = %{"kind" => kind, "values" => values}
    if negated?, do: Map.put(base, "not", true), else: base
  end

  defp parse_chosen_condition(%{"kind" => kind}) when kind in ~w(top bottom), do: normalize_chosen_condition(%{"kind" => kind})
  defp parse_chosen_condition(_condition), do: new_chosen_condition(false)

  def chosen_columns(%{"join" => join} = filter, bottom_columns, column_count, {top, bottom}) do
    combine = if join == "or", do: &Enum.any?/2, else: &Enum.all?/2
    %{"conditions" => conditions} = normalize_chosen_filter(filter)

    Enum.filter(0..(column_count - 1)//1, fn column ->
      cells = %{top: Enum.at(top, column), bottom: Enum.at(bottom, column), bottom?: column in bottom_columns}
      combine.(conditions, &chosen_condition_met?(&1, cells))
    end)
  end

  defp chosen_condition_met?(%{"kind" => kind, "values" => values} = condition, cells) do
    matched = condition_matches?(kind, values, cells)
    if condition["not"], do: not matched, else: matched
  end

  defp condition_matches?("using", values, cells), do: using_match?(values, cells)
  defp condition_matches?("bottom_is", values, cells), do: any_match?(values, [cells.bottom])
  defp condition_matches?("top_is", values, cells), do: any_match?(values, [cells.top])
  defp condition_matches?("has", values, cells), do: any_match?(values, [cells.top, cells.bottom])

  defp using_match?(values, cells) do
    Enum.any?(values, fn
      "bottom" -> cells.bottom?
      "top" -> not cells.bottom?
      value -> cell_matches?(value, used_cell(cells))
    end)
  end

  defp used_cell(cells), do: if(cells.bottom?, do: cells.bottom, else: cells.top)

  defp any_match?(values, cells), do: Enum.any?(values, fn value -> Enum.any?(cells, &cell_matches?(value, &1)) end)

  def chosen_filter_label(%{"join" => join} = filter) do
    %{"conditions" => conditions} = normalize_chosen_filter(filter)
    "slots " <> Enum.map_join(conditions, " #{join} ", &chosen_condition_label/1)
  end

  defp chosen_condition_label(%{"kind" => kind, "values" => values} = condition) do
    {_kind, label} = List.keyfind(@chosen_kinds, kind, 0)
    label = if condition["not"], do: @negated_labels[kind], else: label
    "#{label} #{Enum.join(values, "/")}"
  end

  defp cell_matches?(match, %{sin: _sin, tier: _tier} = cell), do: priority_match?(match, cell)
  defp cell_matches?(_match, _cell), do: false

  defp slot_matches?([], top_cell, bottom_cell), do: skill_cell?(top_cell) or skill_cell?(bottom_cell)
  defp slot_matches?(matches, top_cell, bottom_cell), do: Enum.any?(matches, &chip_matches?(&1, top_cell, bottom_cell))

  defp chip_matches?("top", top_cell, _bottom_cell), do: skill_cell?(top_cell)
  defp chip_matches?("bottom", _top_cell, bottom_cell), do: skill_cell?(bottom_cell)
  defp chip_matches?(chip, top_cell, bottom_cell), do: priority_match?(chip, top_cell) or priority_match?(chip, bottom_cell)

  defp skill_cell?(%{sin: _sin, tier: _tier}), do: true
  defp skill_cell?(_cell), do: false

  def tray_count_matches?(%{"cmp" => "eq", "value" => n}, count), do: count == n
  def tray_count_matches?(%{"cmp" => "gte", "value" => n}, count), do: count >= n
  def tray_count_matches?(%{"cmp" => "lte", "value" => n}, count), do: count <= n

  def condition_leaf(params), do: params |> build_leaf() |> put_not(params)

  defp build_leaf(%{"op" => @sinner_count_op} = params) do
    %{
      "op" => @sinner_count_op,
      "cmp" => if(params["cmp"] in @count_cmps, do: params["cmp"], else: "gte"),
      "value" => max(parse_count(params["value"]) || 1, 1)
    }
  end

  defp build_leaf(%{"op" => @fight_op}), do: %{"op" => @fight_op}

  defp build_leaf(%{"op" => @tray_count_op} = params) do
    %{
      "op" => @tray_count_op,
      "sinners" => parse_sinners(params["sinners_csv"]),
      "matches" => params["matches"] |> List.wrap() |> Enum.filter(&(chip_term?(&1) or &1 in where_extras())) |> Enum.uniq(),
      "cmp" => if(params["cmp"] in @count_cmps, do: params["cmp"], else: "gte"),
      "value" => parse_count(params["value"]) || 1
    }
  end

  defp build_leaf(%{"op" => @position_op} = params) do
    %{"op" => @position_op, "sinners" => parse_sinners(params["sinners_csv"]), "position" => parse_skill(params)}
  end

  defp build_leaf(params) do
    %{"op" => "hook", "hook" => String.trim(params["hook"] || "")}
  end

  defp put_not(leaf, %{"not" => negated}) when negated in ["true", true], do: Map.put(leaf, "not", true)
  defp put_not(leaf, _params), do: leaf

  defp parse_sinners(csv) when is_binary(csv), do: csv |> String.split(",", trim: true) |> Enum.filter(&(&1 in SinnerProfiles.sinners())) |> Enum.uniq()
  defp parse_sinners(_csv), do: []

  def sinner_count_matches?(leaf, count), do: tray_count_matches?(leaf, count)

  defp cmp_symbol("eq"), do: "="
  defp cmp_symbol("gte"), do: ">="
  defp cmp_symbol("lte"), do: "<="

  defp leaf_label(%{"not" => true, "op" => op} = leaf, names) when op not in ["hook", "boss_fight"], do: "not " <> leaf_label(Map.delete(leaf, "not"), names)

  defp leaf_label(%{"op" => @sinner_count_op} = leaf, _names), do: "sinners #{cmp_symbol(leaf["cmp"])} #{leaf["value"]}"

  defp leaf_label(%{"op" => "boss_fight"} = leaf, _names), do: if(leaf["not"], do: "not a boss fight", else: "boss fight")

  defp leaf_label(%{"op" => @tray_count_op} = leaf, names) do
    owner =
      case leaf["sinners"] do
        [_ | _] = sinners -> Enum.map_join(sinners, "/", &Map.get(names, &1, SinnerProfiles.label(&1))) <> " "
        _ -> ""
      end

    what = if leaf["matches"] in [nil, []], do: "any", else: Enum.join(leaf["matches"], "/")
    "#{owner}#{what} slots #{cmp_symbol(leaf["cmp"])} #{leaf["value"]}"
  end

  defp leaf_label(%{"op" => @position_op} = leaf, names) do
    who =
      case leaf["sinners"] do
        [_ | _] = sinners -> Enum.map_join(sinners, "/", &Map.get(names, &1, SinnerProfiles.label(&1)))
        _ -> "(pick a sinner)"
      end

    where =
      case skill_tokens(leaf["position"]) do
        [] -> "none"
        tokens -> Enum.join(tokens, ", ")
      end

    "#{who} at position #{where}"
  end

  defp leaf_label(%{"op" => "hook", "hook" => hook} = leaf, _names) do
    name = if hook in [nil, ""], do: "(no hook)", else: hook
    if leaf["not"], do: "#{name} off", else: "#{name} on"
  end

  def blank do
    chain = new_playbook("chain", "Chain fast")
    chain_a_res = %{new_playbook("chain", "Chain A-res") | "actions" => [Map.put(new_action("chain"), "mode", "a_res")]}
    focused = new_playbook("focused", "Win rate")
    lineup = new_lineup("Lineup")

    %{
      "version" => 4,
      "profiles" => %{},
      "playbooks" => [chain, chain_a_res, focused],
      "tracks" =>
        Map.new(@tracks, fn track ->
          playbook = default_playbook(track, chain, chain_a_res, focused)
          {track, [%{"from_floor" => 1, "playbook" => playbook["id"]}]}
        end),
      "lineups" => [lineup],
      "lineup_tracks" => Map.new(@venues, &{&1, [%{"from_floor" => 1, "lineup" => lineup["id"]}]})
    }
  end

  defp default_playbook("normal_chain", chain, _chain_a_res, _focused), do: chain
  defp default_playbook(track, _chain, chain_a_res, focused), do: if(track_kind(track) == "chain", do: chain_a_res, else: focused)

  def new_playbook(kind, name) do
    %{
      "id" => GiftPlans.new_id("pb"),
      "name" => name,
      "kind" => kind,
      "max_retries" => @default_max_retries,
      "actions" => default_actions(kind)
    }
  end

  defp default_actions("chain"), do: [new_action("chain")]
  defp default_actions("focused"), do: [new_action("win_rate"), new_action("commit")]

  def new_action(type) when type in ~w(win_rate damage_rate commit retry), do: %{"id" => GiftPlans.new_id("ac"), "type" => type}

  def new_action("dodge"),
    do: %{"id" => GiftPlans.new_id("ac"), "type" => "dodge", "who" => "everyone", "sinners" => [], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "none"}, "skip_bottom_target" => true}

  def new_action("ego") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "ego",
      "who" => "everyone",
      "sinners" => [],
      "skill" => %{"pick" => "all"},
      "grade" => "zayin",
      "corrode" => false,
      "enemy" => %{"pick" => "none"}
    }
  end

  def new_action("target") do
    put_row(
      %{
        "id" => GiftPlans.new_id("ac"),
        "type" => "target",
        "who" => "everyone",
        "sinners" => [],
        "skill" => %{"pick" => "all"},
        "enemy" => %{"pick" => "last", "offset" => 1, "step" => "left"}
      },
      "priority",
      nil
    )
  end

  def new_action("if") do
    %{"id" => GiftPlans.new_id("ac"), "type" => "if", "condition" => Conditions.add(nil, "", @default_leaf), "then" => [], "elifs" => [], "else" => nil}
  end

  def new_action("chain"), do: %{"id" => GiftPlans.new_id("ac"), "type" => "chain", "mode" => "fast", "pins" => []}

  def normalize_dodge(%{"type" => "dodge"} = holder) do
    holder
    |> Map.put("type", "target")
    |> Map.put("row", "priority")
    |> Map.put("priority", %{"order" => ["dodge"]})
    |> Map.put_new("skip_bottom_target", true)
  end

  def normalize_dodge(holder), do: holder

  def convert_action(action, kind) when kind in ~w(top bottom priority) do
    action = normalize_dodge(action)

    action
    |> Map.drop(~w(grade corrode))
    |> Map.put("type", "target")
    |> Map.put_new("row", "bottom")
    |> Map.put_new("enemy", %{"pick" => "first"})
  end

  def convert_action(action, "dodge") do
    action
    |> Map.drop(~w(grade corrode row priority mode max_defenses))
    |> Map.put("type", "dodge")
    |> Map.put_new("enemy", %{"pick" => "none"})
    |> Map.put_new("skip_bottom_target", true)
  end

  def convert_action(action, "ego") do
    action
    |> Map.drop(~w(row priority mode max_defenses))
    |> Map.put("type", "ego")
    |> Map.put_new("grade", "zayin")
    |> Map.put_new("corrode", false)
    |> Map.put_new("enemy", %{"pick" => "none"})
  end

  def convert_action(action, "nothing") do
    action
    |> Map.drop(~w(grade corrode row priority enemy mode max_defenses))
    |> Map.put("type", "nothing")
  end

  def convert_action(action, _kind), do: action

  def seed_sinner(%{"sinners" => []} = holder, sinner) when is_binary(sinner), do: %{holder | "sinners" => [sinner]}
  def seed_sinner(holder, _sinner), do: holder

  def new_pin, do: put_row(%{"type" => "target", "who" => "everyone", "sinners" => [], "skill" => %{"pick" => "all"}}, "priority", nil)

  def paint(entries, floor, id, key \\ "playbook") do
    entries
    |> Enum.reject(&(&1["from_floor"] == floor))
    |> Kernel.++([%{"from_floor" => floor, key => id}])
    |> normalize_track(key)
  end

  def erase(entries, floor, key \\ "playbook")
  def erase(entries, 1, _key), do: entries

  def erase(entries, floor, key) do
    entries
    |> Enum.reject(&(&1["from_floor"] == floor))
    |> normalize_track(key)
  end

  def normalize_track(entries, key \\ "playbook") do
    entries
    |> Enum.sort_by(& &1["from_floor"])
    |> Enum.dedup_by(& &1[key])
  end

  def schedule?(%{"type" => "schedule"}), do: true
  def schedule?(_item), do: false

  def segment_froms(schedule), do: Enum.map(schedule["segments"], & &1["from_turn"])

  def loop_from(schedule), do: schedule["loop_from"]

  def looping?(schedule), do: is_integer(schedule["loop_from"])

  def loop_segment?(schedule, from), do: looping?(schedule) and from >= schedule["loop_from"]

  def segment_label(schedule, from) do
    if loop_segment?(schedule, from), do: "Loop T#{from - schedule["loop_from"] + 1}", else: range_label(schedule, from)
  end

  def loop_turns_label(schedule, from) do
    start = schedule["loop_from"]
    length = Enum.count(schedule["segments"], &(&1["from_turn"] >= start))
    first = start + rem(from - start, length)
    turns = Enum.map(0..3, &"T#{first + &1 * length}")
    Enum.join(turns, ", ") <> ", ..."
  end

  defp range_label(schedule, from) do
    next = schedule |> segment_froms() |> Enum.filter(&(&1 > from)) |> Enum.min(fn -> nil end)

    cond do
      is_nil(next) -> "Turns #{from}+"
      next - 1 == from -> "Turn #{from}"
      true -> "Turns #{from}-#{next - 1}"
    end
  end

  def segment_at(schedule, turn) do
    if loop_segment?(schedule, turn), do: loop_segment_at(schedule, turn), else: plain_segment_at(schedule, turn)
  end

  defp loop_segment_at(schedule, turn) do
    body = Enum.filter(schedule["segments"], &(&1["from_turn"] >= schedule["loop_from"]))
    Enum.at(body, rem(turn - schedule["loop_from"], length(body)))
  end

  defp plain_segment_at(schedule, turn) do
    schedule["segments"]
    |> Enum.filter(&(&1["from_turn"] <= turn))
    |> Enum.max_by(& &1["from_turn"], fn -> nil end)
  end

  def find_item(items, id) do
    Enum.find_value(items, fn
      %{"id" => ^id} = item -> item
      %{"type" => "if"} = block -> Enum.find_value(branches(block), &find_item(branch_actions(block, &1), id))
      %{"type" => "schedule"} = schedule -> Enum.find_value(schedule["segments"], &find_item(&1["actions"], id))
      _item -> nil
    end)
  end

  def update_list_containing(items, id, fun) do
    if Enum.any?(items, &(&1["id"] == id)) do
      fun.(items)
    else
      Enum.map(items, fn
        %{"type" => "if"} = block ->
          Enum.reduce(branches(block), block, fn branch, acc -> update_branch_actions(acc, branch, &update_list_containing(&1, id, fun)) end)

        %{"type" => "schedule"} = schedule ->
          Map.update!(schedule, "segments", fn segments ->
            Enum.map(segments, &Map.update!(&1, "actions", fn actions -> update_list_containing(actions, id, fun) end))
          end)

        item ->
          item
      end)
    end
  end

  def update_container(items, "root", fun), do: fun.(items)

  def update_container(items, container, fun) do
    if branch_container?(container), do: update_branch(items, container, fun), else: update_segment(items, container, fun)
  end

  def branch_container?(container), do: String.contains?(container, "~")

  defp update_branch(items, container, fun) do
    [block_id, branch] = String.split(container, "~")

    update_list_containing(items, block_id, fn list ->
      Enum.map(list, fn
        %{"id" => ^block_id} = block -> update_branch_actions(block, branch, fun)
        item -> item
      end)
    end)
  end

  defp update_segment(items, container, fun) do
    [schedule_id, from] = String.split(container, "|")
    from = String.to_integer(from)

    update_list_containing(items, schedule_id, fn list ->
      Enum.map(list, fn
        %{"id" => ^schedule_id} = schedule ->
          Map.update!(schedule, "segments", fn segments ->
            Enum.map(segments, &if(&1["from_turn"] == from, do: Map.update!(&1, "actions", fun), else: &1))
          end)

        item ->
          item
      end)
    end)
  end

  def container_actions(items, "root"), do: items

  def container_actions(items, container) do
    if branch_container?(container) do
      [block_id, branch] = String.split(container, "~")
      branch_actions(find_item(items, block_id) || %{"then" => []}, branch)
    else
      segment_actions(items, container)
    end
  end

  defp segment_actions(items, container) do
    [schedule_id, from] = String.split(container, "|")
    from = String.to_integer(from)

    with %{"segments" => segments} <- find_item(items, schedule_id),
         %{"actions" => actions} <- Enum.find(segments, &(&1["from_turn"] == from)) do
      actions
    else
      _ -> []
    end
  end

  def scope_actions(items, container) do
    plain = Enum.reject(items, &schedule?/1)

    case owner_container(items, container) do
      "root" -> plain ++ Enum.flat_map(Enum.filter(items, &schedule?/1), fn schedule -> Enum.flat_map(schedule["segments"], & &1["actions"]) end)
      owner -> plain ++ container_actions(items, owner)
    end
  end

  defp owner_container(items, container) do
    if branch_container?(container) do
      [block_id, _branch] = String.split(container, "~")

      segment =
        items
        |> Enum.filter(&schedule?/1)
        |> Enum.find_value(fn schedule ->
          Enum.find_value(schedule["segments"], &if(find_item(&1["actions"], block_id), do: "#{schedule["id"]}|#{&1["from_turn"]}"))
        end)

      segment || "root"
    else
      container
    end
  end

  def normalize_items(items) do
    items
    |> chain_last()
    |> Enum.map(fn
      %{"type" => "schedule"} = schedule -> Map.update!(schedule, "segments", fn segments -> Enum.map(segments, &Map.update!(&1, "actions", fn actions -> chain_last(actions) end)) end)
      item -> item
    end)
  end

  def new_schedule(action) do
    %{"id" => GiftPlans.new_id("sc"), "type" => "schedule", "segments" => [%{"from_turn" => 1, "actions" => [action]}]}
  end

  def wrap_in_schedule(items, action_id) do
    Enum.map(items, fn
      %{"id" => ^action_id, "type" => type} = action when type != "schedule" -> new_schedule(action)
      item -> item
    end)
  end

  def unwrap_schedule(items, schedule_id) do
    Enum.flat_map(items, fn
      %{"id" => ^schedule_id} = schedule -> Enum.find(schedule["segments"], &(&1["from_turn"] == 1))["actions"]
      item -> [item]
    end)
  end

  def update_schedule(items, schedule_id, fun) do
    Enum.map(items, fn
      %{"id" => ^schedule_id, "type" => "schedule"} = schedule -> fun.(schedule)
      item -> item
    end)
  end

  def split_segment(schedule, turn) when turn in 2..@max_turn do
    cond do
      turn in segment_froms(schedule) -> schedule
      loop_segment?(schedule, turn) -> append_loop_segment(schedule)
      true -> add_segment(schedule, turn, plain_segment_at(schedule, turn))
    end
  end

  def split_segment(schedule, _turn), do: schedule

  defp add_segment(schedule, turn, source) do
    segment = %{"from_turn" => turn, "actions" => Enum.map(source["actions"], &refresh_ids/1)}
    Map.update!(schedule, "segments", &Enum.sort_by(&1 ++ [segment], fn s -> s["from_turn"] end))
  end

  defp append_loop_segment(schedule) do
    last = List.last(schedule["segments"])

    if last["from_turn"] >= @max_turn, do: schedule, else: add_segment(schedule, last["from_turn"] + 1, last)
  end

  def move_segment(schedule, from, to) when from != 1 and to in 2..@max_turn do
    if to in segment_froms(schedule) or loop_segment?(schedule, from) or loop_segment?(schedule, to) do
      schedule
    else
      Map.update!(schedule, "segments", fn segments ->
        segments |> Enum.map(&if(&1["from_turn"] == from, do: %{&1 | "from_turn" => to}, else: &1)) |> Enum.sort_by(& &1["from_turn"])
      end)
    end
  end

  def move_segment(schedule, _from, _to), do: schedule

  def remove_segment(schedule, 1), do: schedule

  def remove_segment(schedule, from) do
    if loop_segment?(schedule, from) and (from == schedule["loop_from"] or from != List.last(segment_froms(schedule))) do
      schedule
    else
      Map.update!(schedule, "segments", &Enum.reject(&1, fn segment -> segment["from_turn"] == from end))
    end
  end

  def add_intro_segment(%{"loop_from" => start} = schedule) when is_integer(start) do
    last = List.last(schedule["segments"])

    if last["from_turn"] >= @max_turn do
      schedule
    else
      source = plain_segment_at(schedule, max(start - 1, 1)) || hd(schedule["segments"])
      shifted = Enum.map(schedule["segments"], &if(&1["from_turn"] >= start, do: %{&1 | "from_turn" => &1["from_turn"] + 1}, else: &1))
      intro = %{"from_turn" => start, "actions" => Enum.map(source["actions"], &refresh_ids/1)}
      %{schedule | "segments" => Enum.sort_by([intro | shifted], & &1["from_turn"])} |> Map.put("loop_from", start + 1)
    end
  end

  def add_intro_segment(schedule), do: schedule

  def set_loop(schedule, nil), do: Map.delete(schedule, "loop_from")

  def set_loop(schedule, start) when start in 1..@max_turn do
    schedule = if start in segment_froms(schedule), do: schedule, else: split_segment(Map.delete(schedule, "loop_from"), start)
    {head, body} = Enum.split_with(schedule["segments"], &(&1["from_turn"] < start))
    body = body |> Enum.with_index() |> Enum.map(fn {segment, index} -> %{segment | "from_turn" => start + index} end)
    %{schedule | "segments" => head ++ body} |> Map.put("loop_from", start)
  end

  def set_loop(schedule, _start), do: schedule

  def reorder_container(items, container, ids) do
    update_container(items, container, fn list ->
      by_id = Map.new(list, &{&1["id"], &1})
      ordered = for id <- ids, Map.has_key?(by_id, id), do: by_id[id]
      if length(ordered) == length(list), do: ordered, else: list
    end)
  end

  def reorder_playbooks(playbooks, kind, ids) do
    by_id = Map.new(playbooks, &{&1["id"], &1})
    ordered = for id <- ids, pb = by_id[id], pb["kind"] == kind, do: pb

    if length(ordered) == Enum.count(playbooks, &(&1["kind"] == kind)) do
      {result, _queue} =
        Enum.map_reduce(playbooks, ordered, fn
          %{"kind" => ^kind}, [next | queue] -> {next, queue}
          playbook, queue -> {playbook, queue}
        end)

      result
    else
      playbooks
    end
  end

  def move_to_container(items, from, to, id, ids) do
    moved = find_item(items, id)

    cond do
      is_nil(moved) or from == to -> items
      schedule?(moved) -> items
      into_itself?(moved, to) -> items
      true ->
        removed = update_container(items, from, fn list -> Enum.reject(list, &(&1["id"] == id)) end)

        placed =
          update_container(removed, to, fn list ->
            by_id = Map.new([moved | list], &{&1["id"], &1})
            ordered = for item_id <- ids, Map.has_key?(by_id, item_id), do: by_id[item_id]
            if length(ordered) == length(list) + 1, do: ordered, else: list ++ [moved]
          end)

        if terminal_conflict?(placed, to), do: items, else: placed
    end
  end

  defp into_itself?(moved, to) do
    branch_container?(to) and not is_nil(find_item([moved], hd(String.split(to, "~"))))
  end

  def terminal_conflict?(items, container) do
    actions = if branch_container?(container), do: container_actions(items, container), else: scope_actions(items, container)
    Enum.count(actions, &terminal?/1) > 1
  end

  def tracks_using(data, playbook_id) do
    Enum.filter(@tracks, fn track ->
      Enum.any?(get_in(data, ["tracks", track]) || [], &(&1["playbook"] == playbook_id))
    end)
  end

  def profiles(data) do
    raw = (is_map(data) && data["profiles"]) || %{}
    Map.new(raw, fn {sinner, ids} -> {sinner, List.wrap(ids)} end)
  end

  def put_profile(data, sinner, ids) do
    case ids |> List.wrap() |> Enum.uniq() do
      [] -> Map.put(data, "profiles", Map.delete(profiles(data), sinner))
      ids -> Map.put(data, "profiles", Map.put(profiles(data), sinner, ids))
    end
  end

  def profile_ids_used(data), do: data |> profiles() |> Map.values() |> List.flatten() |> MapSet.new()
end
