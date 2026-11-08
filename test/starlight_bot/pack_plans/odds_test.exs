defmodule StarlightBot.PackPlans.OddsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.PackPlans.Odds

  test "single look with one wanted pack is shown/pool" do
    odds = Odds.ranked(10, 3, 1, 0, 1)
    assert_in_delta hd(odds.wanted), 0.3, 1.0e-9
    assert_in_delta odds.any, 0.3, 1.0e-9
  end

  test "higher ranks absorb simultaneous appearances and ranks sum to any" do
    odds = Odds.ranked(20, 4, 3, 0, 3)
    assert_in_delta Enum.sum(odds.wanted), odds.any, 1.0e-9
    assert odds.wanted == Enum.sort(odds.wanted, :desc)
  end

  test "refreshes follow 1 - miss^looks" do
    miss = 1 - 3 / 10
    odds = Odds.ranked(10, 3, 1, 0, 3)
    assert_in_delta odds.any, 1 - miss * miss * miss, 1.0e-9
  end

  test "backups only count after every look misses" do
    odds = Odds.ranked(10, 3, 1, 2, 2)
    miss = 0.7
    assert Enum.sum(odds.backup) < :math.pow(miss, 2)
    assert Enum.sum(odds.backup) > 0
  end

  test "showing the whole pool is certain" do
    odds = Odds.ranked(3, 3, 1, 0, 1)
    assert_in_delta hd(odds.wanted), 1.0, 1.0e-9
  end

  test "percent formatting" do
    assert Odds.percent(1.0) == "100%"
    assert Odds.percent(0.0312) == "3.1%"
    assert Odds.percent(0.456) == "46%"
  end

  describe "for_run" do
    defp pack(id, floors), do: %{id: id, name_en: id, normal_floors: Jason.encode!(floors), hard_floors: "[]"}

    defp plan(statuses), do: %{"mode_schedule" => [], "search_floors" => [], "packs" => statuses}

    test "a pack hunted on two floors is split by the chance it was already taken" do
      packs = [pack("a", [1, 2]), pack("b", [1, 2]), pack("c", [1, 2]), pack("d", [1, 2])]
      statuses = %{"a" => %{"normal" => %{"1" => "hunt", "2" => "hunt"}}}
      odds = Odds.for_run(plan(statuses), packs, [{1, "normal"}, {2, "normal"}], [])

      first = hd(odds[1].rows)
      second = hd(odds[2].rows)
      assert_in_delta first.final, 1 - :math.pow(1 - 3 / 4, 2), 1.0e-9
      assert_in_delta second.available, 1 - first.final, 1.0e-9
      assert second.final < second.fresh
    end

    test "a floor with a taken favorite promotes the next pack and shrinks the pool" do
      packs = [pack("a", [1, 2]), pack("b", [2]), pack("c", [2]), pack("d", [2])]

      statuses = %{
        "a" => %{"normal" => %{"1" => "favorite", "2" => "favorite"}},
        "b" => %{"normal" => %{"2" => "hunt"}}
      }

      odds = Odds.for_run(plan(statuses), packs, [{1, "normal"}, {2, "normal"}], [])
      [a2, b2] = odds[2].rows
      assert_in_delta odds[1].any, 1.0, 1.0e-9
      assert_in_delta a2.final, 0.0, 1.0e-9
      assert b2.final > b2.fresh
    end

    test "search floor gives the top available pack everything" do
      packs = [pack("a", [1]), pack("b", [1])]
      statuses = %{"a" => %{"normal" => %{"1" => "favorite"}}}
      plan = Map.put(plan(statuses), "search_floors", [1])
      odds = Odds.for_run(plan, packs, [{1, "normal"}], [])
      assert_in_delta hd(odds[1].rows).final, 1.0, 1.0e-9
    end

    test "expected railway hits count listed Line packs plus the railway share of fallback picks" do
      packs = [
        %{id: "l", name_en: "Line 1", normal_floors: "[1]", hard_floors: "[]"},
        pack("a", [1]),
        pack("b", [1]),
        pack("c", [1])
      ]

      no_plan = Odds.for_run(plan(%{}), packs, [{1, "normal"}], [])
      assert_in_delta no_plan[1].railway, 1 / 4, 1.0e-9

      hunting_line = plan(%{"l" => %{"normal" => %{"1" => "hunt"}}})
      hunted = Odds.for_run(hunting_line, packs, [{1, "normal"}], [])
      assert_in_delta hunted[1].railway, hd(hunted[1].rows).final, 1.0e-9

      banned = plan(%{"l" => %{"normal" => %{"1" => "banned"}}})
      assert_in_delta Odds.for_run(banned, packs, [{1, "normal"}], [])[1].railway, 0.0, 1.0e-9
    end

    test "search count distribution sums to one and cost beats the cost of the average count" do
      packs = Enum.map(1..6, &pack("p#{&1}", [1, 2]))

      statuses = %{
        "p1" => %{"normal" => %{"1" => "favorite", "2" => "favorite"}},
        "p2" => %{"normal" => %{"1" => "favorite", "2" => "favorite"}}
      }

      plan = Map.put(plan(statuses), "search_floors", [1, 2])
      run = Odds.run(plan, packs, [{1, "normal"}, {2, "normal"}], [])

      assert_in_delta run.searches |> Map.values() |> Enum.sum(), 1.0, 1.0e-9
      assert Odds.expected_searches(run.searches) > 0

      average = Odds.expected_searches(run.searches)
      cost_of_average = 15 * average + 5 * average * average
      assert Odds.expected_search_cost(run.searches) > cost_of_average
    end

    test "no search floors means no searches" do
      packs = [pack("a", [1]), pack("b", [1])]
      run = Odds.run(plan(%{"a" => %{"normal" => %{"1" => "hunt"}}}), packs, [{1, "normal"}], [])
      assert run.searches == %{0 => 1.0}
    end

    test "floor 5 shows one fewer pack because of the pinned pack" do
      packs = Enum.map(1..8, &pack("p#{&1}", [4, 5]))
      graces = [%{"index" => 0}, %{"index" => 2}]
      odds = Odds.for_run(plan(%{}), packs, [{4, "normal"}, {5, "normal"}], graces)
      assert odds[4].shown == 5
      assert odds[5].shown == 4
    end
  end
end
