defmodule StarlightBot.GiftPlansTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans

  defp gift(id, name, tier, ingredients \\ nil), do: %{id: id, name: name, tier: tier, ingredients: ingredients}

  defp plan do
    %{
      "version" => 2,
      "affinity" => "burn",
      "grace_picks" => [],
      "library" => %{
        "keep_lists" => [%{"id" => "kp_1", "name" => "Core", "gifts" => ["Fiery Down"]}],
        "upties" => [%{"id" => "up_1", "name" => "Glimpse +2", "gift" => "Glimpse of Flames", "target_level" => 2}],
        "tiered_fusions" => [
          %{"id" => "tf_1", "name" => "Glimpse", "target" => "Glimpse of Flames", "routes" => []},
          %{"id" => "tf_2", "name" => "Hellterfly", "target" => "Hellterfly's Dream", "routes" => []}
        ],
        "shopping_lists" => []
      },
      "workflows" => [
        %{"id" => "wf_1", "name" => "Opener", "keep" => "kp_1", "steps" => []},
        %{
          "id" => "wf_2",
          "name" => "Standard",
          "keep" => "kp_1",
          "steps" => [
            %{"id" => "st_1", "kind" => "tiered_fusion", "fusions" => ["tf_1", "tf_2"], "enabled" => true},
            %{"id" => "st_2", "kind" => "fixed_fusion", "target" => "Wholeness", "enabled" => true},
            %{"id" => "st_3", "kind" => "uptie", "upties" => ["up_1", "up_gone"], "max_gifts" => 1, "enabled" => true},
            %{"id" => "st_4", "kind" => "tiered_fusion", "fusions" => [], "enabled" => true}
          ]
        }
      ],
      "floor_schedule" => [%{"from_floor" => 1, "workflow" => "wf_1"}, %{"from_floor" => 2, "workflow" => "wf_2"}]
    }
  end

  describe "workflow_for_floor/2" do
    test "picks the last range starting at or before the floor" do
      assert GiftPlans.workflow_for_floor(plan(), 1)["id"] == "wf_1"
      assert GiftPlans.workflow_for_floor(plan(), 2)["id"] == "wf_2"
      assert GiftPlans.workflow_for_floor(plan(), 9)["id"] == "wf_2"
    end

    test "returns nil before the first range" do
      data = %{plan() | "floor_schedule" => [%{"from_floor" => 3, "workflow" => "wf_2"}]}
      assert GiftPlans.workflow_for_floor(data, 2) == nil
    end
  end

  describe "protected_set/3" do
    test "unions the workflow keep list with fusion targets and fixed-fusion ingredients" do
      gifts = [gift("g1", "Wholeness", 4, "g2,g3"), gift("g2", "Ing A", 2), gift("g3", "Ing B", 2)]
      workflow = GiftPlans.find_workflow(plan(), "wf_2")

      assert GiftPlans.protected_set(plan(), workflow, gifts) ==
               MapSet.new(["Fiery Down", "Glimpse of Flames", "Hellterfly's Dream", "Wholeness", "Ing A", "Ing B"])
    end

    test "ignores disabled steps" do
      data = plan()
      [workflow] = Enum.filter(data["workflows"], &(&1["id"] == "wf_2"))
      workflow = update_in(workflow, ["steps"], fn steps -> Enum.map(steps, &Map.put(&1, "enabled", false)) end)

      assert GiftPlans.protected_set(data, workflow, []) == MapSet.new(["Fiery Down"])
    end
  end

  describe "eval_condition/2" do
    setup do
      %{env: %{wallet: 250, owned: MapSet.new(["Fiery Down"])}}
    end

    test "nil always passes", %{env: env} do
      assert GiftPlans.eval_condition(nil, env)
    end

    test "evaluates and/or trees", %{env: env} do
      tree = %{
        "op" => "and",
        "children" => [
          %{"op" => "cost_gte", "value" => 200},
          %{
            "op" => "or",
            "children" => [
              %{"op" => "missing_gift", "gift" => "Fiery Down"},
              %{"op" => "has_gift", "gift" => "Fiery Down"}
            ]
          }
        ]
      }

      assert GiftPlans.eval_condition(tree, env)
      refute GiftPlans.eval_condition(put_in(tree, ["children", Access.at(0), "value"], 300), env)
    end

    test "cost checks fail when cost is unknown" do
      refute GiftPlans.eval_condition(%{"op" => "cost_gte", "value" => 0}, %{wallet: nil, owned: MapSet.new()})
    end
  end

  test "prune_condition/1 drops empty groups and collapses an empty root to nil" do
    assert GiftPlans.prune_condition(%{"op" => "and", "children" => []}) == nil

    assert GiftPlans.prune_condition(%{
             "op" => "and",
             "children" => [%{"op" => "or", "children" => []}, %{"op" => "cost_gte", "value" => 1}]
           }) == %{"op" => "and", "children" => [%{"op" => "cost_gte", "value" => 1}]}
  end

  test "condition_label/1 renders nested groups" do
    tree = %{
      "op" => "and",
      "children" => [
        %{"op" => "cost_gte", "value" => 200},
        %{"op" => "or", "children" => [%{"op" => "missing_gift", "gift" => "A"}, %{"op" => "has_gift", "gift" => "B"}]}
      ]
    }

    assert GiftPlans.condition_label(tree) == "cost >= 200 AND (missing A OR owns B)"
  end

  test "issues/1 flags broken references, empty definition lists, and unscheduled floor 1" do
    data = %{plan() | "floor_schedule" => [%{"from_floor" => 2, "workflow" => "wf_2"}]}
    issues = GiftPlans.issues(data)

    assert Enum.any?(issues, &String.starts_with?(&1, "Floor 1 has no workflow"))
    assert "Standard: step 3 (Uptie) references a deleted definition." in issues
    assert "Standard: step 4 (Tiered Fusion) has no definitions selected." in issues
  end

  test "step_label/2 lists every referenced definition in order" do
    [fusion | _] = GiftPlans.find_workflow(plan(), "wf_2")["steps"]
    assert GiftPlans.step_label(plan(), fusion) == "Tiered Fusion · Glimpse › Hellterfly"
  end

  test "blank/1 schedules its single workflow from floor 1" do
    data = GiftPlans.blank("burn")
    [workflow] = data["workflows"]

    assert data["affinity"] == "burn"
    assert GiftPlans.workflow_for_floor(data, 1) == workflow
    assert GiftPlans.issues(data) == []
  end
end
