defmodule StarlightBot.BattlePlans do
  alias StarlightBot.BattlePlans.Resolver
  alias StarlightBot.Conditions
  alias StarlightBot.GiftPlans

  @tracks ~w(normal_chain hard_chain normal_focused hard_focused lux_chain lux_focused)
  @venues ~w(md_battle md_boss lux)
  @front_line_size 7
  @backup_size 5
  @max_floor 15
  @default_max_retries 5
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
  def skill_picks, do: @skill_picks
  def enemy_picks, do: @skill_picks ++ ["percent"]

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
      action -> [action]
    end)
  end

  def refresh_ids(%{"type" => "if"} = block) do
    Enum.reduce(@branches, Map.put(block, "id", GiftPlans.new_id("ac")), &Map.update!(&2, &1, fn actions -> Enum.map(actions, fn a -> refresh_ids(a) end) end))
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
    profile_id =
      case Integer.parse(params["profile_id"] || "") do
        {id, _} -> id
        :error -> nil
      end

    %{
      "op" => @tray_count_op,
      "match" => if(params["match"] in @tiers ++ @sins, do: params["match"], else: "wrath"),
      "cmp" => if(params["cmp"] in @count_cmps, do: params["cmp"], else: "gte"),
      "value" => parse_count(params["value"]) || 1,
      "profile_id" => profile_id
    }
  end

  def condition_leaf(%{"op" => @position_op} = params) do
    profile_id =
      case Integer.parse(params["profile_id"] || "") do
        {id, _} -> id
        :error -> nil
      end

    value =
      case Integer.parse(params["value"] || "") do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    %{
      "op" => @position_op,
      "profile_id" => profile_id,
      "cmp" => if(params["cmp"] in @position_cmps, do: params["cmp"], else: "is"),
      "pos" => if(params["pos"] in @positions, do: params["pos"], else: "first"),
      "value" => value
    }
  end

  def condition_leaf(params) do
    %{"op" => if(params["op"] == "hook_off", do: "hook_off", else: "hook_on"), "hook" => String.trim(params["hook"] || "")}
  end

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
      case leaf["profile_id"] do
        nil -> ""
        id -> "#{Map.get(names, id, "profile #{id}")} "
      end

    "#{owner}#{leaf["match"]} slots #{cmp_symbol(leaf["cmp"])} #{leaf["value"]}"
  end

  defp leaf_label(%{"op" => @position_op} = leaf, names) do
    who =
      case leaf["profile_id"] do
        nil -> "(no sinner)"
        id -> Map.get(names, id, "profile #{id}")
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
      "version" => 3,
      "max_retries" => @default_max_retries,
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
      "phases" => [%{"from_turn" => 1, "actions" => default_actions(kind)}]
    }
  end

  defp default_actions("chain"), do: [new_action("chain_fast")]
  defp default_actions("focused"), do: [new_action("win_rate"), new_action("commit")]

  def new_action(type) when type in ~w(win_rate damage_rate commit clear retry), do: %{"id" => GiftPlans.new_id("ac"), "type" => type}

  def new_action("dodge"),
    do: %{"id" => GiftPlans.new_id("ac"), "type" => "dodge", "who" => "only", "profile_ids" => [], "skill" => %{"pick" => "first"}}

  def new_action("ego") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "ego",
      "who" => "only",
      "profile_ids" => [],
      "skill" => %{"pick" => "first"},
      "grade" => "zayin",
      "corrode" => false
    }
  end

  def new_action("target") do
    %{
      "id" => GiftPlans.new_id("ac"),
      "type" => "target",
      "who" => "only",
      "profile_ids" => [],
      "skill" => %{"pick" => "first"},
      "row" => "bottom",
      "enemy" => %{"pick" => "first"}
    }
  end

  def new_action("if") do
    %{"id" => GiftPlans.new_id("ac"), "type" => "if", "condition" => Conditions.add(nil, "", @hook_leaf), "then" => [], "else" => []}
  end

  def new_action(type) when type in @chain_actions, do: %{"id" => GiftPlans.new_id("ac"), "type" => type, "pins" => []}

  def new_pin, do: %{"who" => "only", "profile_ids" => [], "skill" => %{"pick" => "first"}, "row" => "bottom"}

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

  def split_phase(playbook, turn) when turn > 1 do
    if Enum.any?(playbook["phases"], &(&1["from_turn"] == turn)) do
      playbook
    else
      source = Resolver.phase_for(playbook, turn)
      actions = Enum.map(source["actions"], &refresh_ids/1)
      phases = Enum.sort_by(playbook["phases"] ++ [%{"from_turn" => turn, "actions" => actions}], & &1["from_turn"])
      Map.put(playbook, "phases", phases)
    end
  end

  def remove_phase(playbook, 1), do: playbook

  def remove_phase(playbook, turn) do
    Map.update!(playbook, "phases", fn phases -> Enum.reject(phases, &(&1["from_turn"] == turn)) end)
  end

  def tracks_using(data, playbook_id) do
    Enum.filter(@tracks, fn track ->
      Enum.any?(get_in(data, ["tracks", track]) || [], &(&1["playbook"] == playbook_id))
    end)
  end

  def profile_ids_used(data) do
    for playbook <- data["playbooks"] || [],
        phase <- playbook["phases"],
        action <- flatten_actions(phase["actions"]),
        id <- (action["profile_ids"] || []) ++ Enum.flat_map(action["pins"] || [], &(&1["profile_ids"] || [])) ++ Enum.map(Conditions.leaves(action["condition"]), & &1["profile_id"]),
        is_integer(id),
        into: MapSet.new(),
        do: id
  end
end
