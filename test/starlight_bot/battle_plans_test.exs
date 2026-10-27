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
      [first | _] = playbook["actions"]
      %{playbook | "actions" => BattlePlans.wrap_in_schedule(playbook["actions"], first["id"])}
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
      [schedule, chain] = playbook["actions"] ++ [BattlePlans.new_action("chain_a_res")]
      container = schedule["id"] <> "|1"
      items = playbook["actions"] ++ [chain]

      assert BattlePlans.move_to_container(items, "root", container, schedule["id"], [schedule["id"]]) == items
      assert BattlePlans.move_to_container(items, "root", container, chain["id"], [chain["id"]]) == items
    end
  end

  describe "if blocks" do
    test "sinner count leaves parse, label and match" do
      leaf = BattlePlans.condition_leaf(%{"op" => "sinners_lte", "value" => "2", "hook" => "ignored"})
      assert leaf == %{"op" => "sinners_lte", "value" => 2}
      assert BattlePlans.condition_leaf(%{"op" => "sinners_eq", "value" => "0"})["value"] == 1
      assert BattlePlans.condition_label(Conditions.add(nil, "", leaf)) == "sinners <= 2"
      assert BattlePlans.sinner_count_matches?(leaf, 1)
      refute BattlePlans.sinner_count_matches?(leaf, 3)
      assert BattlePlans.condition_leaf(%{"op" => "hook_off", "hook" => " battle_turn "}) == %{"op" => "hook_off", "hook" => "battle_turn"}
    end

    test "a block is terminal only when a branch holds a chain action" do
      block = BattlePlans.new_action("if")
      refute BattlePlans.terminal?(block)
      assert BattlePlans.terminal?(Map.put(block, "else", [BattlePlans.new_action("chain_fast")]))
    end
  end

  describe "boss fight conditions" do
    test "builds and labels both leaves" do
      assert BattlePlans.condition_leaf(%{"op" => "boss_fight", "hook" => "stale"}) == %{"op" => "boss_fight"}
      assert BattlePlans.condition_label(%{"op" => "boss_fight"}) == "boss fight"
      assert BattlePlans.condition_label(%{"op" => "not_boss_fight"}) == "not a boss fight"
      assert BattlePlans.fight_leaf?(%{"op" => "not_boss_fight"})
      refute BattlePlans.fight_leaf?(%{"op" => "hook_on"})
    end
  end

  describe "profiles/1" do
    test "assigns and clears a sinner's profile, and lists the ids in use" do
      data = BattlePlans.blank()
      assert BattlePlans.profiles(data) == %{}

      data = data |> BattlePlans.put_profile("ryoshu", 2) |> BattlePlans.put_profile("faust", 1)
      assert BattlePlans.profiles(data) == %{"ryoshu" => 2, "faust" => 1}
      assert BattlePlans.profile_ids_used(data) == MapSet.new([1, 2])

      data = BattlePlans.put_profile(data, "ryoshu", nil)
      assert BattlePlans.profiles(data) == %{"faust" => 1}
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

    test "both rows matching or nothing matching picks bottom" do
      assert BattlePlans.pick_row(priority(["pride"]), cell(:pride, :skill1), cell(:pride, :skill3)) == :bottom
      assert BattlePlans.pick_row(priority(["wrath", "s3"]), cell(:gloom, :skill1), cell(:lust, :skill2)) == :bottom
      assert BattlePlans.pick_row(priority([]), cell(:gloom, :skill1), cell(:lust, :skill2)) == :bottom
    end
  end

  describe "assign_slots/3" do
    defp cells_of(cells), do: fn column -> Enum.at(cells, column) end

    defp saikai_cells do
      [
        {cell(:pride, :skill1), cell(:gloom, :skill2)},
        {cell(:envy, :skill1), cell(:wrath, :skill1)},
        {cell(:lust, :skill1), cell(:sloth, :skill3)},
        {cell(:pride, :skill2), cell(:envy, :skill1)},
        {cell(:gloom, :skill1), cell(:lust, :skill1)}
      ]
    end

    defp rest(extra \\ %{}), do: Map.merge(%{"type" => "dodge"}, extra)

    test "an uncapped rule takes every slot" do
      holder = %{"type" => "target", "row" => "top"}
      assert BattlePlans.assign_slots(holder, [0, 1, 2], nil) == [{holder, [0, 1, 2]}]
    end

    test "a cap takes the leftmost slots and the rest rule gets what is left" do
      holder = %{"type" => "target", "row" => "top", "cap" => 2, "rest" => rest()}
      assert [{^holder, [0, 1]}, {%{"type" => "dodge"}, [2, 3, 4]}] = BattlePlans.assign_slots(holder, [0, 1, 2, 3, 4], nil)
    end

    test "a priority cap takes the best ranked slots, leftmost first on ties" do
      holder = %{"type" => "target", "row" => "priority", "priority" => %{"order" => ["wrath", "s3", "s2"]}, "cap" => 3, "rest" => rest()}
      assert [{^holder, [0, 1, 2]}, {%{"type" => "dodge"}, [3, 4]}] = BattlePlans.assign_slots(holder, [0, 1, 2, 3, 4], cells_of(saikai_cells()))
    end

    test "rest rules chain their own caps" do
      third = rest(%{"type" => "ego"})
      second = %{"type" => "target", "row" => "bottom", "cap" => 1, "rest" => third}
      first = %{"type" => "target", "row" => "top", "cap" => 2, "rest" => second}
      assert [{^first, [0, 1]}, {^second, [2]}, {^third, [3, 4]}] = BattlePlans.assign_slots(first, [0, 1, 2, 3, 4], nil)
    end

    test "a cap past the slot count leaves nothing for the rest rule" do
      holder = %{"type" => "target", "row" => "top", "cap" => 9, "rest" => rest()}
      assert [{^holder, [0, 1]}] = BattlePlans.assign_slots(holder, [0, 1], nil)
    end
  end

  describe "reorder_playbooks/3" do
    test "reorders one kind in place and leaves the other kind's slots alone" do
      pbs = [%{"id" => "a", "kind" => "chain"}, %{"id" => "x", "kind" => "focused"}, %{"id" => "b", "kind" => "chain"}, %{"id" => "c", "kind" => "chain"}]
      assert pbs |> BattlePlans.reorder_playbooks("chain", ["c", "a", "b"]) |> Enum.map(& &1["id"]) == ["c", "x", "a", "b"]
    end

    test "ignores an incomplete or foreign id list" do
      pbs = [%{"id" => "a", "kind" => "chain"}, %{"id" => "b", "kind" => "chain"}, %{"id" => "x", "kind" => "focused"}]
      assert BattlePlans.reorder_playbooks(pbs, "chain", ["b"]) == pbs
      assert BattlePlans.reorder_playbooks(pbs, "chain", ["b", "x"]) == pbs
    end
  end

  describe "put_cap/2" do
    test "parses 1 to 99, clamps, and creates the rest rule" do
      assert %{"cap" => 3, "rest" => %{"type" => "target", "row" => "priority"}} = BattlePlans.put_cap(%{"type" => "target"}, "3")
      assert BattlePlans.put_cap(%{}, "250")["cap"] == 99
    end

    test "keeps an existing rest rule" do
      holder = %{"cap" => 2, "rest" => %{"type" => "ego"}}
      assert BattlePlans.put_cap(holder, "4")["rest"] == %{"type" => "ego"}
    end

    test "blank, zero, or junk removes the cap and its rest rules" do
      holder = %{"type" => "target", "cap" => 2, "rest" => %{"type" => "ego"}}
      for value <- ["", "0", "x", nil], do: assert(BattlePlans.put_cap(holder, value) == %{"type" => "target"})
    end

    test "row_label no longer mentions limits" do
      assert BattlePlans.row_label(%{"row" => "priority", "priority" => %{"order" => ["wrath"]}}) == "priority wrath"
    end
  end

  describe "tray_count leaves" do
    test "condition_leaf fills defaults and labels the count" do
      leaf = BattlePlans.condition_leaf(%{"op" => "tray_count", "hook" => "battle_chain"})
      assert leaf == %{"op" => "tray_count", "match" => "wrath", "cmp" => "gte", "value" => 1, "sinner" => nil}
      assert BattlePlans.tray_leaf?(leaf)
      refute BattlePlans.sinner_leaf?(leaf)
      assert BattlePlans.condition_label(%{"op" => "and", "children" => [leaf]}) == "wrath slots >= 1"

      leaf = BattlePlans.condition_leaf(%{"op" => "tray_count", "match" => "s3", "cmp" => "eq", "value" => "0", "sinner" => "ryoshu"})
      assert leaf == %{"op" => "tray_count", "match" => "s3", "cmp" => "eq", "value" => 0, "sinner" => "ryoshu"}
      assert BattlePlans.condition_label(leaf) == "Ryoshu s3 slots = 0"
      assert BattlePlans.condition_label(%{leaf | "sinner" => "hong_lu"}) == "Hong Lu s3 slots = 0"
      assert BattlePlans.condition_leaf(%{"op" => "tray_count", "sinner" => "nobody"})["sinner"] == nil
    end

    test "counts slots where either row matches, scoped to columns" do
      classified = {[cell(:wrath, :skill1), cell(:envy, :skill3), cell(:wrath, :skill2)], [cell(:wrath, :skill2), cell(:wrath, :skill1), cell(:pride, :skill1)]}
      leaf = %{"match" => "wrath"}
      assert BattlePlans.tray_count(leaf, classified, :all) == 3
      assert BattlePlans.tray_count(leaf, classified, [1, 2]) == 2
      assert BattlePlans.tray_count(%{"match" => "s3"}, classified, [0, 2]) == 0
    end

    test "first_with takes up to n owned slots with a match in either row, left to right" do
      classified = {[cell(:envy, :skill1), cell(:wrath, :skill2), cell(:pride, :skill1)], [cell(:pride, :skill3), cell(:gloom, :skill1), cell(:wrath, :skill1)]}
      assert BattlePlans.first_with([0, 1, 2], "wrath", 1, classified) == [1]
      assert BattlePlans.first_with([0, 1, 2], "wrath", 3, classified) == [1, 2]
      assert BattlePlans.first_with([2], "wrath", 3, classified) == [2]
      assert BattlePlans.first_with([0, 1], "s3", 1, classified) == [0]
      assert BattlePlans.first_with([0, 1, 2], "lust", 2, classified) == []
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
      assert leaf == %{"op" => "sinner_position", "sinner" => nil, "cmp" => "is", "pos" => "first", "value" => 1}
      assert BattlePlans.position_leaf?(leaf)
      refute BattlePlans.tray_leaf?(leaf)
      refute BattlePlans.sinner_leaf?(leaf)
      assert BattlePlans.condition_label(leaf) == "(no sinner) is first"

      leaf = BattlePlans.condition_leaf(%{"op" => "sinner_position", "sinner" => "faust", "cmp" => "is_not", "pos" => "exact", "value" => "3"})
      assert leaf == %{"op" => "sinner_position", "sinner" => "faust", "cmp" => "is_not", "pos" => "exact", "value" => 3}
      assert BattlePlans.condition_label(leaf) == "Faust is not at position 3"
      assert BattlePlans.condition_label(leaf, %{"faust" => "Saikai"}) == "Saikai is not at position 3"
      assert BattlePlans.condition_label(%{leaf | "pos" => "last"}, %{"faust" => "Saikai"}) == "Saikai is not last"
      assert BattlePlans.condition_label(%{leaf | "cmp" => "gt"}, %{"faust" => "Saikai"}) == "Saikai is after position 3"
      assert BattlePlans.condition_label(%{leaf | "cmp" => "lt", "pos" => "last"}, %{"faust" => "Saikai"}) == "Saikai is before last"
    end

    test "matches first, last and exact positions, negated with is not" do
      first = %{"pos" => "first", "value" => 1, "cmp" => "is"}
      last = %{"pos" => "last", "value" => 1, "cmp" => "is"}
      third = %{"pos" => "exact", "value" => 3, "cmp" => "is"}

      assert BattlePlans.position_matches?(first, 0, 5)
      refute BattlePlans.position_matches?(first, 1, 5)
      assert BattlePlans.position_matches?(last, 4, 5)
      refute BattlePlans.position_matches?(last, 3, 5)
      assert BattlePlans.position_matches?(third, 2, 5)
      refute BattlePlans.position_matches?(%{third | "cmp" => "is_not"}, 2, 5)
      assert BattlePlans.position_matches?(%{last | "cmp" => "is_not"}, 0, 5)
    end

    test "greater than and less than compare left to right tray order" do
      third = %{"pos" => "exact", "value" => 3}

      assert BattlePlans.position_matches?(Map.put(third, "cmp", "gt"), 3, 5)
      refute BattlePlans.position_matches?(Map.put(third, "cmp", "gt"), 2, 5)
      assert BattlePlans.position_matches?(Map.put(third, "cmp", "lt"), 1, 5)
      refute BattlePlans.position_matches?(Map.put(third, "cmp", "lt"), 2, 5)
      assert BattlePlans.position_matches?(%{"pos" => "last", "value" => 1, "cmp" => "lt"}, 3, 5)
      refute BattlePlans.position_matches?(%{"pos" => "first", "value" => 1, "cmp" => "lt"}, 0, 5)
    end
  end

  describe "target_index/2" do
    defp enemy(pick, n, step \\ nil, index \\ 0), do: %{"pick" => pick, "n" => n, "step" => step, "index" => index}

    test "counts the starting slot from either end" do
      assert BattlePlans.target_index(6, enemy("first", 1)) == 0
      assert BattlePlans.target_index(6, enemy("first", 3)) == 2
      assert BattlePlans.target_index(6, enemy("last", 1)) == 5
      assert BattlePlans.target_index(6, enemy("last", 2)) == 4
    end

    test "a start past the far end lands on the far end" do
      assert BattlePlans.target_index(4, enemy("first", 9)) == 3
      assert BattlePlans.target_index(4, enemy("last", 9)) == 0
    end

    test "each next sinner slot steps one target and then piles onto the end" do
      indexes = fn pick, n, step -> for i <- 0..5, do: BattlePlans.target_index(5, enemy(pick, n, step, i)) end
      assert indexes.("first", 1, "right") == [0, 1, 2, 3, 4, 4]
      assert indexes.("first", 3, "right") == [2, 3, 4, 4, 4, 4]
      assert indexes.("first", 5, "left") == [4, 3, 2, 1, 0, 0]
      assert indexes.("last", 1, "left") == [4, 3, 2, 1, 0, 0]
      assert indexes.("first", 2, nil) == [1, 1, 1, 1, 1, 1]
      assert indexes.("first", 99, "left") == [4, 3, 2, 1, 0, 0]
    end

    test "saved exact, up_to and percent picks read as from first" do
      assert BattlePlans.target_index(5, %{"pick" => "exact", "n" => 3}) == 2
      assert BattlePlans.target_index(5, %{"pick" => "up_to", "n" => 9}) == 4
      assert BattlePlans.target_index(5, %{"pick" => "percent", "n" => 80}) == 0
    end

    test "labels and parsing" do
      assert BattlePlans.enemy_label(%{"pick" => "last", "n" => 2, "step" => "left", "ignore" => [%{"side" => "top", "n" => 1}]}) == "2 from last, then left, ignoring top 1"
      assert BattlePlans.enemy_label(%{"pick" => "none"}) == "none"
      assert BattlePlans.parse_enemy("last", "0", "up") == %{"pick" => "last", "n" => 1}
      assert BattlePlans.parse_enemy("first", "4", "right") == %{"pick" => "first", "n" => 4, "step" => "right"}
      assert BattlePlans.parse_enemy("exact", "2", nil) == %{"pick" => "first", "n" => 2}
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
