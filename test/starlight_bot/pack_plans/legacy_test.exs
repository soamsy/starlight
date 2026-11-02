defmodule StarlightBot.PackPlans.LegacyTest do
  use ExUnit.Case, async: true

  alias StarlightBot.PackPlans.Legacy

  @eligible %{{"a", "normal"} => [1, 2], {"a", "hard"} => [1, 2, 3], {"b", "hard"} => [3, 4]}
  defp eligible(id, mode), do: Map.get(@eligible, {id, mode}, [])

  test "spreads each pack-level priority over its floors" do
    legacy = %{
      "version" => 1,
      "packs" => %{
        "a" => %{"normal" => %{"priority" => "hunt"}, "hard" => %{"priority" => "hunt", "favorite" => true, "floors" => [2, 3]}},
        "b" => %{"hard" => %{"priority" => "banned"}}
      },
      "hunt_order" => %{"normal" => ["a"], "hard" => ["b", "a"]}
    }

    assert Legacy.convert(legacy, &eligible/2) == %{
             "version" => 2,
             "packs" => %{
               "a" => %{"normal" => %{"1" => "hunt", "2" => "hunt"}, "hard" => %{"2" => "favorite", "3" => "favorite"}},
               "b" => %{"hard" => %{"3" => "banned", "4" => "banned"}}
             },
             "order" => %{"normal" => %{"1" => ["a"], "2" => ["a"]}, "hard" => %{"2" => ["a"], "3" => ["a"]}}
           }
  end

  test "keeps the legacy hunt order within each floor" do
    legacy = %{
      "packs" => %{"a" => %{"hard" => %{"priority" => "hunt"}}, "b" => %{"hard" => %{"priority" => "hunt"}}},
      "hunt_order" => %{"hard" => ["b", "a"]}
    }

    assert Legacy.convert(legacy, &eligible/2)["order"]["hard"]["3"] == ["b", "a"]
  end

  test "unknown packs fall back to every floor and an explicit empty floor list stays empty" do
    legacy = %{"packs" => %{"x" => %{"hard" => %{"priority" => "banned"}}, "a" => %{"hard" => %{"priority" => "hunt", "floors" => []}}}}
    converted = Legacy.convert(legacy, &eligible/2)

    assert converted["packs"]["x"]["hard"] |> Map.keys() |> length() == 15
    refute Map.has_key?(converted["packs"], "a")
  end

  test "current plans and unrelated data are left alone" do
    current = %{"version" => 2, "packs" => %{"a" => %{"hard" => %{"1" => "hunt"}}}}
    assert Legacy.upgrade(current, &eligible/2) == current
    assert Legacy.upgrade(%{}, &eligible/2) == %{}
  end
end
