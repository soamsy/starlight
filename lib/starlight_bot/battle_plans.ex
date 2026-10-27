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
  @chain_actions ~w(chain_fast chain_a_res)
  @common_actions ~w(win_rate damage_rate commit clear dodge ego retry)
  @focused_actions ~w(target)
  @block_actions ~w(if)
  @branches ~w(then else)
  @hook_leaf %{"op" => "hook_on", "hook" => ""}
  @sinner_ops ~w(sinners_eq sinners_gte sinners_lte)
  @tray_count_op "tray_count"
  @position_op "sinner_position"
  @fight_ops ~w(boss_fight not_boss_fight)
  @positions ~w(first last exact)
  @position_cmps ~w(is is_not gt lt)
  @count_cmps ~w(eq gte lte)
  @skill_picks ~w(first last exact up_to)
  @grades ~w(zayin teth he waw)
  @rows ~w(top bottom priority)
  @sins ~w(wrath lust sloth gluttony gloom pride envy)
  @tiers ~w(s3 s2 s1)
  @priority_values @tiers ++ @sins ++ ["dodge"]
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
  def skill_picks, do: @skill_picks
  def enemy_picks, do: ["none"] ++ @skill_picks ++ ["percent"]

  def percent_index(count, percent), do: round((count - 1) * percent / 100)

  def filter_by_height(targets, %{"dir" => dir, "pct" => pct}) when dir in ["high", "low"] and targets != [] do
    keep = max(ceil(length(targets) * pct / 100), 1)
    order = if dir == "high", do: :asc, else: :desc
    kept = targets |> Enum.sort_by(fn %{icon: {_x, y}} -> y end, order) |> Enum.take(keep)
    Enum.filter(targets, &(&1 in kept))
  end

  def filter_by_height(targets, _height), do: targets

  def height_label(%{"dir" => dir, "pct" => pct}) when dir in ["high", "low"],
    do: " among the #{if dir == "high", do: "highest", else: "lowest"} #{pct}%"

  def height_label(_height), do: ""
  def grades, do: @grades
  def rows, do: @rows
  def tiers, do: @tiers
  def priority_values, do: @priority_values
  def count_cmps, do: @count_cmps

  def put_row(holder, "priority", order) do
    order =
      if is_map(holder["priority"]),
        do: order |> List.wrap() |> Enum.filter(&(&1 in @priority_values)) |> Enum.uniq(),
        else: @default_priority_order

    holder |> Map.put("row", "priority") |> Map.put("priority", %{"order" => order})
  end

  def put_row(holder, row, _order) do
    holder |> Map.put("row", if(row == "top", do: "top", else: "bottom")) |> Map.delete("priority")
  end

  def put_keep(%{"row" => "priority"} = holder, min, max) do
    min = parse_count(min)
    max = parse_count(max)
    min = if min && max && min > max, do: max, else: min

    Map.update!(holder, "priority", fn priority ->
      priority
      |> Map.drop(["min", "max"])
      |> then(&if(min, do: Map.put(&1, "min", min), else: &1))
      |> then(&if(max, do: Map.put(&1, "max", max), else: &1))
    end)
  end

  def put_keep(holder, _min, _max), do: holder

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_count(_value), do: nil

  def pick_row(%{"row" => "top"}, _top, _bottom), do: :top

  def pick_row(%{"row" => "priority", "priority" => %{"order" => order}}, top, bottom) do
    Enum.find_value(order, :bottom, fn
      "dodge" ->
        :dodge

      value ->
        cond do
          priority_match?(value, bottom) -> :bottom
          priority_match?(value, top) -> :top
          true -> nil
        end
    end)
  end

  def pick_row(_holder, _top, _bottom), do: :bottom

  def allocate_rows(%{"priority" => %{"order" => order} = priority}, cells) do
    dodge_rank = Enum.find_index(order, &(&1 == "dodge"))

    ranked =
      cells
      |> Enum.map(fn {column, top, bottom} ->
        {rank, row} = best_match(order, top, bottom)
        %{column: column, rank: rank, row: row, kept?: is_nil(dodge_rank) or rank < dodge_rank}
      end)
      |> Enum.sort_by(&{&1.rank, &1.column})

    kept = ranked |> Enum.filter(& &1.kept?) |> Enum.map(& &1.column)
    kept = if priority["max"], do: Enum.take(kept, priority["max"]), else: kept
    shortfall = (priority["min"] || 0) - length(kept)
    rescued = ranked |> Enum.reject(&(&1.column in kept)) |> Enum.take(max(shortfall, 0)) |> Enum.map(& &1.column)

    Map.new(ranked, fn %{column: column, row: row} -> {column, if(column in kept or column in rescued, do: row, else: :dodge)} end)
  end

  defp best_match(order, top, bottom) do
    order
    |> Enum.with_index()
    |> Enum.find_value({length(order), :bottom}, fn
      {"dodge", _rank} ->
        nil

      {value, rank} ->
        cond do
          priority_match?(value, bottom) -> {rank, :bottom}
          priority_match?(value, top) -> {rank, :top}
          true -> nil
        end
    end)
  end

  def cell_label(%{sin: sin, tier: tier}), do: "#{sin}/#{tier_name(tier)}"

  defp priority_match?(value, %{tier: tier}) when value in @tiers, do: tier_name(tier) == value
  defp priority_match?(value, %{sin: sin}), do: Atom.to_string(sin) == value

  defp tier_name(tier), do: tier |> Atom.to_string() |> String.replace_prefix("skill", "s")

  def row_label(%{"row" => "priority", "priority" => %{"order" => []}}), do: "priority (empty)"
  def row_label(%{"row" => "priority", "priority" => %{"order" => order} = priority}),
    do: "priority #{Enum.join(order, " > ")}#{keep_label(priority["min"], priority["max"])}"
  def row_label(%{"row" => row}), do: row

  defp keep_label(nil, nil), do: ""
  defp keep_label(min, nil), do: ", keep at least #{min}"
  defp keep_label(nil, max), do: ", keep at most #{max}"
  defp keep_label(n, n), do: ", keep #{n}"
  defp keep_label(min, max), do: ", keep #{min}-#{max}"

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

  def action_types(kind), do: branch_action_types(kind) ++ @block_actions

  def branch_action_types("chain"), do: @common_actions ++ @chain_actions
  def branch_action_types("focused"), do: @common_actions ++ @focused_actions

  def branches, do: @branches
  def hook_leaf, do: @hook_leaf

  def chain_action?(type), do: type in @chain_actions

  def terminal?(%{"type" => "if"} = block), do: Enum.any?(@branches, fn branch -> Enum.any?(block[branch], &terminal?/1) end)
  def terminal?(%{"type" => type}), do: chain_action?(type)

  def chain_allowed_in?(actions, block_id, branch) do
    Enum.find_value(actions, fn
      %{"id" => ^block_id} = block ->
        no_other_terminal?(actions, block_id) and not Enum.any?(block[branch], &terminal?/1)

      %{"type" => "if"} = block ->
        Enum.find_value(@branches, fn inner ->
          case chain_allowed_in?(block[inner], block_id, branch) do
            nil -> nil
            allowed? -> allowed? and no_other_terminal?(actions, block["id"])
          end
        end)

      _action ->
        nil
    end) || false
  end

  defp no_other_terminal?(actions, id), do: not Enum.any?(actions, &(&1["id"] != id and terminal?(&1)))

  def chain_last(actions) do
    {terminal, other} = actions |> Enum.map(&sort_branches/1) |> Enum.split_with(&terminal?/1)
    other ++ terminal
  end

  defp sort_branches(%{"type" => "if"} = block), do: Enum.reduce(@branches, block, &Map.update!(&2, &1, fn actions -> chain_last(actions) end))
  defp sort_branches(action), do: action

  def flatten_actions(actions) do
    Enum.flat_map(actions, fn
      %{"type" => "if"} = block -> [block | Enum.flat_map(@branches, &flatten_actions(block[&1]))]
      %{"type" => "schedule"} = schedule -> Enum.flat_map(schedule["segments"], &flatten_actions(&1["actions"]))
      action -> [action]
    end)
  end

  def refresh_ids(%{"type" => "if"} = block) do
    Enum.reduce(@branches, Map.put(block, "id", GiftPlans.new_id("ac")), &Map.update!(&2, &1, fn actions -> Enum.map(actions, fn a -> refresh_ids(a) end) end))
  end

  def refresh_ids(%{"type" => "schedule"} = schedule) do
    segments = Enum.map(schedule["segments"], &Map.update!(&1, "actions", fn actions -> Enum.map(actions, fn a -> refresh_ids(a) end) end))
    %{schedule | "id" => GiftPlans.new_id("sc"), "segments" => segments}
  end

  def refresh_ids(action), do: Map.put(action, "id", GiftPlans.new_id("ac"))

  def condition_label(tree, profile_names \\ %{})
  def condition_label(nil, _profile_names), do: "always"
  def condition_label(tree, profile_names), do: Conditions.label(tree, &leaf_label(&1, profile_names))

  def sinner_leaf?(%{"op" => op}), do: op in @sinner_ops
  def sinner_leaf?(_node), do: false

  def tray_leaf?(%{"op" => @tray_count_op}), do: true
  def tray_leaf?(_node), do: false

  def position_leaf?(%{"op" => @position_op}), do: true
  def position_leaf?(_node), do: false

  def fight_leaf?(%{"op" => op}), do: op in @fight_ops
  def fight_leaf?(_node), do: false

  def positions, do: @positions
  def position_cmps, do: @position_cmps

  def position_matches?(%{"pos" => pos, "value" => n, "cmp" => cmp}, index, count) do
    target =
      case pos do
        "first" -> 0
        "last" -> count - 1
        "exact" -> n - 1
      end

    case cmp do
      "is" -> index == target
      "is_not" -> index != target
      "gt" -> index > target
      "lt" -> index < target
    end
  end

  def sins, do: @sins

  def tray_count(%{"match" => match}, {top, bottom}, columns) do
    top
    |> Enum.zip(bottom)
    |> Enum.with_index()
    |> Enum.count(fn {{top_cell, bottom_cell}, column} ->
      (columns == :all or column in columns) and slot_matches?(match, top_cell, bottom_cell)
    end)
  end

  def first_with(columns, match, n, {top, bottom}) do
    columns |> Enum.filter(&slot_matches?(match, Enum.at(top, &1), Enum.at(bottom, &1))) |> Enum.take(n)
  end

  defp slot_matches?(match, top_cell, bottom_cell), do: priority_match?(match, top_cell) or priority_match?(match, bottom_cell)

  def tray_count_matches?(%{"cmp" => "eq", "value" => n}, count), do: count == n
  def tray_count_matches?(%{"cmp" => "gte", "value" => n}, count), do: count >= n
  def tray_count_matches?(%{"cmp" => "lte", "value" => n}, count), do: count <= n

  def condition_leaf(%{"op" => op} = params) when op in @sinner_ops do
    value =
      case Integer.parse(params["value"] || "") do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    %{"op" => op, "value" => value}
  end

  def condition_leaf(%{"op" => op}) when op in @fight_ops, do: %{"op" => op}

  def condition_leaf(%{"op" => @tray_count_op} = params) do
    %{
      "op" => @tray_count_op,
      "match" => if(params["match"] in @tiers ++ @sins, do: params["match"], else: "wrath"),
      "cmp" => if(params["cmp"] in @count_cmps, do: params["cmp"], else: "gte"),
      "value" => parse_count(params["value"]) || 1,
      "sinner" => parse_sinner(params["sinner"])
    }
  end

  def condition_leaf(%{"op" => @position_op} = params) do
    value =
      case Integer.parse(params["value"] || "") do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    %{
      "op" => @position_op,
      "sinner" => parse_sinner(params["sinner"]),
      "cmp" => if(params["cmp"] in @position_cmps, do: params["cmp"], else: "is"),
      "pos" => if(params["pos"] in @positions, do: params["pos"], else: "first"),
      "value" => value
    }
  end

  def condition_leaf(params) do
    %{"op" => if(params["op"] == "hook_off", do: "hook_off", else: "hook_on"), "hook" => String.trim(params["hook"] || "")}
  end

  defp parse_sinner(sinner), do: if(sinner in SinnerProfiles.sinners(), do: sinner)

  def sinner_count_matches?(%{"op" => "sinners_eq", "value" => n}, count), do: count == n
  def sinner_count_matches?(%{"op" => "sinners_gte", "value" => n}, count), do: count >= n
  def sinner_count_matches?(%{"op" => "sinners_lte", "value" => n}, count), do: count <= n

  defp cmp_symbol("eq"), do: "="
  defp cmp_symbol("gte"), do: ">="
  defp cmp_symbol("lte"), do: "<="

  defp leaf_label(%{"op" => "sinners_eq", "value" => n}, _names), do: "sinners = #{n}"
  defp leaf_label(%{"op" => "sinners_gte", "value" => n}, _names), do: "sinners >= #{n}"
  defp leaf_label(%{"op" => "sinners_lte", "value" => n}, _names), do: "sinners <= #{n}"

  defp leaf_label(%{"op" => "boss_fight"}, _names), do: "boss fight"
  defp leaf_label(%{"op" => "not_boss_fight"}, _names), do: "not a boss fight"

  defp leaf_label(%{"op" => @tray_count_op} = leaf, names) do
    owner =
      case leaf["sinner"] do
        nil -> ""
        sinner -> "#{Map.get(names, sinner, SinnerProfiles.label(sinner))} "
      end

    "#{owner}#{leaf["match"]} slots #{cmp_symbol(leaf["cmp"])} #{leaf["value"]}"
  end

  defp leaf_label(%{"op" => @position_op} = leaf, names) do
    who =
      case leaf["sinner"] do
        nil -> "(no sinner)"
        sinner -> Map.get(names, sinner, SinnerProfiles.label(sinner))
      end

    where =
      case {leaf["cmp"], leaf["pos"]} do
        {cmp, "exact"} when cmp in ["gt", "lt"] -> "position #{leaf["value"]}"
        {_cmp, "exact"} -> "at position #{leaf["value"]}"
        {_cmp, pos} -> pos
      end

    relation =
      case leaf["cmp"] do
        "is_not" -> "is not"
        "gt" -> "is after"
        "lt" -> "is before"
        _ -> "is"
      end

    "#{who} #{relation} #{where}"
  end

  defp leaf_label(%{"op" => op, "hook" => hook}, _names) do
    name = if hook in [nil, ""], do: "(no hook)", else: hook
    if op == "hook_off", do: "#{name} off", else: "#{name} on"
  end

  def blank do
    chain = new_playbook("chain", "Chain fast")
    focused = new_playbook("focused", "Win rate")
    lineup = new_lineup("Lineup")

    %{
      "version" => 4,
      "max_retries" => @default_max_retries,
      "profiles" => %{},
      "playbooks" => [chain, focused],
      "tracks" =>
        Map.new(@tracks, fn track ->
          playbook = if track_kind(track) == "chain", do: chain, else: focused
          {track, [%{"from_floor" => 1, "playbook" => playbook["id"]}]}
        end),
      "lineups" => [lineup],
      "lineup_tracks" => Map.new(@venues, &{&1, [%{"from_floor" => 1, "lineup" => lineup["id"]}]})
    }
  end

  def new_playbook(kind, name) do
    %{
      "id" => GiftPlans.new_id("pb"),
      "name" => name,
      "kind" => kind,
      "actions" => default_actions(kind)
    }
  end

  defp default_actions("chain"), do: [new_action("chain_fast")]
  defp default_actions("focused"), do: [new_action("win_rate"), new_action("commit")]

  def new_action(type) when type in ~w(win_rate damage_rate commit clear retry), do: %{"id" => GiftPlans.new_id("ac"), "type" => type}

  def new_action("dodge"),
    do: %{"id" => GiftPlans.new_id("ac"), "type" => "dodge", "who" => "only", "sinners" => [], "skill" => %{"pick" => "first"}, "enemy" => %{"pick" => "none"}}

  def new_action("ego") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "ego",
      "who" => "only",
      "sinners" => [],
      "skill" => %{"pick" => "first"},
      "grade" => "zayin",
      "corrode" => false,
      "enemy" => %{"pick" => "none"}
    }
  end

  def new_action("target") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "target",
      "who" => "only",
      "sinners" => [],
      "skill" => %{"pick" => "first"},
      "row" => "bottom",
      "enemy" => %{"pick" => "first"}
    }
  end

  def new_action("if") do
    %{"id" => GiftPlans.new_id("ac"), "type" => "if", "condition" => Conditions.add(nil, "", @hook_leaf), "then" => [], "else" => []}
  end

  def new_action(type) when type in @chain_actions, do: %{"id" => GiftPlans.new_id("ac"), "type" => type, "pins" => []}

  def convert_action(action, kind) when kind in ~w(top bottom priority) do
    action
    |> Map.drop(~w(grade corrode))
    |> Map.put("type", "target")
    |> Map.put_new("row", "bottom")
    |> Map.put_new("enemy", %{"pick" => "first"})
  end

  def convert_action(action, "dodge") do
    action
    |> Map.drop(~w(grade corrode row priority))
    |> Map.put("type", "dodge")
    |> Map.put_new("enemy", %{"pick" => "none"})
  end

  def convert_action(action, "ego") do
    action
    |> Map.drop(~w(row priority))
    |> Map.put("type", "ego")
    |> Map.put_new("grade", "zayin")
    |> Map.put_new("corrode", false)
    |> Map.put_new("enemy", %{"pick" => "none"})
  end

  def convert_action(action, _kind), do: action

  def new_pin, do: %{"who" => "only", "sinners" => [], "skill" => %{"pick" => "first"}, "row" => "bottom"}

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

  def segment_label(schedule, from) do
    next = schedule |> segment_froms() |> Enum.filter(&(&1 > from)) |> Enum.min(fn -> nil end)

    cond do
      is_nil(next) -> "Turns #{from}+"
      next - 1 == from -> "Turn #{from}"
      true -> "Turns #{from}-#{next - 1}"
    end
  end

  def segment_at(schedule, turn) do
    schedule["segments"]
    |> Enum.filter(&(&1["from_turn"] <= turn))
    |> Enum.max_by(& &1["from_turn"], fn -> nil end)
  end

  def find_item(items, id) do
    Enum.find_value(items, fn
      %{"id" => ^id} = item -> item
      %{"type" => "if"} = block -> Enum.find_value(@branches, &find_item(block[&1], id))
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
          Enum.reduce(@branches, block, fn branch, acc -> Map.update!(acc, branch, &update_list_containing(&1, id, fun)) end)

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
        %{"id" => ^block_id} = block -> Map.update!(block, branch, fun)
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
      (find_item(items, block_id) || %{})[branch] || []
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
    if turn in segment_froms(schedule) do
      schedule
    else
      copied = schedule |> segment_at(turn) |> Map.fetch!("actions") |> Enum.map(&refresh_ids/1)
      segment = %{"from_turn" => turn, "actions" => copied}
      Map.update!(schedule, "segments", &Enum.sort_by(&1 ++ [segment], fn s -> s["from_turn"] end))
    end
  end

  def split_segment(schedule, _turn), do: schedule

  def move_segment(schedule, from, to) when from != 1 and to in 2..@max_turn do
    if to in segment_froms(schedule) do
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
    Map.update!(schedule, "segments", &Enum.reject(&1, fn segment -> segment["from_turn"] == from end))
  end

  def reorder_container(items, container, ids) do
    update_container(items, container, fn list ->
      by_id = Map.new(list, &{&1["id"], &1})
      ordered = for id <- ids, Map.has_key?(by_id, id), do: by_id[id]
      if length(ordered) == length(list), do: ordered, else: list
    end)
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

  def terminal_conflict?(items, container), do: Enum.count(scope_actions(items, container), &terminal?/1) > 1

  def tracks_using(data, playbook_id) do
    Enum.filter(@tracks, fn track ->
      Enum.any?(get_in(data, ["tracks", track]) || [], &(&1["playbook"] == playbook_id))
    end)
  end

  def profiles(data), do: (is_map(data) && data["profiles"]) || %{}

  def put_profile(data, sinner, nil), do: Map.put(data, "profiles", Map.delete(profiles(data), sinner))

  def put_profile(data, sinner, profile_id) when is_integer(profile_id),
    do: Map.put(data, "profiles", Map.put(profiles(data), sinner, profile_id))

  def profile_ids_used(data), do: data |> profiles() |> Map.values() |> MapSet.new()
end
