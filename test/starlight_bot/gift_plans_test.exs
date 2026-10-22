defmodule StarlightBot.GiftPlansTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans

  defp gift(id, name, tier, ingredients \\ nil), do: %{id: id, name: name, tier: tier, ingredients: ingredients}

  defp plan do
    %{
      "version" => 3,
      "affinity" => "burn",
      "grace_picks" => [],
      "library" => %{
        "lists" => [%{"id" => "kp_1", "name" => "Core", "gifts" => ["Fiery Down"]}],
        "upties" => [%{"id" => "up_1", "name" => "Glimpse +2", "gift" => "Glimpse of Flames", "target_level" => 2}],
        "fusions" => [
          %{"id" => "tf_1", "name" => "Glimpse", "type" => "tiered", "target" => "Glimpse of Flames", "routes" => []},
          %{"id" => "tf_2", "name" => "Hellterfly", "type" => "tiered", "target" => "Hellterfly's Dream", "routes" => []},
          %{"id" => "fx_1", "name" => "Wholeness", "type" => "fixed", "target" => "Wholeness", "buy_missing" => true, "sub_fusions" => %{}}
        ]
      },
      "workflows" => [
        %{"id" => "wf_1", "name" => "Opener", "keep" => "kp_1", "steps" => []},
        %{
          "id" => "wf_2",
          "name" => "Standard",
          "keep" => "kp_1",
          "steps" => [
            %{"id" => "st_1", "kind" => "fusion", "fusions" => ["tf_1", "tf_2"], "enabled" => true},
            %{"id" => "st_2", "kind" => "fusion", "fusions" => ["fx_1"], "enabled" => true},
            %{"id" => "st_3", "kind" => "uptie", "upties" => ["up_1", "up_gone"], "max_gifts" => 1, "enabled" => true},
            %{"id" => "st_4", "kind" => "fusion", "fusions" => [], "enabled" => true}
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

    test "protects the gift an uptie step works on, skipping missing uptie definitions" do
      data = plan()
      workflow = %{"id" => "wf_3", "keep" => nil, "steps" => [%{"id" => "st_9", "kind" => "uptie", "upties" => ["up_gone", "up_1"], "enabled" => true}]}

      assert GiftPlans.protected_set(data, workflow, []) == MapSet.new(["Glimpse of Flames"])
    end

    test "ignores disabled steps" do
      data = plan()
      [workflow] = Enum.filter(data["workflows"], &(&1["id"] == "wf_2"))
      workflow = update_in(workflow, ["steps"], fn steps -> Enum.map(steps, &Map.put(&1, "enabled", false)) end)

      assert GiftPlans.protected_set(data, workflow, []) == MapSet.new(["Fiery Down"])
    end
  end

  describe "nested workflows" do
    defp nested_plan do
      run = fn id, target -> %{"id" => id, "kind" => "workflow", "workflow" => target, "enabled" => true} end
      refresh = %{"id" => "st_r", "kind" => "refresh", "enabled" => true}

      %{
        plan()
        | "workflows" => [
            %{"id" => "wf_a", "name" => "A", "keep" => "kp_1", "steps" => [run.("st_a", "wf_b")]},
            %{"id" => "wf_b", "name" => "B", "keep" => nil, "steps" => [refresh, run.("st_b", "wf_c")]},
            %{"id" => "wf_c", "name" => "C", "keep" => nil, "steps" => [%{"id" => "st_c", "kind" => "uptie", "upties" => ["up_1"], "enabled" => true}]},
            %{"id" => "wf_d", "name" => "D", "keep" => nil, "steps" => []}
          ]
      }
    end

    test "an exit step needs no settings and labels itself" do
      step = GiftPlans.new_step("bail", plan())
      assert Map.take(step, ["kind", "enabled", "condition"]) == %{"kind" => "bail", "enabled" => true, "condition" => nil}
      assert GiftPlans.step_label(plan(), step) == "Exit Workflow"

      data = update_in(nested_plan()["workflows"], fn [a, b | rest] -> [a, Map.update!(b, "steps", &[step | &1]) | rest] end)
      assert GiftPlans.issues(data) == GiftPlans.issues(nested_plan())
    end

    test "a workflow can't run itself or anything that leads back to it" do
      data = nested_plan()

      assert GiftPlans.creates_cycle?(data, "wf_a", "wf_a")
      assert GiftPlans.creates_cycle?(data, "wf_c", "wf_a")
      assert GiftPlans.creates_cycle?(data, "wf_b", "wf_a")
      refute GiftPlans.creates_cycle?(data, "wf_c", "wf_d")
      refute GiftPlans.creates_cycle?(data, "wf_d", "wf_a")
    end

    test "expand_steps inlines nested steps and protection reaches into them while only the top keep list applies" do
      data = nested_plan()
      top = GiftPlans.find_workflow(data, "wf_a")

      assert data |> GiftPlans.expand_steps(top) |> Enum.map(& &1["id"]) == ["st_r", "st_c"]
      assert GiftPlans.protected_set(data, top, []) == MapSet.new(["Fiery Down", "Glimpse of Flames"])
    end

    test "a between-repeats workflow counts as called: cycles, protection, issues and imports see it" do
      data =
        update_in(nested_plan()["workflows"], fn [a, b, c, d] ->
          [a, b, c, Map.put(d, "steps", [%{"id" => "st_d", "kind" => "refresh", "enabled" => true, "repeat" => 2, "between" => "wf_c"}])]
        end)

      d = GiftPlans.find_workflow(data, "wf_d")
      assert GiftPlans.called_workflows(d) == ["wf_c"]
      assert GiftPlans.creates_cycle?(data, "wf_c", "wf_d")
      assert data |> GiftPlans.expand_steps(d) |> Enum.map(& &1["id"]) == ["st_d", "st_c"]
      assert GiftPlans.protected_set(data, d, []) == MapSet.new(["Glimpse of Flames"])

      gone = put_in(data, ["workflows", Access.at(3), "steps", Access.at(0), "between"], "wf_gone")
      assert Enum.any?(GiftPlans.issues(gone), &(&1 =~ "D: step 1 (Refresh) runs a deleted workflow between repeats."))

      imported = GiftPlans.import_workflows(GiftPlans.blank(), data, ["wf_d"], "Src")
      [copy_c] = Enum.filter(imported["workflows"], &(&1["name"] == "C"))
      [copy_d] = Enum.filter(imported["workflows"], &(&1["name"] == "D"))
      assert hd(copy_d["steps"])["between"] == copy_c["id"]
    end

    test "issues flag a cycle and a missing workflow" do
      data = nested_plan()
      looped = update_in(data, ["workflows"], &Enum.map(&1, fn
        %{"id" => "wf_c"} = wf -> Map.update!(wf, "steps", fn steps -> steps ++ [%{"id" => "st_x", "kind" => "workflow", "workflow" => "wf_a", "enabled" => true}] end)
        %{"id" => "wf_d"} = wf -> Map.put(wf, "steps", [%{"id" => "st_y", "kind" => "workflow", "workflow" => "wf_gone", "enabled" => true}])
        wf -> wf
      end))

      issues = GiftPlans.issues(looped)
      assert Enum.any?(issues, &(&1 =~ "C: step 2 (Run Workflow) runs A, which leads back to C."))
      assert Enum.any?(issues, &(&1 =~ "D: step 1 (Run Workflow) has no workflow selected"))
      assert GiftPlans.expand_steps(looped, GiftPlans.find_workflow(looped, "wf_a")) |> Enum.map(& &1["id"]) == ["st_r", "st_c"]
    end
  end

  describe "fixed fusion definitions" do
    test "protect the target, its ingredients, and what their sub-fusions reach" do
      gifts = [gift("g1", "Wholeness", 4, "g2,g3"), gift("g2", "Ing A", 3, "g4,g5"), gift("g3", "Ing B", 2), gift("g4", "Deep A", 1), gift("g5", "Deep B", 1)]

      data =
        plan()
        |> update_in(["library", "fusions"], fn defs ->
          Enum.map(defs, fn
            %{"id" => "fx_1"} = d -> Map.put(d, "sub_fusions", %{"Ing A" => "fx_2"})
            d -> d
          end) ++ [%{"id" => "fx_2", "name" => "Ing A", "type" => "fixed", "target" => "Ing A", "sub_fusions" => %{}}]
        end)

      workflow = %{"id" => "wf_x", "keep" => nil, "steps" => [%{"id" => "s", "kind" => "fusion", "fusions" => ["fx_1"], "enabled" => true}]}

      assert GiftPlans.protected_set(data, workflow, gifts) == MapSet.new(["Wholeness", "Ing A", "Ing B", "Deep A", "Deep B"])
    end

    test "issues flag a missing recipe and a sub-fusion aimed at the wrong gift" do
      by_name = Map.new([gift("g1", "Wholeness", 4, "g2,g3"), gift("g2", "Ing A", 2), gift("g3", "Ing B", 2), gift("g9", "Plain", 4)], &{&1.name, &1})

      data =
        update_in(plan(), ["library", "fusions"], fn defs ->
          Enum.map(defs, fn
            %{"id" => "fx_1"} = d -> Map.put(d, "sub_fusions", %{"Ing A" => "tf_1", "Ing B" => "gone"})
            d -> d
          end) ++ [%{"id" => "fx_3", "name" => "Bad", "type" => "fixed", "target" => "Plain", "sub_fusions" => %{}}]
        end)

      issues = GiftPlans.issues(data, by_name)
      assert "Wholeness: the sub-fusion for Ing A (Glimpse) targets Glimpse of Flames." in issues
      assert "Wholeness: the sub-fusion for Ing B was deleted." in issues
      assert "Bad: Plain has no fixed recipe." in issues
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
      refute GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 100}, %{wallet: nil, owned: MapSet.new()})
    end

    test "cost under passes only below the value", %{env: env} do
      assert GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 251}, env)
      refute GiftPlans.eval_condition(%{"op" => "cost_lt", "value" => 250}, env)
      assert GiftPlans.condition_label(%{"op" => "cost_lt", "value" => 250}) == "cost < 250"
    end

    test "all fusions complete checks top-level fusion targets against owned gifts" do
      plan = %{
        "library" => %{
          "fusions" => [
            %{"id" => "fu_top", "target" => "Top", "sub_fusions" => %{"Mid" => "fu_mid"}},
            %{"id" => "fu_mid", "target" => "Mid"},
            %{"id" => "fu_blank", "target" => nil}
          ]
        }
      }

      leaf = %{"op" => "fusions_complete"}
      assert GiftPlans.eval_condition(leaf, %{plan: plan, owned: MapSet.new(["Top"])})
      refute GiftPlans.eval_condition(leaf, %{plan: plan, owned: MapSet.new(["Mid"])})
    end

    test "all upties complete needs every uptie gift owned at its target level" do
      plan = %{
        "library" => %{
          "upties" => [
            %{"gift" => "A", "target_level" => 2},
            %{"gift" => "B", "target_level" => 3},
            %{"gift" => nil, "target_level" => 2}
          ]
        }
      }

      leaf = %{"op" => "upties_complete"}
      done = %{1 => %{name: "A", uptie: 2}, 2 => %{name: "B", uptie: 3}}
      assert GiftPlans.eval_condition(leaf, %{plan: plan, inventory: done})
      refute GiftPlans.eval_condition(leaf, %{plan: plan, inventory: %{done | 2 => %{name: "B", uptie: 2}}})
      refute GiftPlans.eval_condition(leaf, %{plan: plan, inventory: Map.delete(done, 2)})
      assert GiftPlans.condition_label(leaf) == "all upties complete"
    end

    test "a specific fusion or uptie is done when its own target is reached" do
      plan = %{
        "library" => %{
          "fusions" => [%{"id" => "fu_1", "name" => "Make Top", "target" => "Top"}],
          "upties" => [%{"id" => "up_1", "name" => "A to +3", "gift" => "A", "target_level" => 3}]
        }
      }

      env = %{plan: plan, owned: MapSet.new(["Top", "A"]), inventory: %{1 => %{name: "A", uptie: 2}}}
      assert GiftPlans.eval_condition(%{"op" => "fusion_done", "fusion" => "fu_1"}, env)
      refute GiftPlans.eval_condition(%{"op" => "fusion_done", "fusion" => "fu_gone"}, env)
      refute GiftPlans.eval_condition(%{"op" => "uptie_done", "uptie" => "up_1"}, env)
      assert GiftPlans.eval_condition(%{"op" => "uptie_done", "uptie" => "up_1"}, %{env | inventory: %{1 => %{name: "A", uptie: 3}}})
      assert GiftPlans.condition_label(%{"op" => "uptie_done", "uptie" => "up_1"}, plan) == "uptie A to +3 done"
      assert GiftPlans.condition_label(%{"op" => "fusion_done", "fusion" => "fu_gone"}, plan) == "fusion (deleted) done"
    end
  end

  describe "milestones" do
    defp ref(lib, id, gift \\ nil), do: GiftPlans.entry_ref(lib, id, gift)

    defp milestone_plan do
      %{
        "milestones" => [
          %{"id" => "ms_shop", "name" => "Shop Done", "condition" => %{"op" => "cost_gte", "value" => 100}, "blocks" => [
            %{"type" => "entry", "ref" => ref("fusions", "fu_1")},
            %{"type" => "entry", "ref" => ref("upties", "up_1")},
            %{"type" => "entry", "ref" => ref("fusions", "fu_3")},
            %{"type" => "entry", "ref" => ref("lists", "kp_1", "K1")},
            %{"type" => "entry", "ref" => ref("lists", "kp_1", "Gone")}
          ]},
          %{"id" => "ms_late", "name" => "Late", "condition" => %{"op" => "milestone", "milestone" => "ms_shop"}, "blocks" => [
            %{"type" => "entry", "ref" => ref("upties", "up_1")}
          ]}
        ],
        "library" => %{
          "fusions" => [
            %{"id" => "fu_1", "name" => "Make Top", "target" => "Top"},
            %{"id" => "fu_2", "name" => "Make Other", "target" => "Other"},
            %{"id" => "fu_3", "name" => "Unset", "target" => nil}
          ],
          "upties" => [%{"id" => "up_1", "gift" => "A", "target_level" => 2}],
          "lists" => [%{"id" => "kp_1", "name" => "Keep", "gifts" => ["K1", "K2", "tier:3"]}]
        }
      }
    end

    defp env(owned, uptie \\ 2, wallet \\ 100) do
      %{plan: nil, wallet: wallet, owned: MapSet.new(owned), inventory: %{1 => %{name: "A", uptie: uptie}}}
    end

    defp reached?(plan, id, env), do: GiftPlans.eval_condition(%{"op" => "milestone", "milestone" => id}, %{env | plan: plan})

    test "a milestone needs its fusions, upties at target, list gifts, and its own condition" do
      plan = milestone_plan()

      assert reached?(plan, "ms_shop", env(["Top", "A", "K1"]))
      refute reached?(plan, "ms_shop", env(["Top", "A", "K1"], 2, 99))
      refute reached?(plan, "ms_shop", env(["Top", "A"]))
      refute reached?(plan, "ms_shop", env(["A", "K1"]))
      refute reached?(plan, "ms_shop", env(["Top", "A", "K1"], 1))
      assert reached?(plan, "ms_late", env(["Top", "A", "K1"]))
      refute reached?(plan, "ms_late", env(["Top", "A", "K1"], 2, 0))
      refute reached?(plan, "ms_gone", env(["Top", "A", "K1"]))
      assert GiftPlans.condition_label(%{"op" => "milestone", "milestone" => "ms_shop"}, plan) == "milestone Shop Done reached"
      assert GiftPlans.eval_condition(%{"op" => "milestone_not", "milestone" => "ms_shop"}, %{env(["Top", "A"]) | plan: plan})
      refute GiftPlans.eval_condition(%{"op" => "milestone_not", "milestone" => "ms_shop"}, %{env(["Top", "A", "K1"]) | plan: plan})
      assert GiftPlans.condition_label(%{"op" => "milestone_not", "milestone" => "ms_shop"}, plan) == "milestone Shop Done not reached"
      assert Enum.map(GiftPlans.milestone_entries(plan, "ms_shop"), & &1.ref["id"]) == ["fu_1", "up_1", "fu_3", "kp_1"]
    end

    test "grouped entries need at least the group's count met, ungrouped ones all" do
      plan =
        milestone_plan()
        |> GiftPlans.set_entry_group("ms_shop", ref("fusions", "fu_1"), "new")
        |> GiftPlans.set_entry_group("ms_shop", ref("lists", "kp_1", "K1"), "A")
        |> GiftPlans.add_entry("ms_shop", ref("lists", "kp_1", "K2"))
        |> GiftPlans.set_entry_group("ms_shop", ref("lists", "kp_1", "K2"), "A")
        |> put_in(["milestones", Access.at(0), "condition"], nil)

      [%{"type" => "group", "letter" => "A", "refs" => refs}, %{"ref" => %{"id" => "up_1"}}, %{"ref" => %{"id" => "fu_3"}}, %{"ref" => %{"gift" => "Gone"}}] =
        hd(plan["milestones"])["blocks"]
      assert Enum.map(refs, &(&1["gift"] || &1["id"])) == ["fu_1", "K1", "K2"]
      assert GiftPlans.next_group_letter(hd(plan["milestones"])) == "B"

      assert reached?(plan, "ms_shop", env(["A", "K2"]))
      refute reached?(plan, "ms_shop", env(["A"]))
      refute reached?(plan, "ms_shop", env(["K2"], 0))

      two = GiftPlans.set_group_min(plan, "ms_shop", "A", 2)
      refute reached?(two, "ms_shop", env(["A", "K2"]))
      assert reached?(two, "ms_shop", env(["A", "K2", "Top"]))

      four = GiftPlans.set_group_min(plan, "ms_shop", "A", 4)
      assert Enum.any?(GiftPlans.issues(Map.merge(plan(), four)), &(&1 =~ "group A needs 4 but only has 3"))

      back = GiftPlans.set_entry_group(plan, "ms_shop", ref("lists", "kp_1", "K1"), nil)
      assert Enum.map(hd(back["milestones"])["blocks"], &GiftPlans.block_key/1) == ["group:A", "lists|kp_1|K1", "upties|up_1|", "fusions|fu_3|", "lists|kp_1|Gone"]

      reordered = GiftPlans.reorder_group(plan, "ms_shop", "A", ["lists|kp_1|K2", "fusions|fu_1|"])
      assert Enum.map(hd(hd(reordered["milestones"])["blocks"])["refs"], &GiftPlans.entry_key/1) == ["lists|kp_1|K2", "fusions|fu_1|", "lists|kp_1|K1"]
    end

    test "move_entry/5 drags entries into and out of groups, dropping emptied groups" do
      plan = GiftPlans.set_entry_group(milestone_plan(), "ms_shop", ref("fusions", "fu_1"), "new")
      keys = fn plan -> plan["milestones"] |> hd() |> Map.get("blocks") |> Enum.map(&{GiftPlans.block_key(&1), Enum.map(GiftPlans.block_refs(&1), fn r -> GiftPlans.entry_key(r) end)}) end

      into = GiftPlans.move_entry(plan, "ms_shop", "upties|up_1|", "A", ["upties|up_1|", "fusions|fu_1|"])
      assert keys.(into) == [{"group:A", ["upties|up_1|", "fusions|fu_1|"]}, {"fusions|fu_3|", ["fusions|fu_3|"]}, {"lists|kp_1|K1", ["lists|kp_1|K1"]}, {"lists|kp_1|Gone", ["lists|kp_1|Gone"]}]

      out = GiftPlans.move_entry(plan, "ms_shop", "fusions|fu_1|", nil, ["upties|up_1|", "fusions|fu_1|", "group:A", "fusions|fu_3|"])
      assert Enum.map(keys.(out), &elem(&1, 0)) == ["upties|up_1|", "fusions|fu_1|", "fusions|fu_3|", "lists|kp_1|K1", "lists|kp_1|Gone"]

      included = GiftPlans.add_entry(plan, "ms_shop", ref("milestones", "ms_late"))
      assert GiftPlans.move_entry(included, "ms_shop", "milestones|ms_late|", "A", []) == included
      assert GiftPlans.move_entry(plan, "ms_shop", "fusions|fu_gone|", nil, []) == plan
    end

    test "included milestones count as required and their entries are worked first" do
      plan =
        milestone_plan()
        |> GiftPlans.add_entry("ms_late", ref("milestones", "ms_shop"))
        |> GiftPlans.add_entry("ms_late", ref("fusions", "fu_2"))
        |> put_in(["milestones", Access.at(1), "condition"], nil)

      assert Enum.map(GiftPlans.work_entries(plan, "ms_late"), &GiftPlans.entry_key(&1.ref)) ==
               ["fusions|fu_1|", "upties|up_1|", "fusions|fu_3|", "lists|kp_1|K1", "fusions|fu_2|"]

      refute reached?(plan, "ms_late", env(["Top", "A", "Other"]))
      assert reached?(plan, "ms_late", env(["Top", "A", "K1", "Other"]))
      assert GiftPlans.milestone_cycle?(plan, "ms_shop", "ms_late")
    end

    test "entries stop being needed once done, or once their group has enough done or partway" do
      plan = GiftPlans.set_entry_group(milestone_plan(), "ms_shop", ref("upties", "up_1"), "new")
      plan = GiftPlans.set_entry_group(plan, "ms_shop", ref("lists", "kp_1", "K1"), "A")
      needed = fn env -> plan |> GiftPlans.work_entries("ms_shop") |> Enum.filter(&GiftPlans.entry_needed?(plan, &1, %{env | plan: plan})) |> Enum.map(&GiftPlans.entry_key(&1.ref)) end

      assert needed.(%{env(["Top"]) | inventory: %{}}) == ["upties|up_1|", "lists|kp_1|K1"]
      assert needed.(env(["Top"], 0)) == ["upties|up_1|"]
      assert needed.(env(["Top", "K1"], 1)) == ["upties|up_1|"]
      assert needed.(env(["Top", "K1"], 2)) == []
      assert needed.(%{env(["Top", "K1"]) | inventory: %{}}) == []
    end

    test "a partway uptie or fixed fusion holds its group open until it finishes" do
      plan =
        milestone_plan()
        |> put_in(["library", "fusions", Access.at(1)], %{"id" => "fu_2", "name" => "Make Other", "type" => "fixed", "target" => "Other"})
        |> GiftPlans.add_entry("ms_shop", ref("fusions", "fu_2"))
        |> GiftPlans.set_entry_group("ms_shop", ref("upties", "up_1"), "new")
        |> GiftPlans.set_entry_group("ms_shop", ref("lists", "kp_1", "K1"), "A")
        |> GiftPlans.set_entry_group("ms_shop", ref("fusions", "fu_2"), "A")

      gifts = %{"Other" => %{name: "Other", ingredients: "g_ing1,g_ing2"}}
      entry = fn plan, key -> Enum.find(GiftPlans.work_entries(plan, "ms_shop"), &(GiftPlans.entry_key(&1.ref) == key)) end
      base = Map.put(%{env(["Top", "K1"]) | plan: plan, inventory: %{}}, :gifts, gifts)

      assert reached?(plan, "ms_shop", base)
      assert GiftPlans.entry_status(plan, entry.(plan, "fusions|fu_2|"), base) == :open
      assert GiftPlans.entry_status(plan, entry.(plan, "fusions|fu_2|"), %{base | inventory: %{"g_ing1" => %{name: "Ing", uptie: 0}}}) == :partial
      refute reached?(plan, "ms_shop", %{base | inventory: %{"g_ing1" => %{name: "Ing", uptie: 0}}})
      refute reached?(plan, "ms_shop", %{base | inventory: %{1 => %{name: "A", uptie: 1}}})
      assert reached?(plan, "ms_shop", %{base | inventory: %{1 => %{name: "A", uptie: 2}}})
      assert GiftPlans.entry_status(plan, entry.(plan, "fusions|fu_2|"), Map.delete(%{base | inventory: %{"g_ing1" => %{name: "Ing", uptie: 0}}}, :gifts)) == :open
    end

    test "optional entries never hold a milestone back and are never needed" do
      plan = GiftPlans.set_entry_group(milestone_plan(), "ms_shop", ref("lists", "kp_1", "K1"), "optional")
      [k1] = Enum.filter(GiftPlans.milestone_entries(plan, "ms_shop"), &(&1.gift == "K1"))

      assert k1.optional and is_nil(k1.group)
      assert GiftPlans.assignments(plan, ref("lists", "kp_1", "K1")) == %{"ms_shop" => "optional"}
      assert reached?(plan, "ms_shop", env(["Top", "A"]))
      refute GiftPlans.entry_needed?(plan, k1, %{env(["Top", "A"]) | plan: plan})

      grouped = GiftPlans.move_entry(plan, "ms_shop", "lists|kp_1|K1", nil, [])
      assert GiftPlans.set_entry_group(plan, "ms_shop", ref("lists", "kp_1", "K1"), nil) |> GiftPlans.milestone_entries("ms_shop") |> Enum.all?(&(not &1.optional))
      assert grouped |> GiftPlans.milestone_entries("ms_shop") |> Enum.all?(&(not &1.optional))

      included = GiftPlans.add_entry(plan, "ms_shop", ref("milestones", "ms_late"))
      assert GiftPlans.set_entry_group(included, "ms_shop", ref("milestones", "ms_late"), "optional") == included
    end

    test "tier and affinity list entries join milestones as optional only and are never protected by them" do
      plan = put_in(milestone_plan(), ["library", "lists", Access.at(0), "gifts"], ["K1", "K2", "tier:3", "affinity:burn:2"])
      tier_ref = ref("lists", "kp_1", "tier:3")
      plan = plan |> GiftPlans.add_entry("ms_shop", tier_ref) |> GiftPlans.add_entry("ms_shop", ref("lists", "kp_1", "affinity:burn:2"))

      assert [true, true] = for(e <- GiftPlans.milestone_entries(plan, "ms_shop"), GiftPlans.pattern_ref?(e.ref), do: e.optional)
      assert GiftPlans.set_entry_group(plan, "ms_shop", tier_ref, nil) == plan
      assert GiftPlans.set_entry_group(plan, "ms_shop", tier_ref, "new") == plan
      assert GiftPlans.move_entry(GiftPlans.set_entry_group(plan, "ms_shop", ref("fusions", "fu_1"), "new"), "ms_shop", "lists|kp_1|tier:3", "A", []) ==
               GiftPlans.set_entry_group(plan, "ms_shop", ref("fusions", "fu_1"), "new")
      assert reached?(plan, "ms_shop", env(["Top", "A", "K1"]))

      workflow = %{"id" => "wf_m", "keep" => nil, "steps" => [%{"id" => "st_m", "kind" => "milestone", "milestone" => "ms_shop", "enabled" => true}]}
      assert GiftPlans.protected_set(Map.merge(plan(), plan), workflow, []) == MapSet.new(["Top", "A", "K1"])
    end

    test "a cycle between milestones evaluates false and is flagged" do
      plan = put_in(milestone_plan(), ["milestones", Access.at(0), "condition"], %{"op" => "milestone", "milestone" => "ms_late"})

      assert GiftPlans.milestone_cycle?(plan, "ms_shop", "ms_late")
      assert GiftPlans.milestone_cycle?(milestone_plan(), "ms_shop", "ms_shop")
      refute GiftPlans.milestone_cycle?(milestone_plan(), "ms_late", "ms_shop")
      refute reached?(plan, "ms_shop", env(["Top", "A", "K1"]))
      assert Enum.any?(GiftPlans.issues(Map.merge(plan(), plan)), &(&1 =~ "Milestone Shop Done: depends on Late"))
    end

    test "removing a milestone or a referenced thing drops its entries" do
      plan = GiftPlans.add_entry(milestone_plan(), "ms_late", ref("milestones", "ms_shop"))
      data = GiftPlans.remove_milestone(plan, "ms_shop")
      assert Enum.map(data["milestones"], & &1["id"]) == ["ms_late"]
      assert Enum.map(hd(data["milestones"])["blocks"], &GiftPlans.block_key/1) == ["upties|up_1|"]

      data = GiftPlans.drop_refs_everywhere(plan, &(&1["lib"] == "upties"))
      assert GiftPlans.assignments(data, ref("upties", "up_1")) == %{}
      assert GiftPlans.assignments(plan, ref("upties", "up_1")) == %{"ms_shop" => nil, "ms_late" => nil}
    end

    test "a Work on Milestone step protects everything the milestone works on" do
      plan = Map.merge(plan(), milestone_plan())
      workflow = %{"id" => "wf_m", "keep" => nil, "steps" => [%{"id" => "st_m", "kind" => "milestone", "milestone" => "ms_shop", "enabled" => true}]}

      assert GiftPlans.protected_set(plan, workflow, []) == MapSet.new(["Top", "A", "K1"])
      assert GiftPlans.step_label(plan, hd(workflow["steps"])) == "Work on Milestone · Shop Done"
      assert GiftPlans.definition_for(plan, %{"kind" => "milestone", "milestone" => "ms_gone"}) == {:error, :missing_definition}
    end

    test "new plans start with Shop Done, and older plans get it on normalize" do
      assert [%{"name" => "Shop Done", "condition" => nil, "blocks" => []}] = GiftPlans.blank()["milestones"]
      assert [%{"name" => "Shop Done"}] = GiftPlans.normalize(Map.delete(GiftPlans.blank(), "milestones"))["milestones"]
      assert GiftPlans.normalize(%{GiftPlans.blank() | "milestones" => []})["milestones"] == []
    end
  end

  test "refresh count conditions read the shop's refreshes, counting none when unknown" do
    under = %{"op" => "refreshes_lt", "value" => 2}
    at_least = %{"op" => "refreshes_gte", "value" => 2}

    assert GiftPlans.eval_condition(under, %{refreshes: 1})
    refute GiftPlans.eval_condition(under, %{refreshes: 2})
    assert GiftPlans.eval_condition(at_least, %{refreshes: 2})
    assert GiftPlans.eval_condition(under, %{})
    assert GiftPlans.condition_label(under) == "refreshes < 2"
    assert GiftPlans.condition_label(at_least) == "refreshes >= 2"
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
    assert "Standard: step 4 (Fusion) has no definitions selected." in issues
  end

  test "step_label/2 lists every referenced definition in order" do
    [fusion | _] = GiftPlans.find_workflow(plan(), "wf_2")["steps"]
    assert GiftPlans.step_label(plan(), fusion) == "Fusion · Glimpse › Hellterfly"
  end

  describe "fodder, selling, and uptie planning" do
    setup do
      gifts = [
        %{id: "g1", name: "Keep Me", tier: 2, selling_cost: 100},
        %{id: "g2", name: "Junk T1", tier: 1, selling_cost: 50},
        %{id: "g3", name: "Pricey T1", tier: 1, selling_cost: 80},
        %{id: "g4", name: "Junk T2", tier: 2, selling_cost: 90},
        %{id: "g5", name: "Wealth", tier: 6, selling_cost: 999},
        %{id: "g6", name: "Uptied T1", tier: 1, selling_cost: 200}
      ]

      owned = %{
        "g1" => %{name: "Keep Me", uptie: 0, count: 1},
        "g2" => %{name: "Junk T1", uptie: 0, count: 1},
        "g3" => %{name: "Pricey T1", uptie: 0, count: 1},
        "g4" => %{name: "Junk T2", uptie: 0, count: 1},
        "g5" => %{name: "Wealth", uptie: 0, count: 1},
        "g6" => %{name: "Uptied T1", uptie: 1, count: 1}
      }

      %{gifts: gifts, owned: owned, by_id: Map.new(gifts, &{&1.id, &1}), by_name: Map.new(gifts, &{&1.name, &1})}
    end

    test "fodder/3 drops protected gifts, uptied gifts and tiers outside 1 to 4", %{owned: owned, by_id: by_id} do
      names = owned |> GiftPlans.fodder(MapSet.new(["Keep Me"]), by_id) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Junk T1", "Junk T2", "Pricey T1"]
    end

    test "fodder/3 lists a stacked gift once per copy", %{by_id: by_id} do
      owned = %{"g2" => %{name: "Junk T1", uptie: 0, count: 2}, "g4" => %{name: "Junk T2", uptie: 0, count: 1}}
      names = owned |> GiftPlans.fodder(MapSet.new(), by_id) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Junk T1", "Junk T1", "Junk T2"]
    end

    test "sell_order/2 follows tier priority, then highest price", %{owned: owned, by_id: by_id} do
      fodder = GiftPlans.fodder(owned, MapSet.new(["Keep Me"]), by_id)
      assert Enum.map(GiftPlans.sell_order(fodder, [1, 2]), & &1.name) == ["Pricey T1", "Junk T1", "Junk T2"]
      assert Enum.map(GiftPlans.sell_order(fodder, [2]), & &1.name) == ["Junk T2"]
    end

    test "list_sell_order/2 keeps only list matches, in list order, then highest price", %{owned: owned, by_id: by_id} do
      fodder = GiftPlans.fodder(owned, MapSet.new(["Keep Me"]), by_id)
      assert Enum.map(GiftPlans.list_sell_order(fodder, ["Junk T2", "tier:1"]), & &1.name) == ["Junk T2", "Pricey T1", "Junk T1"]
      assert Enum.map(GiftPlans.list_sell_order(fodder, ["Keep Me", "Junk T1"]), & &1.name) == ["Junk T1"]
    end

    test "chance_comet?/1 is true only when grace 8 is picked" do
      assert GiftPlans.chance_comet?(%{"grace_picks" => [%{"index" => 0, "enhance" => 0}, %{"index" => 8, "enhance" => 2}]})
      refute GiftPlans.chance_comet?(%{"grace_picks" => [%{"index" => 0, "enhance" => 0}]})
      refute GiftPlans.chance_comet?(%{})
    end

    test "definition_for/2 resolves a sell step's shopping list only when one is picked" do
      list = %{"id" => "sl_a", "name" => "Dump", "gifts" => []}
      data = %{"library" => %{"lists" => [list]}}

      assert GiftPlans.definition_for(data, %{"kind" => "sell", "list" => nil}) == {:ok, nil}
      assert GiftPlans.definition_for(data, %{"kind" => "sell"}) == {:ok, nil}
      assert GiftPlans.definition_for(data, %{"kind" => "sell", "list" => "sl_a"}) == {:ok, list}
      assert GiftPlans.definition_for(data, %{"kind" => "sell", "list" => "sl_gone"}) == {:error, :missing_definition}
    end

    test "sell_plan/3 takes gifts in order until their known prices cover what's needed", %{owned: owned, by_id: by_id} do
      queue = owned |> GiftPlans.fodder(MapSet.new(["Keep Me"]), by_id) |> GiftPlans.sell_order([1, 2])
      names = fn {gifts, total} -> {Enum.map(gifts, & &1.name), total} end

      assert names.(GiftPlans.sell_plan(queue, 100, 5)) == {["Pricey T1", "Junk T1"], 130}
      assert names.(GiftPlans.sell_plan(queue, 80, 5)) == {["Pricey T1"], 80}
      assert names.(GiftPlans.sell_plan(queue, 500, 5)) == {["Pricey T1", "Junk T1", "Junk T2"], 220}
      assert names.(GiftPlans.sell_plan(queue, 500, 2)) == {["Pricey T1", "Junk T1"], 130}
      assert names.(GiftPlans.sell_plan(queue, nil, 2)) == {["Pricey T1", "Junk T1"], 130}
    end

    test "uptie_plan/5 skips unowned and finished gifts, falls back to +1, and stops when it can't pay in full", %{owned: owned, by_name: by_name} do
      defs = [
        %{"gift" => "Not Owned", "target_level" => 2},
        %{"gift" => "Uptied T1", "target_level" => 1},
        %{"gift" => "Keep Me", "target_level" => 2},
        %{"gift" => "Junk T1", "target_level" => 2}
      ]

      assert {[%{gift: %{name: "Keep Me"}, from: 0, to: 2, price: 180}, %{gift: %{name: "Junk T1"}, from: 0, to: 1, price: 50}], reason} =
               GiftPlans.uptie_plan(defs, owned, by_name, 300, 3)
      assert reason =~ "can't afford Junk T1 +2 (150, have 120), going to +1"

      assert {[%{gift: %{name: "Keep Me"}}], reason} = GiftPlans.uptie_plan(defs, owned, by_name, 220, 3)
      assert reason =~ "can't afford Junk T1 +2 (150, have 40)"

      assert {[_, _], "end of list"} = GiftPlans.uptie_plan(defs, owned, by_name, 400, 3)
      assert {[_], "reached max gifts"} = GiftPlans.uptie_plan(defs, owned, by_name, 400, 1)
    end
  end

  test "list_rank/2 matches gift names and Any-tier entries by their position" do
    entries = ["Fiery Down", GiftPlans.tier_entry(3), "Glimpse"]

    assert GiftPlans.list_rank(entries, %{name: "Fiery Down", tier: 2}) == 0
    assert GiftPlans.list_rank(entries, %{name: "Some T3", tier: 3}) == 1
    assert GiftPlans.list_rank(entries, %{name: "Glimpse", tier: 3}) == 1
    assert GiftPlans.list_rank(entries, %{name: "Other T2", tier: 2}) == nil
    assert GiftPlans.entry_label("tier:3") == "Any T3"
    assert GiftPlans.parse_tier_entry("Fiery Down") == nil
  end

  describe "gift search" do
    test "gift_search_starlight_cost/1 is the cumulative Starlight total for the number of picks" do
      assert Enum.map(0..3, &GiftPlans.gift_search_starlight_cost/1) == [0, 70, 160, 270]
    end

    test "gift_search_tabs/2 groups searchable gifts by tab in first-seen order and caps at 3" do
      gifts_by_name = %{
        "Bleed A" => %{id: "b1", name: "Bleed A", tier: 2, affinity: "bleed"},
        "Plain" => %{id: "n1", name: "Plain", tier: 3, affinity: "none"},
        "Bleed B" => %{id: "b2", name: "Bleed B", tier: 1, affinity: "bleed"},
        "Big" => %{id: "x1", name: "Big", tier: 4, affinity: "bleed"},
        "Slash" => %{id: "s1", name: "Slash", tier: 2, affinity: "slash"}
      }

      tabs = GiftPlans.gift_search_tabs(["Bleed A", "Big", "Plain", "Unknown", "Bleed B", "Slash"], gifts_by_name)
      assert Enum.map(tabs, fn {tab, gifts} -> {tab, Enum.map(gifts, & &1.id)} end) == [{"bleed", ["b1", "b2"]}, {"keywordless", ["n1"]}]
    end

    test "issues/2 flags tier 4 picks and more than 3 gifts" do
      gifts_by_name = %{"Big" => %{name: "Big", tier: 4}, "Small" => %{name: "Small", tier: 2}}
      data = Map.put(GiftPlans.blank(), "gift_search", ["Big", "Small", "Small", "Small"])

      assert Enum.filter(GiftPlans.issues(data, gifts_by_name), &(&1 =~ "Gift search")) == [
               "Gift search has 4 gifts; only 3 can be picked.",
               "Gift search: Big is T4; only T3 and under show up."
             ]
    end

    test "normalize/1 defaults gift_search to an empty list" do
      assert GiftPlans.normalize(%{"version" => 3})["gift_search"] == []
    end
  end

  test "blank/1 schedules its single workflow from floor 1" do
    data = GiftPlans.blank("burn")
    [workflow] = data["workflows"]

    assert data["affinity"] == "burn"
    assert GiftPlans.workflow_for_floor(data, 1) == workflow
    assert GiftPlans.issues(data) == []
  end

  describe "list_remaining/3" do
    test "counts owned gifts matching named and Any-tier entries against the step's done_at" do
      list = %{"gifts" => ["Fiery Down", "tier:3"]}
      assert GiftPlans.list_remaining(list, 2, []) == 2
      assert GiftPlans.list_remaining(list, 2, [%{name: "Fiery Down", tier: 2}, %{name: "Other", tier: 1}]) == 1
      assert GiftPlans.list_remaining(list, 2, [%{name: "Fiery Down", tier: 2}, %{name: "Some T3", tier: 3}, %{name: "Other T3", tier: 3}]) == 0
    end

    test "is nil when the step has no done_at" do
      assert GiftPlans.list_remaining(%{"gifts" => ["Fiery Down"]}, nil, [%{name: "Fiery Down", tier: 2}]) == nil
    end
  end

  describe "affinity entries" do
    test "match a gift's affinity, optionally only some tiers, and label themselves" do
      burn_t2 = %{name: "Burny", tier: 2, affinity: "burn"}
      burn_t4 = %{name: "Big Burn", tier: 4, affinity: "burn"}
      bleed_t2 = %{name: "Bleedy", tier: 2, affinity: "bleed"}

      assert GiftPlans.affinity_entry("burn", [3, 2, 2]) == "affinity:burn:2,3"
      assert GiftPlans.affinity_entry("burn", []) == "affinity:burn"
      assert GiftPlans.entry_label("affinity:burn:2,3") == "Any burn T2, T3"
      assert GiftPlans.entry_label("affinity:burn") == "Any burn"
      assert GiftPlans.entry_matches?("affinity:burn:2,3", burn_t2)
      refute GiftPlans.entry_matches?("affinity:burn:2,3", burn_t4)
      refute GiftPlans.entry_matches?("affinity:burn:2,3", bleed_t2)
      assert GiftPlans.entry_matches?("affinity:burn", burn_t4)
      refute GiftPlans.entry_matches?("affinity:burn", %{name: "Unknown", tier: nil})

      assert GiftPlans.list_rank(["Bleedy", "affinity:burn:4", "tier:2"], burn_t2) == 2
      assert GiftPlans.list_rank(["Bleedy", "affinity:burn:4", "tier:2"], burn_t4) == 1
      assert GiftPlans.list_remaining(%{"gifts" => ["affinity:burn"]}, 2, [burn_t2, bleed_t2]) == 1
    end

    test "on a keep list, protect every matching gift; on a sell list, pick matches in order" do
      plan = put_in(plan(), ["library", "lists", Access.at(0), "gifts"], ["affinity:burn:1,2"])
      protected = GiftPlans.protected_set(plan, hd(plan["workflows"]), [])
      by_id = %{
        "g_1" => %{id: "g_1", name: "Burn T1", tier: 1, affinity: "burn", selling_cost: 5},
        "g_2" => %{id: "g_2", name: "Burn T3", tier: 3, affinity: "burn", selling_cost: 9},
        "g_3" => %{id: "g_3", name: "Bleed T1", tier: 1, affinity: "bleed", selling_cost: 7}
      }

      owned = Map.new(by_id, fn {id, _} -> {id, %{uptie: 0, count: 1}} end)

      assert GiftPlans.protected?(protected, by_id["g_1"])
      refute GiftPlans.protected?(protected, by_id["g_2"])
      fodder = GiftPlans.fodder(owned, protected, by_id)
      assert fodder |> Enum.map(& &1.name) |> Enum.sort() == ["Bleed T1", "Burn T3"]
      assert Enum.map(GiftPlans.list_sell_order(fodder, ["affinity:burn", "affinity:bleed"]), & &1.name) == ["Burn T3", "Bleed T1"]
    end
  end

  describe "keep lists with Any-tier entries" do
    test "protect every gift of that tier from being sold or fused" do
      plan = put_in(plan(), ["library", "lists", Access.at(0), "gifts"], ["Fiery Down", "tier:3"])
      protected = GiftPlans.protected_set(plan, hd(plan["workflows"]), [])
      by_id = %{"g_1" => Map.put(gift("g_1", "Some T3", 3), :selling_cost, 10), "g_2" => Map.put(gift("g_2", "Some T2", 2), :selling_cost, 5)}
      owned = %{"g_1" => %{uptie: 0, count: 1}, "g_2" => %{uptie: 0, count: 1}}

      assert GiftPlans.protected?(protected, %{name: "Other T3", tier: 3})
      refute GiftPlans.protected?(protected, %{name: "Other T2", tier: 2})
      assert Enum.map(GiftPlans.fodder(owned, protected, by_id), & &1.name) == ["Some T2"]
    end
  end

  describe "if steps" do
    defp if_steps do
      [
        %{"id" => "st_1", "kind" => "refresh", "enabled" => true},
        %{"id" => "st_if", "kind" => "if", "enabled" => true, "condition" => %{"op" => "cost_gte", "value" => 150},
          "then" => [%{"id" => "st_t", "kind" => "affinity_refresh", "enabled" => true, "affinity" => "poise"}],
          "else" => [%{"id" => "st_e", "kind" => "fusion", "fusions" => ["tf_1"], "enabled" => true}]},
        %{"id" => "st_3", "kind" => "leave", "enabled" => true}
      ]
    end

    test "new If steps start with a condition and empty branches" do
      step = GiftPlans.new_step("if", plan())
      assert %{"kind" => "if", "then" => [], "else" => [], "condition" => %{"op" => "and"}} = step
      assert GiftPlans.step_label(plan(), step) == "If"
    end

    test "nested helpers find, update, remove and move steps at any depth" do
      steps = if_steps()

      assert Enum.map(GiftPlans.all_steps(steps), & &1["id"]) == ["st_1", "st_if", "st_t", "st_e", "st_3"]
      assert GiftPlans.find_step(steps, "st_e")["kind"] == "fusion"
      assert steps |> GiftPlans.update_step_in("st_t", &Map.put(&1, "affinity", "burn")) |> GiftPlans.find_step("st_t") |> Map.get("affinity") == "burn"
      assert steps |> GiftPlans.remove_step("st_e") |> GiftPlans.find_step("st_if") |> Map.get("else") == []

      moved = GiftPlans.move_step(steps, "st_1", "st_if:else", ["st_1", "st_e"])
      assert Enum.map(moved, & &1["id"]) == ["st_if", "st_3"]
      assert Enum.map(GiftPlans.find_step(moved, "st_if")["else"], & &1["id"]) == ["st_1", "st_e"]

      out = GiftPlans.move_step(steps, "st_t", "", ["st_t", "st_1", "st_if", "st_3"])
      assert Enum.map(out, & &1["id"]) == ["st_t", "st_1", "st_if", "st_3"]
      assert GiftPlans.find_step(out, "st_if")["then"] == []

      assert GiftPlans.move_step(steps, "st_if", "st_if:then", []) == steps

      swapped = GiftPlans.update_containing_list(steps, "st_t", &Enum.reverse([%{"id" => "st_new"} | &1]))
      assert Enum.map(GiftPlans.find_step(swapped, "st_if")["then"], & &1["id"]) == ["st_t", "st_new"]

      copy = GiftPlans.fresh_step_ids(GiftPlans.find_step(steps, "st_if"))
      assert copy["id"] != "st_if" and hd(copy["then"])["id"] != "st_t" and hd(copy["else"])["id"] != "st_e"
    end

    test "protection, issues and imports look inside both branches" do
      data = put_in(plan(), ["workflows", Access.at(1), "steps"], if_steps())
      workflow = Enum.at(data["workflows"], 1)

      assert data |> GiftPlans.expand_steps(workflow) |> Enum.map(& &1["id"]) == ["st_1", "st_if", "st_t", "st_e", "st_3"]
      assert MapSet.member?(GiftPlans.protected_set(data, workflow, []), "Glimpse of Flames")

      broken = put_in(data, ["workflows", Access.at(1), "steps", Access.at(1), "else", Access.at(0), "fusions"], ["tf_gone"])
      assert "Standard: step 2 › else 1 (Fusion) references a deleted definition." in GiftPlans.issues(broken)

      nested_run = put_in(data, ["workflows", Access.at(1), "steps", Access.at(1), "then"], [%{"id" => "st_r", "kind" => "workflow", "workflow" => "wf_1", "enabled" => true}])
      assert GiftPlans.called_workflows(Enum.at(nested_run["workflows"], 1)) == ["wf_1"]
      assert GiftPlans.creates_cycle?(nested_run, "wf_1", "wf_2")

      imported = GiftPlans.import_workflows(GiftPlans.blank(), data, ["wf_2"], "Src")
      copy = Enum.find(imported["workflows"], &(&1["name"] == "Standard (Src)"))
      [_, copied_if, _] = copy["steps"]
      [fusion] = copied_if["else"]
      assert fusion["id"] != "st_e"
      assert GiftPlans.find_definition(imported, "fusions", hd(fusion["fusions"]))["name"] == "Glimpse"
    end
  end

  describe "import_workflows/4" do
    defp source_plan do
      %{
        "workflows" => [
          %{"id" => "wf_loop", "name" => "Repeat", "keep" => "kp_core", "steps" => [
            %{"id" => "st_a", "kind" => "workflow", "workflow" => "wf_check"}
          ]},
          %{"id" => "wf_check", "name" => "ShopCheck", "keep" => "kp_core", "steps" => [
            %{"id" => "st_b", "kind" => "buy_list", "list" => "sl_src"},
            %{"id" => "st_c", "kind" => "fusion", "fusions" => ["fu_bsm", "tf_shared"]},
            %{"id" => "st_d", "kind" => "uptie", "upties" => ["up_src"]}
          ]},
          %{"id" => "wf_other", "name" => "Unrelated", "keep" => nil, "steps" => []}
        ],
        "library" => %{
          "lists" => [%{"id" => "kp_core", "name" => "Core", "gifts" => ["A"]}, %{"id" => "sl_src", "name" => "Buys", "gifts" => ["B"]}],
          "upties" => [%{"id" => "up_src", "name" => "Glimpse +2", "gift" => "Glimpse of Flames", "target_level" => 2}],
          "fusions" => [
            %{"id" => "fu_bsm", "name" => "BSM", "type" => "fixed", "target" => "BSM", "sub_fusions" => %{"Midwinter" => "tf_mid"}},
            %{"id" => "tf_mid", "name" => "Midwinter", "type" => "tiered", "target" => "Midwinter", "routes" => []},
            %{"id" => "tf_shared", "name" => "Glimpse", "type" => "tiered", "target" => "Glimpse of Flames", "routes" => []}
          ]
        }
      }
    end

    test "copies a workflow and everything it runs, reusing same-named library entries and copying the rest" do
      data = GiftPlans.import_workflows(plan(), source_plan(), ["wf_loop"], "SinkPoise")
      names = Enum.map(data["workflows"], & &1["name"])

      assert "Repeat" in names and "ShopCheck" in names
      refute "Unrelated" in names

      loop = Enum.find(data["workflows"], &(&1["name"] == "Repeat"))
      check = Enum.find(data["workflows"], &(&1["name"] == "ShopCheck"))
      assert [%{"kind" => "workflow", "workflow" => check_id}] = loop["steps"]
      assert check_id == check["id"]
      refute check_id == "wf_check"

      [buy, fusion, uptie] = check["steps"]
      assert GiftPlans.find_definition(data, "lists", buy["list"])["name"] == "Buys"
      assert loop["keep"] == "kp_1"
      assert uptie["upties"] == ["up_1"]

      [bsm_id, glimpse_id] = fusion["fusions"]
      assert glimpse_id == "tf_1"
      bsm = GiftPlans.find_definition(data, "fusions", bsm_id)
      assert bsm["name"] == "BSM"
      assert GiftPlans.find_definition(data, "fusions", bsm["sub_fusions"]["Midwinter"])["name"] == "Midwinter"
    end

    test "a workflow name that already exists gets the source plan's name added" do
      base = Map.put(plan(), "workflows", [%{"id" => "wf_x", "name" => "ShopCheck", "keep" => nil, "steps" => []}])
      data = GiftPlans.import_workflows(base, source_plan(), ["wf_check"], "SinkPoise")

      assert Enum.map(data["workflows"], & &1["name"]) == ["ShopCheck", "ShopCheck (SinkPoise)"]
    end
  end

  describe "mounting trials schedule" do
    test "plans default to avoiding enemy HP from F1, and the latest row at or below the floor wins" do
      assert GiftPlans.blank()["mounting_trials"] == [%{"from_floor" => 1, "mode" => "avoid_hp"}]
      assert GiftPlans.normalize(Map.delete(GiftPlans.blank(), "mounting_trials"))["mounting_trials"] == [%{"from_floor" => 1, "mode" => "avoid_hp"}]

      data = %{"mounting_trials" => [%{"from_floor" => 1, "mode" => "avoid_hp"}, %{"from_floor" => 5, "mode" => "best_gift"}]}
      assert GiftPlans.mounting_trials_mode(data, 4) == "avoid_hp"
      assert GiftPlans.mounting_trials_mode(data, 5) == "best_gift"
      assert GiftPlans.mounting_trials_mode(%{"mounting_trials" => []}, 3) == "best_gift"
    end
  end
end
