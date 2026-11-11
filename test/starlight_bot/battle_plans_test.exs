defmodule StarlightBot.BattlePlansTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{BattlePlans, Conditions}

  defp entry(floor, id), do: %{"from_floor" => floor, "playbook" => id}

  describe "blank/0" do
    test "every track starts with a floor 1 change point of the matching kind" do
      data = BattlePlans.blank()
      kinds = Map.new(data["playbooks"], &{&1["id"], &1["kind"]})

      for track <- BattlePlans.tracks() do
        assert [%{"from_floor" => 1, "playbook" => id}] = data["tracks"][track]
        assert kinds[id] == BattlePlans.track_kind(track)
      end
    end

    test "every venue starts on one empty lineup, which is flagged until it has sinners" do
      data = BattlePlans.blank()
      [%{"id" => id}] = BattlePlans.lineups(data)

      for venue <- BattlePlans.venues() do
        assert BattlePlans.lineup_track(data, venue) == [%{"from_floor" => 1, "lineup" => id}]
      end

      assert BattlePlans.lineup_issues(data) == ["Lineup 'Lineup' has no sinners."]
    end
  end

  describe "lineup_issues/1" do
    test "flags a plan with no lineups at all" do
      assert BattlePlans.lineup_issues(%{"playbooks" => []}) == ["No lineups yet. Add one so the bot knows who to field."]
    end

    test "flags venues with nothing on floor 1" do
      data = %{
        "lineups" => [%{"id" => "ln_a", "name" => "Full", "sinners" => ["ryoshu"]}],
        "lineup_tracks" => %{"md_battle" => [%{"from_floor" => 1, "lineup" => "ln_a"}], "md_boss" => [%{"from_floor" => 1, "lineup" => "ln_gone"}]}
      }

      assert BattlePlans.lineup_issues(data) == ["MD Boss has no lineup on floor 1.", "Lux has no lineup on floor 1."]
    end
  end

  test "max_retries falls back to the default for missing or invalid values" do
    assert BattlePlans.max_retries(BattlePlans.blank()) == 5
    assert BattlePlans.max_retries(%{"max_retries" => 0}) == 0
    assert BattlePlans.max_retries(%{"max_retries" => -1}) == 5
    assert BattlePlans.max_retries(nil) == 5
  end

  describe "paint/3" do
    test "adds a change point that runs until the next one" do
      assert BattlePlans.paint([entry(1, "a")], 4, "b") == [entry(1, "a"), entry(4, "b")]
    end

    test "painting the playbook already covering a floor is a no-op" do
      assert BattlePlans.paint([entry(1, "a"), entry(4, "b")], 6, "b") == [entry(1, "a"), entry(4, "b")]
    end

    test "merges into the next change point when it would repeat" do
      assert BattlePlans.paint([entry(1, "a"), entry(4, "b")], 2, "b") == [entry(1, "a"), entry(2, "b")]
    end

    test "repainting floor 1 replaces it" do
      assert BattlePlans.paint([entry(1, "a"), entry(4, "b")], 1, "b") == [entry(1, "b")]
    end
  end

  test "formation/1 puts the first 7 in front and up to 5 in backup" do
    sinners = Enum.map(1..13, &"s#{&1}")
    formation = BattlePlans.formation(sinners)

    assert formation.front == Enum.map(1..7, &"s#{&1}")
    assert formation.backup == Enum.map(8..12, &"s#{&1}")
    assert BattlePlans.formation(["ryoshu"]) == %{front: ["ryoshu"], backup: []}
  end

  test "paint/4 and erase/3 work on lineup entries" do
    lineup = fn floor, id -> %{"from_floor" => floor, "lineup" => id} end
    painted = BattlePlans.paint([lineup.(1, "full")], 5, "solo", "lineup")

    assert painted == [lineup.(1, "full"), lineup.(5, "solo")]
    assert BattlePlans.erase(painted, 5, "lineup") == [lineup.(1, "full")]
  end

  describe "erase/2" do
    test "removes a change point so its floors inherit" do
      assert BattlePlans.erase([entry(1, "a"), entry(4, "b"), entry(6, "a")], 4) == [entry(1, "a")]
    end

    test "never removes floor 1" do
      assert BattlePlans.erase([entry(1, "a")], 1) == [entry(1, "a")]
    end
  end

  describe "schedules" do
    defp scheduled(kind \\ "focused") do
      playbook = BattlePlans.new_playbook(kind, "Win rate")
      actions = if kind == "focused", do: playbook["actions"] ++ [BattlePlans.new_action("commit")], else: playbook["actions"]
      [first | _] = actions
      %{playbook | "actions" => BattlePlans.wrap_in_schedule(actions, first["id"])}
    end

    test "wrapping an action puts it in a single turn 1 tab, in place" do
      playbook = scheduled()
      assert [%{"type" => "schedule", "segments" => [%{"from_turn" => 1, "actions" => [%{"type" => "win_rate"}]}]}, %{"type" => "commit"}] = playbook["actions"]
    end

    test "split_segment copies the covering tab's actions with fresh ids" do
      [schedule | _] = scheduled()["actions"]
      split = BattlePlans.split_segment(schedule, 5)

      assert BattlePlans.segment_froms(split) == [1, 5]
      [first, second] = split["segments"]
      assert Enum.map(first["actions"], & &1["type"]) == Enum.map(second["actions"], & &1["type"])
      refute Enum.map(first["actions"], & &1["id"]) == Enum.map(second["actions"], & &1["id"])
      assert BattlePlans.split_segment(split, 5) == split
    end

    test "split_segment gives branch actions fresh ids" do
      block = BattlePlans.new_action("if") |> Map.put("then", [BattlePlans.new_action("retry")])
      schedule = BattlePlans.new_schedule(block)

      [first, second] = BattlePlans.split_segment(schedule, 3)["segments"]
      [old_block] = first["actions"]
      [new_block] = second["actions"]
      refute old_block["id"] == new_block["id"]
      refute hd(old_block["then"])["id"] == hd(new_block["then"])["id"]
    end

    test "labels cover single turns, ranges and the open tail" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.split_segment(2) |> BattlePlans.split_segment(4)

      assert Enum.map(BattlePlans.segment_froms(schedule), &BattlePlans.segment_label(schedule, &1)) == ["Turn 1", "Turns 2-3", "Turns 4+"]
    end

    test "tab 1 cannot be moved or removed, others can" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.split_segment(3)

      assert BattlePlans.move_segment(schedule, 1, 2) == schedule
      assert BattlePlans.remove_segment(schedule, 1) == schedule
      assert BattlePlans.segment_froms(BattlePlans.move_segment(schedule, 3, 6)) == [1, 6]
      assert BattlePlans.segment_froms(BattlePlans.remove_segment(schedule, 3)) == [1]
    end

    test "a loop repeats its one-turn tabs from the start turn" do
      schedule =
        BattlePlans.new_schedule(BattlePlans.new_action("retry"))
        |> BattlePlans.split_segment(3)
        |> BattlePlans.set_loop(3)
        |> BattlePlans.split_segment(4)
        |> BattlePlans.split_segment(5)

      assert BattlePlans.segment_froms(schedule) == [1, 3, 4, 5]
      assert Enum.map(BattlePlans.segment_froms(schedule), &BattlePlans.segment_label(schedule, &1)) == ["Turns 1-2", "Loop T1", "Loop T2", "Loop T3"]

      froms = Enum.map(1..10, &BattlePlans.segment_at(schedule, &1)["from_turn"])
      assert froms == [1, 1, 3, 4, 5, 3, 4, 5, 3, 4]
    end

    test "a loop tab lists the turns it plays on" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.set_loop(5)
      assert BattlePlans.loop_turns_label(schedule, 5) == "T5, T6, T7, T8, ..."

      schedule = schedule |> BattlePlans.split_segment(6) |> BattlePlans.split_segment(7)
      assert BattlePlans.loop_turns_label(schedule, 5) == "T5, T8, T11, T14, ..."
      assert BattlePlans.loop_turns_label(schedule, 7) == "T7, T10, T13, T16, ..."
    end

    test "loop tabs stay consecutive: only the last can close and none can move" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.set_loop(2) |> BattlePlans.split_segment(9) |> BattlePlans.split_segment(9)

      assert BattlePlans.segment_froms(schedule) == [1, 2, 3, 4]
      assert BattlePlans.move_segment(schedule, 3, 8) == schedule
      assert BattlePlans.remove_segment(schedule, 3) == schedule
      assert BattlePlans.remove_segment(schedule, 2) == schedule
      assert BattlePlans.segment_froms(BattlePlans.remove_segment(schedule, 4)) == [1, 2, 3]
    end

    test "intro tabs can be added ahead of the loop, pushing it later" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.set_loop(1) |> BattlePlans.split_segment(2)

      one = BattlePlans.add_intro_segment(schedule)
      assert BattlePlans.segment_froms(one) == [1, 2, 3]
      assert BattlePlans.loop_from(one) == 2
      assert Enum.map(BattlePlans.segment_froms(one), &BattlePlans.segment_label(one, &1)) == ["Turn 1", "Loop T1", "Loop T2"]

      two = BattlePlans.add_intro_segment(one)
      assert BattlePlans.segment_froms(two) == [1, 2, 3, 4]
      assert Enum.map(BattlePlans.segment_froms(two), &BattlePlans.segment_label(two, &1)) == ["Turn 1", "Turn 2", "Loop T1", "Loop T2"]
      assert Enum.map(1..7, &BattlePlans.segment_at(two, &1)["from_turn"]) == [1, 2, 3, 4, 3, 4, 3]
    end

    test "moving the loop start renumbers the body and clearing it leaves plain tabs" do
      schedule = BattlePlans.new_schedule(BattlePlans.new_action("retry")) |> BattlePlans.set_loop(1) |> BattlePlans.split_segment(2) |> BattlePlans.split_segment(3)

      moved = BattlePlans.set_loop(schedule, 6)
      assert BattlePlans.segment_froms(moved) == [1, 2, 3, 6]
      assert BattlePlans.loop_from(moved) == 6
      assert BattlePlans.segment_at(moved, 9)["from_turn"] == 6

      cleared = BattlePlans.set_loop(moved, nil)
      refute BattlePlans.looping?(cleared)
      assert BattlePlans.segment_at(cleared, 9)["from_turn"] == 6
    end

    test "unwrapping splices tab 1's actions back in place" do
      playbook = scheduled()
      [schedule | _] = playbook["actions"]

      assert playbook["actions"] |> BattlePlans.unwrap_schedule(schedule["id"]) |> Enum.map(& &1["type"]) == ["win_rate", "commit"]
    end

    test "moving an action into a tab and reordering within containers" do
      playbook = scheduled()
      [schedule, commit] = playbook["actions"]
      container = schedule["id"] <> "|1"
      [win_rate] = BattlePlans.container_actions(playbook["actions"], container)

      moved = BattlePlans.move_to_container(playbook["actions"], "root", container, commit["id"], [commit["id"], win_rate["id"]])

      assert Enum.map(moved, & &1["type"]) == ["schedule"]
      assert Enum.map(BattlePlans.container_actions(moved, container), & &1["type"]) == ["commit", "win_rate"]

      reordered = BattlePlans.reorder_container(moved, container, [win_rate["id"], commit["id"]])
      assert Enum.map(BattlePlans.container_actions(reordered, container), & &1["type"]) == ["win_rate", "commit"]
    end

    test "schedules never move into a tab and a second chain action is refused" do
      playbook = scheduled("chain")
      [schedule, chain] = playbook["actions"] ++ [BattlePlans.new_action("chain")]
      container = schedule["id"] <> "|1"
      items = playbook["actions"] ++ [chain]

      assert BattlePlans.move_to_container(items, "root", container, schedule["id"], [schedule["id"]]) == items
      assert BattlePlans.move_to_container(items, "root", container, chain["id"], [chain["id"]]) == items
    end
  end

  describe "if blocks" do
    test "enemy count leaves parse, label and match" do
      leaf = BattlePlans.condition_leaf(%{"op" => "enemy_count", "cmp" => "lte", "value" => "2", "hook" => "ignored"})
      assert leaf == %{"op" => "enemy_count", "cmp" => "lte", "value" => 2}
      assert BattlePlans.condition_leaf(%{"op" => "enemy_count", "cmp" => "eq", "value" => "0"})["value"] == 0
      assert BattlePlans.condition_leaf(%{"op" => "enemy_count"}) == %{"op" => "enemy_count", "cmp" => "gte", "value" => 1}
      assert BattlePlans.condition_label(Conditions.add(nil, "", leaf)) == "enemies <= 2"
      assert BattlePlans.enemy_leaf?(leaf)
      refute BattlePlans.enemy_leaf?(%{"op" => "sinner_count"})
      assert BattlePlans.enemy_count_matches?(leaf, 2)
      refute BattlePlans.enemy_count_matches?(leaf, 3)
    end

    test "sinner count leaves parse, label and match" do
      leaf = BattlePlans.condition_leaf(%{"op" => "sinner_count", "cmp" => "lte", "value" => "2", "hook" => "ignored"})
      assert leaf == %{"op" => "sinner_count", "cmp" => "lte", "value" => 2}
      assert BattlePlans.condition_leaf(%{"op" => "sinner_count", "cmp" => "eq", "value" => "0"})["value"] == 1
      assert BattlePlans.condition_leaf(%{"op" => "sinner_count"}) == %{"op" => "sinner_count", "cmp" => "gte", "value" => 1}
      assert BattlePlans.condition_label(Conditions.add(nil, "", leaf)) == "sinners <= 2"
      assert BattlePlans.sinner_count_matches?(leaf, 1)
      refute BattlePlans.sinner_count_matches?(leaf, 3)
      assert BattlePlans.condition_leaf(%{"op" => "hook", "not" => "true", "hook" => " battle_turn "}) == %{"op" => "hook", "hook" => "battle_turn", "not" => true}
      assert BattlePlans.condition_leaf(%{"op" => "hook", "not" => "false", "hook" => "battle_turn"}) == %{"op" => "hook", "hook" => "battle_turn"}
      assert BattlePlans.condition_label(%{"op" => "hook", "hook" => "battle_turn", "not" => true}) == "battle_turn off"
      assert BattlePlans.condition_label(%{"op" => "hook", "hook" => "battle_turn"}) == "battle_turn on"

      negated = BattlePlans.condition_leaf(%{"op" => "tray_count", "matches" => ["wrath"], "not" => "true", "value" => "2"})
      assert negated["not"] == true
      assert BattlePlans.condition_label(negated) == "not wrath slots >= 2"
      refute Map.has_key?(BattlePlans.condition_leaf(%{"op" => "sinner_count", "not" => "false"}), "not")
      assert BattlePlans.condition_leaf(%{"op" => "sinner_count", "not" => "true", "cmp" => "eq", "value" => "2"}) == %{"op" => "sinner_count", "cmp" => "eq", "value" => 2, "not" => true}
      assert BattlePlans.condition_label(%{"op" => "sinner_count", "cmp" => "eq", "value" => 2, "not" => true}) == "not sinners = 2"
    end

    test "only a plain chain action is terminal, so an if block keeps its place" do
      block = BattlePlans.new_action("if")
      refute BattlePlans.terminal?(Map.put(block, "else", [BattlePlans.new_action("chain")]))
      assert BattlePlans.terminal?(BattlePlans.new_action("chain"))

      target = BattlePlans.new_action("ego")
      chain = BattlePlans.new_action("chain")
      assert Enum.map(BattlePlans.normalize_items([chain, Map.put(block, "else", [chain]), target]), & &1["type"]) == ["if", "ego", "chain"]
    end

    test "a chain in an else if branch survives id refresh and flattening" do
      block = BattlePlans.new_action("if")
      elif = %{BattlePlans.new_elif() | "actions" => [BattlePlans.new_action("chain")]}
      block = Map.put(block, "elifs", [elif])
      refreshed = BattlePlans.refresh_ids(block)
      [new_elif] = refreshed["elifs"]
      refute new_elif["id"] == elif["id"]
      refute hd(new_elif["actions"])["id"] == hd(elif["actions"])["id"]
      assert Enum.any?(BattlePlans.flatten_actions([block]), &(&1["type"] == "chain"))
    end
  end

  describe "boss fight conditions" do
    test "builds and labels both leaves" do
      assert BattlePlans.condition_leaf(%{"op" => "boss_fight", "hook" => "stale"}) == %{"op" => "boss_fight"}
      assert BattlePlans.condition_label(%{"op" => "boss_fight"}) == "boss fight"
      assert BattlePlans.condition_leaf(%{"op" => "boss_fight", "not" => "true"}) == %{"op" => "boss_fight", "not" => true}
      assert BattlePlans.condition_label(%{"op" => "boss_fight", "not" => true}) == "not a boss fight"
      assert BattlePlans.fight_leaf?(%{"op" => "boss_fight", "not" => true})
      refute BattlePlans.fight_leaf?(%{"op" => "hook"})
    end
  end

  describe "profiles/1" do
    test "assigns and clears a sinner's profile, and lists the ids in use" do
      data = BattlePlans.blank()
      assert BattlePlans.profiles(data) == %{}

      data = data |> BattlePlans.put_profile("ryoshu", 2) |> BattlePlans.put_profile("faust", 1)
      assert BattlePlans.profiles(data) == %{"ryoshu" => [2], "faust" => [1]}
      assert BattlePlans.profile_ids_used(data) == MapSet.new([1, 2])

      data = BattlePlans.put_profile(data, "faust", [1, 3, 1])
      assert BattlePlans.profiles(data)["faust"] == [1, 3]

      data = BattlePlans.put_profile(data, "ryoshu", [])
      assert BattlePlans.profiles(data) == %{"faust" => [1, 3]}

      assert BattlePlans.profiles(%{"profiles" => %{"faust" => 4}}) == %{"faust" => [4]}
    end
  end

  describe "put_row/3" do
    test "top and bottom drop any priority" do
      holder = %{"row" => "priority", "priority" => %{"order" => ["s3"]}}
      assert BattlePlans.put_row(holder, "top", nil) == %{"row" => "top"}
      assert BattlePlans.put_row(holder, "junk", nil) == %{"row" => "bottom"}
    end

    test "switching to priority starts from s3 > s2 > s1" do
      assert BattlePlans.put_row(%{"row" => "bottom"}, "priority", ["wrath"])["priority"] == %{"order" => ["s3", "s2", "s1"]}
    end

    test "keeps a mixed order of tiers, sins, and dodge, dropping blanks, unknowns, and repeats" do
      holder = %{"row" => "priority", "priority" => %{"order" => []}}
      result = BattlePlans.put_row(holder, "priority", ["s3", "", "wrath", "bogus", "dodge", "s3", "s2"])
      assert result["priority"] == %{"order" => ["s3", "wrath", "dodge", "s2"]}
    end
  end

  describe "pick_row/4 in use" do
    defp in_use_order(order), do: %{"row" => "priority", "priority" => %{"order" => order}}

    test "the in use chip resolves to the row currently chosen" do
      assert BattlePlans.pick_row(in_use_order(["in_use"]), cell(:wrath, :skill1), cell(:envy, :skill2), :top) == :top
      assert BattlePlans.pick_row(in_use_order(["s3", "in_use"]), cell(:wrath, :skill1), cell(:envy, :skill2), :bottom) == :bottom
    end

    test "it falls through to later chips when the row in use is unknown" do
      assert BattlePlans.pick_row(in_use_order(["in_use", "top"]), cell(:wrath, :skill1), cell(:envy, :skill2), nil) == :top
    end
  end

  describe "put_run_mode/2" do
    test "stores the mode and a defense cap only for a-res+def" do
      holder = BattlePlans.new_rest()

      assert %{"mode" => "a_res_def", "max_defenses" => 2} = BattlePlans.put_run_mode(holder, %{"mode" => "a_res_def", "max_defenses" => "2"})
      refute Map.has_key?(BattlePlans.put_run_mode(holder, %{"mode" => "a_res", "max_defenses" => "2"}), "max_defenses")
      refute Map.has_key?(BattlePlans.put_run_mode(Map.put(holder, "mode", "a_res"), %{"mode" => "none"}), "mode")
    end

    test "a blank cap means no limit and switching to a fixed row drops the mode" do
      holder = BattlePlans.new_rest() |> Map.put("mode", "a_res_def") |> Map.put("max_defenses", 2)

      refute Map.has_key?(BattlePlans.put_run_mode(holder, %{"mode" => "a_res_def", "max_defenses" => ""}), "max_defenses")
      refute Map.has_key?(BattlePlans.put_row(holder, "top", nil), "mode")
    end
  end

  describe "pick_row/3" do
    defp cell(sin, tier), do: %{sin: sin, tier: tier}
    defp priority(order), do: %{"row" => "priority", "priority" => %{"order" => order}}

    test "fixed rows ignore the cells" do
      assert BattlePlans.pick_row(%{"row" => "top"}, cell(:envy, :skill1), cell(:wrath, :skill3)) == :top
      assert BattlePlans.pick_row(%{"row" => "bottom"}, cell(:wrath, :skill3), cell(:envy, :skill1)) == :bottom
    end

    test "walks the list and takes the first entry either skill matches" do
      order = priority(["s3", "wrath", "s2"])
      assert BattlePlans.pick_row(order, cell(:envy, :skill3), cell(:wrath, :skill1)) == :top
      assert BattlePlans.pick_row(order, cell(:envy, :skill2), cell(:wrath, :skill1)) == :bottom
      assert BattlePlans.pick_row(order, cell(:wrath, :skill2), cell(:envy, :skill1)) == :top
    end

    test "dodge is taken as soon as the walk reaches it" do
      order = priority(["s3", "dodge", "s2", "s1"])
      assert BattlePlans.pick_row(order, cell(:wrath, :skill3), cell(:wrath, :skill1)) == :top
      assert BattlePlans.pick_row(order, cell(:wrath, :skill2), cell(:wrath, :skill1)) == :dodge
      assert BattlePlans.pick_row(priority(["dodge", "s3"]), cell(:wrath, :skill3), cell(:wrath, :skill3)) == :dodge
    end

    test "a fused tier and sin only matches a cell that is both" do
      order = priority(["s3+envy", "s2"])
      assert BattlePlans.pick_row(order, cell(:envy, :skill3), cell(:wrath, :skill2)) == :top
      assert BattlePlans.pick_row(order, cell(:wrath, :skill3), cell(:envy, :skill2)) == :bottom
      assert BattlePlans.pick_row(order, cell(:wrath, :skill1), cell(:envy, :skill3)) == :bottom
      assert BattlePlans.pick_row(order, cell(:envy, :skill1), cell(:wrath, :skill1)) == :bottom
    end

    test "put_row keeps valid fused terms and drops malformed ones" do
      holder = %{"row" => "priority", "priority" => %{"order" => []}}
      result = BattlePlans.put_row(holder, "priority", ["s3+envy", "envy+s3", "s3+bogus", "s3+envy+wrath", "dodge+envy", "s3+envy"])
      assert result["priority"] == %{"order" => ["s3+envy"]}
    end

    test "both rows matching or nothing matching picks bottom" do
      assert BattlePlans.pick_row(priority(["pride"]), cell(:pride, :skill1), cell(:pride, :skill3)) == :bottom
      assert BattlePlans.pick_row(priority(["wrath", "s3"]), cell(:gloom, :skill1), cell(:lust, :skill2)) == :bottom
      assert BattlePlans.pick_row(priority([]), cell(:gloom, :skill1), cell(:lust, :skill2)) == :bottom
    end
  end

  describe "slot ranges" do
    test "all keeps every slot" do
      assert BattlePlans.pick_columns([2, 3, 4], %{"pick" => "all"}) == [2, 3, 4]
    end

    test "from first counts from the left and a bare first is slot 1" do
      assert BattlePlans.pick_columns([2, 3, 4], %{"pick" => "first"}) == [2]
      assert BattlePlans.pick_columns([2, 3, 4], %{"pick" => "first", "start" => 2, "end" => 3}) == [3, 4]
    end

    test "from last counts from the right and returns slots left to right" do
      assert BattlePlans.pick_columns([2, 3, 4], %{"pick" => "last"}) == [4]
      assert BattlePlans.pick_columns([2, 3, 4], %{"pick" => "last", "start" => 1, "end" => 2}) == [3, 4]
    end

    test "a range past the slot count takes what exists, and nothing when it starts past the end" do
      assert BattlePlans.pick_columns([2, 3], %{"pick" => "first", "start" => 2, "end" => 9}) == [3]
      assert BattlePlans.pick_columns([2, 3], %{"pick" => "first", "start" => 3, "end" => 4}) == []
    end

    test "parse_skill reads chips and gap toggles, merges duplicate positions, and falls back to the first slot" do
      assert BattlePlans.parse_skill(%{"pick" => "all"}) == %{"pick" => "all"}
      assert BattlePlans.parse_skill(%{"pick" => "first"}) == BattlePlans.first_slot()
      assert BattlePlans.parse_skill(%{"pick" => "last"}) == %{BattlePlans.first_slot() | "pick" => "last"}
      assert BattlePlans.parse_skill(%{"pick" => "exact"}) == BattlePlans.first_slot()

      params = %{
        "pick" => "first",
        "chip" => %{"1" => %{"at" => "3", "on" => "true"}, "0" => %{"at" => "0", "on" => "false"}, "2" => %{"at" => "0", "on" => "true"}},
        "gap_lead" => "false",
        "gap_mid" => %{"0" => "false"},
        "gap_trail" => "true"
      }

      assert BattlePlans.parse_skill(params) == %{
               "pick" => "first",
               "chips" => [%{"at" => 0, "on" => true}, %{"at" => 3, "on" => true}],
               "gaps" => %{"lead" => false, "mid" => [false], "trail" => true}
             }
    end

    test "gaps appear between chips that are two or more apart and each toggles its slots" do
      skill = %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 3, "on" => true}], "gaps" => %{"lead" => true, "mid" => [false], "trail" => false}}
      assert BattlePlans.pick_columns([10, 11, 12, 13, 14], skill) == [10, 13]
      assert BattlePlans.pick_columns([10, 11, 12, 13, 14], put_in(skill, ["gaps", "mid"], [true])) == [10, 11, 12, 13]
      assert BattlePlans.pick_columns([10, 11, 12, 13, 14], put_in(skill, ["gaps", "trail"], true)) == [10, 13, 14]

      adjacent = %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 1, "on" => true}], "gaps" => %{"lead" => true, "mid" => [], "trail" => false}}
      assert Enum.map(BattlePlans.skill_view(adjacent), &elem(&1, 0)) == [:chip, :chip, :gap]
    end

    test "an off chip is skipped, and a chip past the first leaves a leading gap" do
      skill = %{"pick" => "last", "chips" => [%{"at" => 1, "on" => true}, %{"at" => 2, "on" => false}], "gaps" => %{"lead" => true, "mid" => [], "trail" => false}}
      assert BattlePlans.pick_columns([2, 3, 4, 5], skill) == [4, 5]
      assert Enum.map(BattlePlans.skill_view(skill), &elem(&1, 0)) == [:gap, :chip, :chip, :gap]
    end

    test "add_skill_chip adds one position past the furthest chip and converts old ranges" do
      assert BattlePlans.add_skill_chip(BattlePlans.first_slot())["chips"] == [%{"at" => 0, "on" => true}, %{"at" => 1, "on" => true}]
      assert BattlePlans.add_skill_chip(%{"pick" => "last", "start" => 2, "end" => 3})["chips"] == Enum.map(1..3, &%{"at" => &1, "on" => true})
    end

    test "step_skill_chip moves one chip, stops at position 0 and merges chips that land together" do
      skill = %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 2, "on" => false}], "gaps" => %{"lead" => true, "mid" => [], "trail" => true}}
      assert Enum.map(BattlePlans.step_skill_chip(skill, 1, 1)["chips"], & &1["at"]) == [0, 3]
      assert Enum.map(BattlePlans.step_skill_chip(skill, 0, -1)["chips"], & &1["at"]) == [0, 2]
      assert BattlePlans.step_skill_chip(%{skill | "chips" => [%{"at" => 0, "on" => true}, %{"at" => 1, "on" => false}]}, 0, 1)["chips"] == [%{"at" => 1, "on" => true}]
    end

    test "skill_label spells the chips" do
      assert BattlePlans.skill_label(%{"pick" => "all"}) == "all"
      assert BattlePlans.skill_label(%{"pick" => "first"}) == "slots first"
      assert BattlePlans.skill_label(%{"pick" => "last", "start" => 2, "end" => 3}) == "slots last-1, last-2"
      assert BattlePlans.skill_label(BattlePlans.first_slot()) == "slots first, rest"
    end

    test "holder_parts marks sinners and affinities so the editor can draw icons" do
      holder = %{"type" => "target", "who" => "only", "sinners" => ["yi_sang"], "skill" => %{"pick" => "all"}, "row" => "priority", "priority" => %{"order" => ["s3+wrath", "s2"]}, "enemy" => %{"pick" => "none"}}
      parts = BattlePlans.holder_parts(holder)
      assert {:sinner, "yi_sang"} in parts
      assert {:term, "s3+wrath"} in parts
      assert BattlePlans.parts_text(parts, %{"yi_sang" => "Yi Sang"}) == "Yi Sang, all slots: pick s3+wrath > s2"
    end

    test "a lone first or last slot reads as a singular slot" do
      only_first = %{"type" => "target", "who" => "everyone", "sinners" => [], "skill" => %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}], "gaps" => %{"lead" => false, "mid" => [], "trail" => false}}, "row" => "top", "enemy" => %{"pick" => "none"}}
      assert BattlePlans.holder_label(only_first) == "everyone, first slot: pick top"
      assert {:slot, "last"} in BattlePlans.holder_parts(put_in(only_first, ["skill", "pick"], "last"))
    end

    test "holder_label reads a row as plain english" do
      target = BattlePlans.new_action("target")
      assert BattlePlans.holder_label(target) == "everyone, all slots: pick s3 > s2 > s1, target last-1, then left"

      ego = %{"type" => "ego", "who" => "except", "sinners" => ["yi_sang"], "skill" => BattlePlans.first_slot(), "grade" => "he", "corrode" => true, "enemy" => %{"pick" => "none"}}
      assert BattlePlans.holder_label(ego, %{"yi_sang" => "Yi Sang"}) == "all but Yi Sang, slots first rest: EGO HE corrode"

      assert BattlePlans.rows_label(Map.put(BattlePlans.new_pin(), "rest", BattlePlans.new_rest()), %{}, false) ==
               ["everyone, all slots: pick s3 > s2 > s1", "remaining skills: everyone, all slots: pick s3 > s2 > s1"]

      with_rest = Map.put(target, "rest", BattlePlans.new_rest())
      assert BattlePlans.rows_label(with_rest) == [BattlePlans.holder_label(target), "remaining skills: everyone, all slots: pick s3 > s2 > s1, keep targeting"]
    end
  end

  describe "put_rest/2" do
    test "automating creates a rest rule with its own selector, keeping an existing one" do
      assert %{"rest" => %{"type" => "target", "row" => "priority", "who" => "everyone", "skill" => %{"pick" => "all"}}} = BattlePlans.put_rest(%{"type" => "target"}, "true")
      assert BattlePlans.put_rest(%{"rest" => %{"type" => "ego"}}, "true")["rest"] == %{"type" => "ego"}
    end

    test "turning it off drops the rest rule and nil leaves it alone" do
      refute Map.has_key?(BattlePlans.put_rest(%{"rest" => %{"type" => "ego"}}, "false"), "rest")
      assert BattlePlans.put_rest(%{"rest" => %{"type" => "ego"}}, nil)["rest"] == %{"type" => "ego"}
    end
  end

  describe "tray_count leaves" do
    test "condition_leaf fills defaults and labels the count" do
      leaf = BattlePlans.condition_leaf(%{"op" => "tray_count", "hook" => "battle_chain"})
      assert leaf == %{"op" => "tray_count", "sinners" => [], "matches" => [], "cmp" => "gte", "value" => 1}
      assert leaf == BattlePlans.default_leaf()
      assert BattlePlans.tray_leaf?(leaf)
      refute BattlePlans.sinner_leaf?(leaf)
      assert BattlePlans.condition_label(%{"op" => "and", "children" => [leaf]}) == "any slots >= 1"

      leaf = BattlePlans.condition_leaf(%{"op" => "tray_count", "matches" => ["s3", "wrath", "s3+wrath", "bogus", "s3"], "cmp" => "eq", "value" => "0", "sinners_csv" => "ryoshu,nobody,ryoshu"})
      assert leaf == %{"op" => "tray_count", "sinners" => ["ryoshu"], "matches" => ["s3", "wrath", "s3+wrath"], "cmp" => "eq", "value" => 0}
      assert BattlePlans.condition_label(leaf) == "Ryoshu s3/wrath/s3+wrath slots = 0"
      assert BattlePlans.condition_label(%{leaf | "sinners" => ["hong_lu", "ryoshu"]}) == "Hong Lu/Ryoshu s3/wrath/s3+wrath slots = 0"
      assert BattlePlans.condition_leaf(%{"op" => "tray_count", "sinners_csv" => "nobody"})["sinners"] == []
    end

    test "counts slots where either row matches, scoped to columns" do
      classified = {[cell(:wrath, :skill1), cell(:envy, :skill3), cell(:wrath, :skill2)], [cell(:wrath, :skill2), cell(:wrath, :skill1), cell(:pride, :skill1)]}
      leaf = %{"matches" => ["wrath"]}
      assert BattlePlans.tray_count(leaf, classified, :all) == 3
      assert BattlePlans.tray_count(leaf, classified, [1, 2]) == 2
      assert BattlePlans.tray_count(%{"matches" => ["s3"]}, classified, [0, 2]) == 0
      assert BattlePlans.tray_count(%{"matches" => ["pride", "envy"]}, classified, :all) == 2
      assert BattlePlans.tray_count(%{"matches" => ["s3+envy", "pride"]}, classified, :all) == 2
      assert BattlePlans.tray_count(%{"matches" => []}, classified, :all) == 3
      assert BattlePlans.tray_count(%{"matches" => ["top"]}, {[cell(:wrath, :skill1), nil], [nil, cell(:envy, :skill2)]}, :all) == 1
      assert BattlePlans.tray_count(%{"matches" => ["bottom"]}, {[cell(:wrath, :skill1), nil], [nil, cell(:envy, :skill2)]}, :all) == 1
      assert BattlePlans.tray_count(%{"matches" => ["top", "bottom"]}, {[cell(:wrath, :skill1), nil], [nil, cell(:envy, :skill2)]}, :all) == 2
      assert BattlePlans.condition_leaf(%{"op" => "tray_count", "matches" => ["top", "bottom", "dodge"]})["matches"] == ["top", "bottom"]
      assert BattlePlans.tray_count(%{"matches" => []}, {[cell(:wrath, :skill1), nil], [nil, nil]}, :all) == 1
    end

    test "chosen_columns combines row and used-skill conditions with and/or" do
      classified = {[cell(:envy, :skill1), cell(:wrath, :skill2), cell(:pride, :skill1), cell(:envy, :skill3), cell(:lust, :skill1)], [cell(:wrath, :skill1), cell(:envy, :skill1), cell(:envy, :skill2), cell(:pride, :skill1), cell(:wrath, :skill3)]}
      filter = fn join, conditions -> %{"join" => join, "conditions" => conditions} end
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "bottom"}]), [1, 3], 5, classified) == [1, 3]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "top"}]), [1, 3], 5, classified) == [0, 2, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "using", "values" => ["envy", "lust"]}]), [1, 3], 5, classified) == [0, 1, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "not_using", "values" => ["envy"]}]), [1, 3], 5, classified) == [2, 3, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "top"}, %{"kind" => "not_using", "values" => ["envy"]}]), [1, 3], 5, classified) == [2, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "bottom_is", "values" => ["wrath"]}]), [], 5, classified) == [0, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "bottom_is_not", "values" => ["wrath", "envy"]}]), [], 5, classified) == [3]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "top_is", "values" => ["envy", "s1"]}]), [], 5, classified) == [0, 2, 3, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "top_is_not", "values" => ["envy"]}]), [], 5, classified) == [1, 2, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "has", "values" => ["lust"]}]), [], 5, classified) == [4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "has", "not" => true, "values" => ["pride"]}]), [], 5, classified) == [0, 1, 4]
      assert BattlePlans.parse_chosen_filter(%{"where_c" => %{"0" => %{"kind" => "top_is", "not" => "true", "values" => ["envy"]}, "1" => %{"kind" => "has", "not" => "false", "values" => ["envy"]}}})["conditions"] ==
               [%{"kind" => "top_is", "not" => true, "values" => ["envy"]}, %{"kind" => "has", "values" => ["envy"]}]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "has_no", "values" => ["pride"]}]), [], 5, classified) == [0, 1, 4]
      assert BattlePlans.chosen_columns(filter.("and", [%{"kind" => "has_no", "values" => ["envy", "wrath"]}]), [], 5, classified) == []
      assert BattlePlans.chosen_columns(filter.("or", [%{"kind" => "bottom"}, %{"kind" => "using", "values" => ["lust"]}]), [1, 3], 5, classified) == [1, 3, 4]
    end

    test "parse_chosen_filter reads indexed conditions and drops unknown chips" do
      params = %{"where_join" => "or", "where_c" => %{"1" => %{"kind" => "bottom"}, "0" => %{"kind" => "not_using", "values" => ["envy", "bogus", "envy", "s3"]}}}
      assert BattlePlans.parse_chosen_filter(params) == %{"join" => "or", "conditions" => [%{"kind" => "using", "not" => true, "values" => ["envy", "s3"]}, %{"kind" => "using", "values" => ["bottom"]}]}
      assert BattlePlans.parse_chosen_filter(%{}) == BattlePlans.new_chosen_filter()
      fused = %{"where_c" => %{"0" => %{"kind" => "bottom_is", "values" => ["s3+envy", "envy+s3", "dodge", "wrath"]}}}
      assert BattlePlans.parse_chosen_filter(fused)["conditions"] == [%{"kind" => "bottom_is", "values" => ["s3+envy", "wrath"]}]
    end

    test "compares the count" do
      assert BattlePlans.tray_count_matches?(%{"cmp" => "gte", "value" => 2}, 2)
      refute BattlePlans.tray_count_matches?(%{"cmp" => "eq", "value" => 1}, 2)
      assert BattlePlans.tray_count_matches?(%{"cmp" => "lte", "value" => 1}, 0)
    end
  end

  describe "sinner_position leaves" do
    test "condition_leaf fills defaults and labels the position" do
      leaf = BattlePlans.condition_leaf(%{"op" => "sinner_position"})
      assert leaf == %{"op" => "sinner_position", "sinners" => [], "position" => BattlePlans.first_slot()}
      assert BattlePlans.position_leaf?(leaf)
      refute BattlePlans.tray_leaf?(leaf)
      refute BattlePlans.sinner_leaf?(leaf)
      assert BattlePlans.condition_label(leaf) == "(pick a sinner) at position first, rest"

      leaf = BattlePlans.condition_leaf(%{"op" => "sinner_position", "sinners_csv" => "faust,nobody,ryoshu", "pick" => "last", "chip" => %{"0" => %{"at" => "0", "on" => "true"}, "1" => %{"at" => "2", "on" => "true"}}, "gap_lead" => "false", "gap_mid" => %{"0" => "false"}, "gap_trail" => "false", "not" => "true"})

      assert leaf == %{
               "op" => "sinner_position",
               "sinners" => ["faust", "ryoshu"],
               "position" => %{"pick" => "last", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 2, "on" => true}], "gaps" => %{"lead" => false, "mid" => [false], "trail" => false}},
               "not" => true
             }

      assert BattlePlans.condition_label(leaf, %{"faust" => "Saikai"}) == "not Saikai/Ryoshu at position last, last-2"
    end

    test "every selected sinner has to land in the defined positions" do
      first = %{"position" => BattlePlans.first_slot() |> Map.put("gaps", %{"lead" => false, "mid" => [], "trail" => false})}
      last = %{"position" => %{"pick" => "last", "chips" => [%{"at" => 0, "on" => true}], "gaps" => %{"lead" => false, "mid" => [], "trail" => false}}}
      first_two = %{"position" => %{"pick" => "first", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 1, "on" => true}], "gaps" => %{"lead" => false, "mid" => [], "trail" => false}}}
      after_first = %{"position" => %{"pick" => "first", "chips" => [%{"at" => 0, "on" => false}], "gaps" => %{"lead" => false, "mid" => [], "trail" => true}}}

      assert BattlePlans.position_matches?(first, [0], 5)
      refute BattlePlans.position_matches?(first, [1], 5)
      assert BattlePlans.position_matches?(last, [4], 5)
      refute BattlePlans.position_matches?(last, [3], 5)
      assert BattlePlans.position_matches?(first_two, [0, 1], 5)
      refute BattlePlans.position_matches?(first_two, [1, 2], 5)
      assert BattlePlans.position_matches?(after_first, [1, 4], 5)
      refute BattlePlans.position_matches?(after_first, [0, 4], 5)
    end
  end

  describe "target_index/2" do
    defp enemy(pick, offset, step \\ nil, index \\ 0), do: %{"pick" => pick, "offset" => offset, "step" => step, "index" => index}

    test "counts the starting offset from either end" do
      assert BattlePlans.target_index(6, enemy("first", 0)) == 0
      assert BattlePlans.target_index(6, enemy("first", 2)) == 2
      assert BattlePlans.target_index(6, enemy("last", 0)) == 5
      assert BattlePlans.target_index(6, enemy("last", 1)) == 4
      assert BattlePlans.target_index(5, enemy("last", 0)) == 4
    end

    test "a start past the far end lands on the far end" do
      assert BattlePlans.target_index(4, enemy("first", 9)) == 3
      assert BattlePlans.target_index(4, enemy("last", 9)) == 0
    end

    test "each next sinner slot steps one target and then piles onto the end" do
      indexes = fn pick, n, step -> for i <- 0..5, do: BattlePlans.target_index(5, enemy(pick, n, step, i)) end
      assert indexes.("first", 0, "right") == [0, 1, 2, 3, 4, 4]
      assert indexes.("first", 2, "right") == [2, 3, 4, 4, 4, 4]
      assert indexes.("first", 4, "left") == [4, 3, 2, 1, 0, 0]
      assert indexes.("last", 0, "left") == [4, 3, 2, 1, 0, 0]
      assert indexes.("first", 1, nil) == [1, 1, 1, 1, 1, 1]
      assert indexes.("first", 99, "left") == [4, 3, 2, 1, 0, 0]
    end

    test "saved exact, up_to and percent picks read as from first" do
      assert BattlePlans.target_index(5, %{"pick" => "exact", "offset" => 2}) == 2
      assert BattlePlans.target_index(5, %{"pick" => "up_to", "offset" => 8}) == 4
      assert BattlePlans.target_index(5, %{"pick" => "percent", "offset" => 80}) == 0
    end

    test "labels and parsing" do
      assert BattlePlans.enemy_label(%{"pick" => "last", "offset" => 1, "step" => "left", "ignore" => [%{"side" => "top", "n" => 1}]}) == "last-1, then left, ignoring top 1"
      assert BattlePlans.enemy_label(%{"pick" => "none"}) == "none"
      assert BattlePlans.parse_enemy("last", "0", "up") == %{"pick" => "last", "offset" => 0, "step" => "left"}
      assert BattlePlans.parse_enemy("first", "4", "right") == %{"pick" => "first", "offset" => 4, "step" => "right"}
      assert BattlePlans.parse_enemy("exact", "2", nil) == %{"pick" => "first", "offset" => 2, "step" => "right"}
      assert BattlePlans.parse_enemy("none", "2", "left") == %{"pick" => "none"}
    end
  end

  describe "apply_ignores/2" do
    defp at(x, y), do: %{icon: {x, y}, point: {x, y + 100}}
    defp ignore(side, n), do: %{"side" => side, "n" => n}

    setup do
      %{targets: [at(100, 300), at(200, 150), at(300, 400), at(400, 200)]}
    end

    test "cuts slots from one side, keeping left to right order", %{targets: targets} do
      assert BattlePlans.apply_ignores(targets, [ignore("left", 1)]) == [at(200, 150), at(300, 400), at(400, 200)]
      assert BattlePlans.apply_ignores(targets, [ignore("right", 2)]) == [at(100, 300), at(200, 150)]
      assert BattlePlans.apply_ignores(targets, [ignore("top", 2)]) == [at(100, 300), at(300, 400)]
      assert BattlePlans.apply_ignores(targets, [ignore("bottom", 1)]) == [at(100, 300), at(200, 150), at(400, 200)]
    end

    test "ignores apply in order to what is left", %{targets: targets} do
      assert BattlePlans.apply_ignores(targets, [ignore("left", 1), ignore("top", 1)]) == [at(300, 400), at(400, 200)]
    end

    test "an ignore that would cut everything leaves the target furthest from that side", %{targets: targets} do
      assert BattlePlans.apply_ignores(targets, [ignore("left", 99)]) == [at(400, 200)]
      assert BattlePlans.apply_ignores(targets, [ignore("top", 99)]) == [at(300, 400)]
    end

    test "later ignores can never remove the last target", %{targets: targets} do
      assert BattlePlans.apply_ignores(targets, [ignore("left", 99), ignore("right", 5), ignore("top", 1)]) == [at(400, 200)]
    end

    test "passes through without ignores and handles no targets", %{targets: targets} do
      assert BattlePlans.apply_ignores(targets, nil) == targets
      assert BattlePlans.apply_ignores(targets, []) == targets
      assert BattlePlans.apply_ignores([], [ignore("left", 1)]) == []
      assert BattlePlans.ignore_label([ignore("left", 3), ignore("top", 2)]) == ", ignoring left 3, top 2"
    end
  end

  describe "put_ignores/3" do
    test "reads indexed entries in order, clamps n, drops junk, and appends an added side" do
      entries = %{"1" => %{"side" => "top", "n" => "500"}, "0" => %{"side" => "left", "n" => "3"}, "2" => %{"side" => "diagonal", "n" => "1"}}
      assert BattlePlans.put_ignores(%{"pick" => "first"}, entries, "right")["ignore"] == [ignore("left", 3), ignore("top", 99), ignore("right", 1)]
    end

    test "no entries removes the key, and remove_ignore drops by index" do
      assert BattlePlans.put_ignores(%{"pick" => "first", "ignore" => [ignore("left", 1)]}, nil, "") == %{"pick" => "first"}
      enemy = %{"pick" => "first", "ignore" => [ignore("left", 1), ignore("top", 2)]}
      assert BattlePlans.remove_ignore(enemy, 0)["ignore"] == [ignore("top", 2)]
      assert BattlePlans.remove_ignore(BattlePlans.remove_ignore(enemy, 0), 0) == %{"pick" => "first"}
    end
  end
end
