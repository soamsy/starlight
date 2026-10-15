defmodule StarlightBotWeb.Live.GiftPlanEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{GiftPlans, Repo, Strategies}
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Repo.insert_all("ego_gifts", [
      %{id: "g_glimpse", name: "Glimpse of Flames", affinity: "burn", tier: 4, buying_cost: 300, ingredients: nil},
      %{id: "g_fiery", name: "Fiery Down", affinity: "burn", tier: 2, buying_cost: 120, ingredients: nil},
      %{id: "g_a", name: "Ing A", affinity: "burn", tier: 2, buying_cost: nil, ingredients: nil},
      %{id: "g_b", name: "Ing B", affinity: "burn", tier: 2, buying_cost: nil, ingredients: nil},
      %{id: "g_fixed", name: "Fixed Thing", affinity: "burn", tier: 4, buying_cost: nil, ingredients: "g_a,g_b"}
    ])

    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    {:noreply, socket} = Live.handle_event("new_plan", %{}, socket)
    %{socket: socket}
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  defp render(socket) do
    socket.assigns |> Live.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  defp saved(socket), do: Strategies.get(:gift_strategies, socket.assigns.editing_id).data

  defp steps(socket), do: hd(saved(socket)["workflows"])["steps"]

  test "route selector lists normal-usable combos first, then combos below the target tier, then fewer points" do
    keys = fn tier -> Enum.map(Live.selector_combos(tier), &StarlightBot.GiftPlans.Combos.combo_key(&1.combo)) end

    assert keys.(4) ==
             ~w(3-3-2 3-3-3 4-3 4-2-2 4-4 3-2-2 3-2-1-1 3-1-1-1-1 3-3-1 2-2-2-2 2-2-2-1-1 4-2-1 4-1-1-1)

    assert keys.(3) == ~w(2-2-2 4-1 3-2-1 3-3 4-2 3-2-2 2-2-1 2-1-1-1 1-1-1-1-1 3-2 3-1-1)
  end

  test "a new plan starts as a valid v2 plan", %{socket: socket} do
    assert saved(socket)["version"] == 2
    assert GiftPlans.issues(saved(socket)) == []
    assert render(socket) =~ "No steps yet"
  end

  test "library definitions can be built and referenced by steps", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "upties"})
      |> then(fn s -> event(s, "set_uptie_gift", %{"id" => s.assigns.selected_def["upties"], "gift" => "Fiery Down"}) end)
      |> event("lib_add", %{"lib" => "tiered_fusions"})
      |> then(fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["tiered_fusions"], "gift" => "Glimpse of Flames"}) end)

    uptie_id = socket.assigns.selected_def["upties"]
    fusion_id = socket.assigns.selected_def["tiered_fusions"]

    [top_332, top_422] = hd(saved(socket)["library"]["tiered_fusions"])["routes"]

    socket =
      socket
      |> event("rt_add", %{"def_id" => fusion_id, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_update", %{"def_id" => fusion_id, "route_id" => top_422["id"], "buy_up_to" => "2", "leftover" => %{"1" => "0", "2" => "1"}})
      |> event("rt_add", %{"def_id" => fusion_id, "parent" => top_422["id"], "tier" => "2", "combo" => "2-2"})
      |> event("rt_duplicate", %{"def_id" => fusion_id, "route_id" => top_332["id"]})
      |> event("add_step", %{"kind" => "uptie", "ref" => uptie_id})
      |> event("add_step", %{"kind" => "tiered_fusion", "ref" => fusion_id})

    [fusion] = saved(socket)["library"]["tiered_fusions"]
    [first, copy, edited, added] = fusion["routes"]
    assert first["combo"] == [3, 3, 2] and copy["combo"] == [3, 3, 2]
    assert copy["id"] != first["id"]
    assert hd(copy["subgoals"]["3"])["id"] != hd(first["subgoals"]["3"])["id"]
    assert edited["buy_up_to"] == 2 and edited["leftover"] == %{"2" => 1}
    assert [%{"combo" => [2, 2]}] = edited["subgoals"]["2"]
    assert added["combo"] == [4, 4]

    socket = event(socket, "rt_reorder", %{"scope" => "#{fusion_id}||4", "ids" => [added["id"], first["id"]]})
    assert Enum.map(hd(saved(socket)["library"]["tiered_fusions"])["routes"], & &1["id"]) == [added["id"], first["id"], copy["id"], edited["id"]]

    socket = event(socket, "rt_delete", %{"def_id" => fusion_id, "route_id" => hd(first["subgoals"]["3"])["id"]})
    assert hd(saved(socket)["library"]["tiered_fusions"])["routes"] |> Enum.at(1) |> Map.get("subgoals") == %{"3" => []}
    assert [%{"kind" => "uptie", "upties" => [^uptie_id], "max_gifts" => 1}, %{"kind" => "tiered_fusion", "fusions" => [^fusion_id]}] = steps(socket)
    assert hd(saved(socket)["library"]["upties"])["gift"] == "Fiery Down"

    for tab <- ~w(workflows upties tiered_fusions shopping_lists keep_lists grace) do
      assert is_binary(socket |> event("set_tab", %{"tab" => tab}) |> render())
    end

    html = render(event(socket, "set_tab", %{"tab" => "tiered_fusions"}))
    assert html =~ "super only"
    assert html =~ "Sub-goal: make T3s"
    assert html =~ "+ add T2 route"
  end

  test "routes can be copied from one tiered fusion and pasted over another", %{socket: socket} do
    target = fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["tiered_fusions"], "gift" => "Glimpse of Flames"}) end

    socket = socket |> event("lib_add", %{"lib" => "tiered_fusions"}) |> then(target)
    source_id = socket.assigns.selected_def["tiered_fusions"]

    socket =
      socket
      |> event("rt_add", %{"def_id" => source_id, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_copy", %{"def_id" => source_id})
      |> event("lib_add", %{"lib" => "tiered_fusions"})
      |> then(target)

    dest_id = socket.assigns.selected_def["tiered_fusions"]
    socket = event(socket, "rt_paste", %{"def_id" => dest_id})

    [source, dest] = saved(socket)["library"]["tiered_fusions"]
    assert Enum.map(dest["routes"], & &1["combo"]) == [[3, 3, 2], [4, 2, 2], [4, 4]]
    assert Enum.map(dest["routes"], & &1["id"]) -- Enum.map(source["routes"], & &1["id"]) == Enum.map(dest["routes"], & &1["id"])
    assert hd(dest["routes"])["subgoals"]["3"] |> hd() |> Map.get("id") != hd(source["routes"])["subgoals"]["3"] |> hd() |> Map.get("id")
    assert render(event(socket, "set_tab", %{"tab" => "tiered_fusions"})) =~ "3 route(s)"
  end

  test "uptie and tiered fusion steps hold an ordered list of definitions", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "tiered_fusions"})
      |> event("lib_add", %{"lib" => "tiered_fusions"})
      |> event("lib_add", %{"lib" => "upties"})

    [tf_a, tf_b] = Enum.map(saved(socket)["library"]["tiered_fusions"], & &1["id"])
    socket = event(socket, "add_step", %{"kind" => "tiered_fusion", "ref" => tf_a})
    [step] = steps(socket)

    socket =
      socket
      |> event("toggle_step_list_item", %{"id" => step["id"], "field" => "fusions", "item" => tf_b, "value" => ""})
      |> event("reorder_step_field", %{"scope" => "#{step["id"]}:fusions", "ids" => [tf_b, tf_a]})

    assert hd(steps(socket))["fusions"] == [tf_b, tf_a]
    assert render(socket) =~ "Fusions, in order:"

    socket = event(socket, "toggle_step_list_item", %{"id" => step["id"], "field" => "fusions", "item" => tf_b, "value" => ""})
    assert hd(steps(socket))["fusions"] == [tf_a]

    socket = event(socket, "add_step", %{"kind" => "uptie", "ref" => hd(saved(socket)["library"]["upties"])["id"]})
    [_fusion, uptie] = steps(socket)
    socket = event(socket, "update_step", %{"step_id" => uptie["id"], "step" => %{"max_gifts" => "3"}})
    assert List.last(steps(socket))["max_gifts"] == 3
    assert render(socket) =~ "Upties, in order:"
  end

  test "gift lists can be copied and pasted across shopping lists and keep lists", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "shopping_lists"})
      |> then(fn s -> event(s, "lib_toggle_gift", %{"lib" => "shopping_lists", "id" => s.assigns.selected_def["shopping_lists"], "gift" => "Ing B"}) end)
      |> then(fn s -> event(s, "lib_toggle_gift", %{"lib" => "shopping_lists", "id" => s.assigns.selected_def["shopping_lists"], "gift" => "Ing A"}) end)
      |> then(fn s -> event(s, "gifts_copy", %{"lib" => "shopping_lists", "def_id" => s.assigns.selected_def["shopping_lists"]}) end)

    keep_id = hd(saved(socket)["library"]["keep_lists"])["id"]
    socket = event(socket, "gifts_paste", %{"lib" => "keep_lists", "def_id" => keep_id})

    library = saved(socket)["library"]
    assert hd(library["keep_lists"])["gifts"] == ["Ing B", "Ing A"]

    for tab <- ~w(shopping_lists keep_lists) do
      assert render(event(socket, "set_tab", %{"tab" => tab})) =~ "2 gift(s)"
    end
  end

  test "heal, heal all, and revive steps", %{socket: socket} do
    socket = event(socket, "add_step", %{"kind" => "heal"})
    [heal] = steps(socket)
    sinner = hd(StarlightBot.Teams.all_sinners())

    socket = event(socket, "update_step", %{"step_id" => heal["id"], "step" => %{"sinner" => sinner}})

    assert [%{"kind" => "heal", "sinner" => ^sinner}] = steps(socket)
    assert GiftPlans.step_label(saved(socket), hd(steps(socket))) == "Heal Sinner · #{sinner}"
    assert render(socket) =~ "about 50% HP and 45 SP"

    socket = event(socket, "add_step", %{"kind" => "heal_all"})
    assert render(socket) =~ "about 15% HP and 15 SP"

    socket = event(socket, "add_step", %{"kind" => "revive"})
    [_heal, _heal_all, revive] = steps(socket)
    socket = event(socket, "update_step", %{"step_id" => revive["id"], "step" => %{"sinner" => sinner}})
    assert GiftPlans.step_label(saved(socket), List.last(steps(socket))) == "Revive · #{sinner}"
    assert render(socket) =~ "Revives this sinner"
  end

  test "steps can be edited, reordered, and given condition trees", %{socket: socket} do
    socket =
      socket
      |> event("add_step", %{"kind" => "budget"})
      |> event("add_step", %{"kind" => "sell"})
      |> event("add_step", %{"kind" => "fixed_fusion"})

    [budget, sell, fixed] = steps(socket)

    socket =
      socket
      |> event("update_step", %{"step_id" => budget["id"], "step" => %{"amount" => "-150"}})
      |> event("update_step", %{"step_id" => fixed["id"], "step" => %{"target" => "Fixed Thing", "buy_missing" => "false"}})
      |> event("toggle_step_list_item", %{"id" => sell["id"], "field" => "tiers", "item" => "2", "value" => ""})
      |> event("reorder_step_field", %{"scope" => "#{sell["id"]}:tiers", "ids" => ["2", "1"]})
      |> event("move_step", %{"id" => fixed["id"], "dir" => "up"})
      |> event("cond_add", %{"step_id" => budget["id"], "path" => "", "node" => "leaf"})
      |> event("cond_add", %{"step_id" => budget["id"], "path" => "", "node" => "group"})
      |> event("cond_update", %{"step_id" => budget["id"], "path" => "0", "op" => "cost_gte", "value" => "200"})
      |> event("cond_update", %{"step_id" => budget["id"], "path" => "1.0", "op" => "missing_gift", "gift" => "Glimpse of Flames"})
      |> event("toggle_step", %{"id" => budget["id"]})

    [budget, fixed, sell] = steps(socket)
    assert budget["amount"] == -150
    assert fixed["target"] == "Fixed Thing" and fixed["buy_missing"] == false
    assert sell["tiers"] == [2, 1]
    assert GiftPlans.condition_label(budget["condition"]) == "cost >= 200 AND missing Glimpse of Flames"

    workflow = hd(saved(socket)["workflows"])
    assert GiftPlans.derived_protected(saved(socket), workflow, socket.assigns.gifts) == ["Fixed Thing", "Ing A", "Ing B"]
    assert render(socket) =~ "if cost &gt;= 200 AND missing Glimpse of Flames"

    socket =
      socket
      |> event("cond_remove", %{"step_id" => budget["id"], "path" => "1"})
      |> event("cond_remove", %{"step_id" => budget["id"], "path" => "0"})

    assert hd(steps(socket))["condition"] == nil
  end

  test "workflows can be added and scheduled, and scheduled workflows can't be deleted", %{socket: socket} do
    [first] = saved(socket)["workflows"]

    socket = event(socket, "add_workflow", %{})
    second = socket.assigns.selected_workflow_id

    socket =
      socket
      |> event("add_schedule_row", %{})
      |> event("update_schedule", %{"rows" => %{"0" => %{"from_floor" => "1", "workflow" => first["id"]}, "1" => %{"from_floor" => "2", "workflow" => second}}})
      |> event("delete_workflow", %{"id" => second})

    data = saved(socket)
    assert length(data["workflows"]) == 2
    assert GiftPlans.workflow_for_floor(data, 1)["id"] == first["id"]
    assert GiftPlans.workflow_for_floor(data, 5)["id"] == second
  end
end
