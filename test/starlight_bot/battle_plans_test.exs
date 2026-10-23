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

  describe "split_phase/2" do
    test "copies the covering phase's actions into the new phase" do
      playbook = BattlePlans.new_playbook("focused", "Win rate")
      split = BattlePlans.split_phase(playbook, 5)

      assert Enum.map(split["phases"], & &1["from_turn"]) == [1, 5]
      [first, second] = split["phases"]
      assert Enum.map(first["actions"], & &1["type"]) == Enum.map(second["actions"], & &1["type"])
      refute Enum.map(first["actions"], & &1["id"]) == Enum.map(second["actions"], & &1["id"])
    end
  end

  describe "if blocks" do
    test "split_phase gives branch actions fresh ids" do
      block = BattlePlans.new_action("if") |> Map.put("then", [BattlePlans.new_action("clear")])
      playbook = BattlePlans.new_playbook("focused", "Win rate") |> put_in(["phases", Access.at(0), "actions"], [block])

      [first, second] = BattlePlans.split_phase(playbook, 3)["phases"]
      [old_block] = first["actions"]
      [new_block] = second["actions"]
      refute old_block["id"] == new_block["id"]
      refute hd(old_block["then"])["id"] == hd(new_block["then"])["id"]
    end

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

  describe "allocate_rows/2" do
    defp tray(cells), do: cells |> Enum.with_index() |> Enum.map(fn {{top, bottom}, column} -> {column, top, bottom} end)
    defp keep(order, min, max), do: %{"row" => "priority", "priority" => %{"order" => order, "min" => min, "max" => max}}

    defp saikai_tray do
      tray([
        {cell(:pride, :skill1), cell(:gloom, :skill2)},
        {cell(:envy, :skill1), cell(:wrath, :skill1)},
        {cell(:lust, :skill1), cell(:sloth, :skill3)},
        {cell(:pride, :skill2), cell(:envy, :skill1)},
        {cell(:gloom, :skill1), cell(:lust, :skill1)}
      ])
    end

    test "without limits it agrees with pick_row slot by slot" do
      assert BattlePlans.allocate_rows(priority(["wrath", "dodge", "s3"]), saikai_tray()) ==
               %{0 => :dodge, 1 => :bottom, 2 => :dodge, 3 => :dodge, 4 => :dodge}
    end

    test "max keeps the best ranked slots and dodges the rest, leftmost first on ties" do
      assert BattlePlans.allocate_rows(keep(["wrath", "s3", "s2", "s1"], nil, 3), saikai_tray()) ==
               %{0 => :bottom, 1 => :bottom, 2 => :bottom, 3 => :dodge, 4 => :dodge}
    end

    test "min pulls the best ranked slots back from dodge with their best row" do
      assert BattlePlans.allocate_rows(keep(["wrath", "dodge", "s2", "pride"], 3, nil), saikai_tray()) ==
               %{0 => :bottom, 1 => :bottom, 2 => :dodge, 3 => :top, 4 => :dodge}
    end

    test "min never dodges slots the list already keeps" do
      assert BattlePlans.allocate_rows(keep(["s1"], 1, nil), saikai_tray()) |> Map.values() |> Enum.count(&(&1 == :dodge)) == 0
    end
  end

  describe "put_keep/3" do
    test "parses limits, drops blanks, and caps min at max" do
      holder = BattlePlans.put_row(%{"row" => "bottom"}, "priority", nil)
      assert BattlePlans.put_keep(holder, "2", "")["priority"] == %{"order" => ["s3", "s2", "s1"], "min" => 2}
      assert BattlePlans.put_keep(holder, "5", "3")["priority"]["min"] == 3
      assert BattlePlans.put_keep(holder, "x", "-1")["priority"] == %{"order" => ["s3", "s2", "s1"]}
      assert BattlePlans.put_keep(%{"row" => "top"}, "1", "2") == %{"row" => "top"}
    end

    test "labels the limits" do
      assert BattlePlans.row_label(keep(["wrath"], 1, 4)) == "priority wrath, keep 1-4"
      assert BattlePlans.row_label(keep(["wrath"], nil, 4)) == "priority wrath, keep at most 4"
      assert BattlePlans.row_label(keep(["wrath"], 2, 2)) == "priority wrath, keep 2"
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

  describe "percent_index/2" do
    test "picks the enemy at that point left to right, rounded" do
      assert BattlePlans.percent_index(3, 50) == 1
      assert BattlePlans.percent_index(4, 50) == 2
      assert BattlePlans.percent_index(5, 0) == 0
      assert BattlePlans.percent_index(5, 100) == 4
      assert BattlePlans.percent_index(5, 30) == 1
      assert BattlePlans.percent_index(1, 50) == 0
    end
  end

  describe "filter_by_height/2" do
    defp at(x, y), do: %{icon: {x, y}, point: {x, y + 100}}

    test "keeps the highest or lowest share by icon height, rounded up, in left to right order" do
      targets = [at(100, 300), at(200, 150), at(300, 400), at(400, 200)]

      assert BattlePlans.filter_by_height(targets, %{"dir" => "high", "pct" => 25}) == [at(200, 150)]
      assert BattlePlans.filter_by_height(targets, %{"dir" => "high", "pct" => 30}) == [at(200, 150), at(400, 200)]
      assert BattlePlans.filter_by_height(targets, %{"dir" => "low", "pct" => 30}) == [at(100, 300), at(300, 400)]
    end

    test "always keeps at least one, and passes through without a filter" do
      targets = [at(100, 300), at(200, 150)]

      assert BattlePlans.filter_by_height(targets, %{"dir" => "high", "pct" => 1}) == [at(200, 150)]
      assert BattlePlans.filter_by_height(targets, nil) == targets
      assert BattlePlans.filter_by_height([], %{"dir" => "high", "pct" => 30}) == []
      assert BattlePlans.height_label(%{"dir" => "low", "pct" => 30}) == " among the lowest 30%"
    end
  end
end
