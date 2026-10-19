defmodule StarlightBot.ConditionsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Conditions

  defp leaf(name), do: %{"op" => "on", "name" => name}

  test "evaluates and/or groups with the domain's leaf evaluator" do
    on = MapSet.new(["a", "c"])
    eval = fn tree -> Conditions.eval(tree, &MapSet.member?(on, &1["name"])) end

    assert eval.(nil)
    assert eval.(%{"op" => "and", "children" => [leaf("a"), %{"op" => "or", "children" => [leaf("b"), leaf("c")]}]})
    refute eval.(%{"op" => "and", "children" => [leaf("a"), leaf("b")]})
  end

  test "builds and edits a tree by path" do
    tree =
      nil
      |> Conditions.add("", leaf("a"))
      |> Conditions.add("", Conditions.group(leaf("b")))
      |> Conditions.add("1", leaf("c"))
      |> Conditions.put_leaf("1.0", leaf("d"))
      |> Conditions.toggle_op("")

    assert Conditions.label(tree, & &1["name"]) == "a OR (d OR c)"
    assert tree |> Conditions.remove("1.1") |> Conditions.label(& &1["name"]) == "a OR d"
    assert Conditions.remove(tree, "") == nil
  end

  test "prune drops empty groups and collapses an empty root to nil" do
    assert Conditions.prune(%{"op" => "and", "children" => [%{"op" => "or", "children" => []}]}) == nil
  end
end
