defmodule StarlightBotWeb.Live.GiftPlanEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{GiftPlans, Plans, Repo}
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.query!("DELETE FROM fusion_route_defaults")

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

  defp saved(socket), do: Plans.get(:gift_plans, socket.assigns.editing_id).data

  defp steps(socket), do: hd(saved(socket)["workflows"])["steps"]

  test "route selector lists normal-usable combos first, then combos below the target tier, then fewer points" do
    keys = fn tier -> Enum.map(Live.selector_combos(tier), &StarlightBot.GiftPlans.Combos.combo_key(&1.combo)) end

    assert keys.(4) ==
             ~w(3-3-2 3-3-3 4-3 4-2-2 4-4 3-2-2 3-2-1-1 3-1-1-1-1 3-3-1 2-2-2-2 2-2-2-1-1 4-2-1 4-1-1-1)

    assert keys.(3) == ~w(2-2-2 4-1 3-2-1 3-3 4-2 3-2-2 2-2-1 2-1-1-1 1-1-1-1-1 3-2 3-1-1)
  end

  test "the shop pane opens on the top milestone, or the first non-empty library without milestones", %{socket: socket} do
    [%{"id" => shop_id}] = saved(socket)["milestones"]
    assert socket.assigns.shop_lib == "milestones"
    assert socket.assigns.selected_milestone_id == shop_id

    socket = socket |> event("lib_add", %{"lib" => "upties"}) |> event("delete_milestone", %{"id" => shop_id})
    socket = event(socket, "select_plan", %{"id" => to_string(socket.assigns.editing_id)})
    assert socket.assigns.shop_lib == "upties"
  end

  test "a new plan starts as a valid v2 plan", %{socket: socket} do
    assert saved(socket)["version"] == 3
    assert GiftPlans.issues(saved(socket)) == []
    assert render(socket) =~ "No steps yet"
  end

  test "library definitions can be built and referenced by steps", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "upties"})
      |> then(fn s -> event(s, "set_uptie_gift", %{"id" => s.assigns.selected_def["upties"], "gift" => "Fiery Down"}) end)
      |> event("lib_add", %{"lib" => "fusions"})
      |> then(fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["fusions"], "gift" => "Glimpse of Flames"}) end)

    uptie_id = socket.assigns.selected_def["upties"]
    fusion_id = socket.assigns.selected_def["fusions"]

    [top_332, top_422] = hd(saved(socket)["library"]["fusions"])["routes"]

    socket =
      socket
      |> event("rt_add", %{"def_id" => fusion_id, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_update", %{"def_id" => fusion_id, "route_id" => top_422["id"], "buy_up_to" => "2", "leftover" => %{"1" => "0", "2" => "1"}})
      |> event("rt_add", %{"def_id" => fusion_id, "parent" => top_422["id"], "tier" => "2", "combo" => "2-2"})
      |> event("rt_duplicate", %{"def_id" => fusion_id, "route_id" => top_332["id"]})
      |> event("add_step", %{"kind" => "uptie", "ref" => uptie_id})
      |> event("add_step", %{"kind" => "fusion", "ref" => fusion_id})

    [fusion] = saved(socket)["library"]["fusions"]
    [first, copy, edited, added] = fusion["routes"]
    assert first["combo"] == [3, 3, 2] and copy["combo"] == [3, 3, 2]
    assert copy["id"] != first["id"]
    assert hd(copy["subgoals"]["3"])["id"] != hd(first["subgoals"]["3"])["id"]
    assert edited["buy_up_to"] == 2 and edited["leftover"] == %{"2" => 1}
    assert [%{"combo" => [2, 2]}] = edited["subgoals"]["2"]
    assert added["combo"] == [4, 4]

    socket = event(socket, "rt_reorder", %{"scope" => "#{fusion_id}||4", "ids" => [added["id"], first["id"]]})
    assert Enum.map(hd(saved(socket)["library"]["fusions"])["routes"], & &1["id"]) == [added["id"], first["id"], copy["id"], edited["id"]]

    socket = event(socket, "rt_delete", %{"def_id" => fusion_id, "route_id" => hd(first["subgoals"]["3"])["id"]})
    assert hd(saved(socket)["library"]["fusions"])["routes"] |> Enum.at(1) |> Map.get("subgoals") == %{"3" => []}
    assert [%{"kind" => "uptie", "upties" => [^uptie_id], "max_gifts" => 1}, %{"kind" => "fusion", "fusions" => [^fusion_id]}] = steps(socket)
    assert hd(saved(socket)["library"]["upties"])["gift"] == "Fiery Down"
    assert hd(saved(socket)["library"]["upties"])["name"] == "Fiery Down"
    assert hd(saved(socket)["library"]["fusions"])["name"] == "Glimpse of Flames"

    for tab <- ~w(workflows shop loadout) do
      assert is_binary(socket |> event("set_tab", %{"tab" => tab}) |> render())
    end

    for lib <- ~w(upties lists fusions) do
      assert is_binary(socket |> event("set_tab", %{"tab" => "shop"}) |> event("lib_select", %{"lib" => lib, "id" => socket.assigns.selected_def[lib]}) |> render())
    end

    html = render(event(socket, "set_tab", %{"tab" => "shop"}))
    assert html =~ "super only"
    assert html =~ "Sub-goal: make T3s"
    assert html =~ "+ add T2 route"
  end

  test "lists take Any-tier entries and keep them on paste", %{socket: socket} do
    socket = socket |> event("lib_add", %{"lib" => "lists"}) |> event("set_tab", %{"tab" => "shop"})
    list_id = socket.assigns.selected_def["lists"]

    socket =
      socket
      |> event("lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down"})
      |> event("lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "tier:3"})

    [keep, list] = saved(socket)["library"]["lists"]
    assert list["gifts"] == ["Fiery Down", "tier:3"]
    assert render(socket) =~ "Any T3"

    socket = socket |> event("gifts_copy", %{"lib" => "lists", "def_id" => list_id}) |> event("gifts_paste", %{"lib" => "lists", "def_id" => keep["id"]})
    assert hd(saved(socket)["library"]["lists"])["gifts"] == ["Fiery Down", "tier:3"]
  end

  test "lists are marked protected and protected floors are shared per gift and kept until the gift leaves the plan", %{socket: socket} do
    socket = socket |> event("lib_add", %{"lib" => "lists"}) |> event("set_tab", %{"tab" => "shop"})
    list_id = socket.assigns.selected_def["lists"]

    socket =
      socket
      |> event("toggle_list_protected", %{"id" => list_id})
      |> event("lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down"})
      |> event("set_protected_floors", %{"entry" => "Fiery Down", "from" => "2", "to" => "4"})

    assert GiftPlans.find_definition(saved(socket), "lists", list_id)["protected"] == true
    assert render(socket) =~ "Protected floors"
    assert GiftPlans.protected_floors(saved(socket), "Fiery Down") == {2, 4}
    assert "protected" in Live.list_roles(saved(socket), list_id)

    socket = event(socket, "toggle_list_protected", %{"id" => list_id})
    assert GiftPlans.protected_floors(saved(socket), "Fiery Down") == {2, 4}

    socket = event(socket, "lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down"})
    assert saved(socket)["protected_floors"] == %{}
  end

  test "lists take any-affinity entries with a tier filter, and they join milestones as optional", %{socket: socket} do
    socket = socket |> event("lib_add", %{"lib" => "lists"}) |> event("set_tab", %{"tab" => "shop"})
    list_id = socket.assigns.selected_def["lists"]

    socket =
      socket
      |> event("lib_add_affinity", %{"def_id" => list_id, "affinity" => "burn", "tiers" => ["3", "2"]})
      |> event("lib_add_affinity", %{"def_id" => list_id, "affinity" => "burn", "tiers" => ["2", "3"]})
      |> event("lib_add_affinity", %{"def_id" => list_id, "affinity" => "bleed"})
      |> event("lib_add_affinity", %{"def_id" => list_id, "affinity" => ""})

    assert List.last(saved(socket)["library"]["lists"])["gifts"] == ["affinity:burn:2,3", "affinity:bleed"]
    assert render(socket) =~ "Any burn T2, T3"

    [%{"id" => shop_id}] = saved(socket)["milestones"]
    socket = event(socket, "toggle_milestone", %{"lib" => "lists", "id" => list_id, "gift" => "affinity:bleed", "milestone" => shop_id})
    assert [%{optional: true, gift: "affinity:bleed"}] = GiftPlans.milestone_entries(saved(socket), shop_id)
    assert render(event(socket, "select_milestone", %{"id" => shop_id})) =~ "optional, buy if seen"
  end

  test "buy steps buy one per run and save an optional stop-once-owning count", %{socket: socket} do
    socket = socket |> event("lib_add", %{"lib" => "lists"})
    list_id = socket.assigns.selected_def["lists"]
    socket = event(socket, "add_step", %{"kind" => "buy_list", "ref" => list_id})
    [buy] = steps(socket)
    refute Map.has_key?(buy, "max_items")

    socket = event(socket, "update_step", %{"step_id" => buy["id"], "step" => %{"list" => list_id, "done_at" => "2", "repeat" => "3"}})
    assert %{"list" => ^list_id, "done_at" => 2, "repeat" => 3} = hd(steps(socket))
    assert render(socket) =~ "Stop once owning"
    assert Live.list_roles(saved(socket), list_id) == ["buy"]

    socket = event(socket, "update_step", %{"step_id" => buy["id"], "step" => %{"list" => list_id, "done_at" => "", "repeat" => "3"}})
    assert hd(steps(socket))["done_at"] == nil
  end

  test "gift search holds up to 3 gifts of tier 3 or under", %{socket: socket} do
    socket = event(socket, "set_tab", %{"tab" => "loadout"})
    html = render(socket)
    assert html =~ ~s(phx-value-gift="Fiery Down")
    refute html =~ ~s(phx-value-gift="Glimpse of Flames")

    socket =
      Enum.reduce(["Fiery Down", "Ing A", "Ing B", "Fixed Thing"], socket, &event(&2, "toggle_search_gift", %{"gift" => &1}))

    assert saved(socket)["gift_search"] == ["Fiery Down", "Ing A", "Ing B"]
    assert render(socket) =~ "3 / 3"

    socket = event(socket, "toggle_search_gift", %{"gift" => "Ing A"})
    assert saved(socket)["gift_search"] == ["Fiery Down", "Ing B"]
  end

  test "routes can be copied from one tiered fusion and pasted over another", %{socket: socket} do
    target = fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["fusions"], "gift" => "Glimpse of Flames"}) end

    socket = socket |> event("lib_add", %{"lib" => "fusions"}) |> then(target)
    source_id = socket.assigns.selected_def["fusions"]

    socket =
      socket
      |> event("rt_add", %{"def_id" => source_id, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_copy", %{"def_id" => source_id})
      |> event("lib_add", %{"lib" => "fusions"})
      |> then(target)

    dest_id = socket.assigns.selected_def["fusions"]
    socket = event(socket, "rt_paste", %{"def_id" => dest_id})

    [source, dest] = saved(socket)["library"]["fusions"]
    assert Enum.map(dest["routes"], & &1["combo"]) == [[3, 3, 2], [4, 2, 2], [4, 4]]
    assert Enum.map(dest["routes"], & &1["id"]) -- Enum.map(source["routes"], & &1["id"]) == Enum.map(dest["routes"], & &1["id"])
    assert hd(dest["routes"])["subgoals"]["3"] |> hd() |> Map.get("id") != hd(source["routes"])["subgoals"]["3"] |> hd() |> Map.get("id")
    assert render(event(socket, "set_tab", %{"tab" => "shop"})) =~ "3 route(s)"
  end

  test "uptie and fusion steps hold an ordered list of definitions", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "fusions"})
      |> event("lib_add", %{"lib" => "fusions"})
      |> event("lib_add", %{"lib" => "upties"})

    [tf_a, tf_b] = Enum.map(saved(socket)["library"]["fusions"], & &1["id"])
    socket = event(socket, "add_step", %{"kind" => "fusion", "ref" => tf_a})
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

  test "a repeated step can run another workflow between repeats, but not one that leads back", %{socket: socket} do
    socket = socket |> event("add_step", %{"kind" => "refresh"}) |> event("add_workflow", %{})
    [standard, between] = saved(socket)["workflows"]
    socket = event(socket, "select_workflow", %{"id" => standard["id"]})
    [step] = steps(socket)

    socket = event(socket, "update_step", %{"step_id" => step["id"], "step" => %{"repeat" => "2", "between" => between["id"]}})
    assert %{"repeat" => 2, "between" => between_id} = hd(steps(socket))
    assert between_id == between["id"]
    html = render(event(socket, "toggle_step", %{"id" => step["id"]}))
    assert html =~ "Between repeats run"
    assert html =~ "↻ Workflow 2"

    socket = socket |> event("select_workflow", %{"id" => between["id"]}) |> event("add_step", %{"kind" => "refresh"})
    [inner] = Enum.at(saved(socket)["workflows"], 1)["steps"]
    socket = event(socket, "update_step", %{"step_id" => inner["id"], "step" => %{"repeat" => "1", "between" => standard["id"]}})
    refute Map.has_key?(hd(Enum.at(saved(socket)["workflows"], 1)["steps"]), "between")

    socket = socket |> event("select_workflow", %{"id" => standard["id"]}) |> event("update_step", %{"step_id" => step["id"], "step" => %{"repeat" => "2", "between" => ""}})
    refute Map.has_key?(hd(steps(socket)), "between")
  end

  test "If steps hold Then and Else steps that can be added, edited, dragged and copied", %{socket: socket} do
    socket = event(socket, "add_step", %{"kind" => "if"})
    [if_step] = steps(socket)
    then_scope = "#{if_step["id"]}:then"
    else_scope = "#{if_step["id"]}:else"

    socket =
      socket
      |> event("set_add_target", %{"scope" => then_scope})
      |> event("add_step", %{"kind" => "affinity_refresh"})
      |> event("set_add_target", %{"scope" => else_scope})
      |> event("add_step", %{"kind" => "refresh"})

    assert render(socket) =~ "Adding into If cost &gt;= 0 › else"
    socket = event(socket, "set_add_target", %{"scope" => else_scope})
    socket = event(socket, "add_step", %{"kind" => "leave"})

    [%{"kind" => "if", "then" => [affinity], "else" => [refresh]}, %{"kind" => "leave"}] = steps(socket)

    socket =
      socket
      |> event("update_step", %{"step_id" => affinity["id"], "step" => %{"affinity" => "poise"}})
      |> event("toggle_step_enabled", %{"id" => refresh["id"]})
      |> event("cond_update", %{"step_id" => if_step["id"], "path" => "0", "op" => "cost_gte", "value" => "150"})

    [%{"then" => [%{"affinity" => "poise"}], "else" => [%{"enabled" => false}]} = updated, _] = steps(socket)
    assert GiftPlans.condition_label(updated["condition"]) == "cost >= 150"

    socket = event(socket, "cond_update", %{"step_id" => if_step["id"], "path" => "0", "op" => "refreshes_lt", "value" => "2"})
    assert GiftPlans.condition_label(hd(steps(socket))["condition"]) == "refreshes < 2"
    assert render(event(socket, "toggle_step", %{"id" => if_step["id"]})) =~ "refreshes this shop under"
    socket = event(socket, "cond_update", %{"step_id" => if_step["id"], "path" => "0", "op" => "cost_gte", "value" => "150"})

    html = render(event(socket, "toggle_step", %{"id" => if_step["id"]}))
    assert html =~ "Then" and html =~ "Else" and html =~ "Exactly one branch runs"

    socket = event(socket, "move_step_to", %{"scope" => else_scope, "id" => affinity["id"], "ids" => [refresh["id"], affinity["id"]]})
    [%{"then" => [], "else" => [_, %{"kind" => "affinity_refresh"}]}, _] = steps(socket)

    socket = event(socket, "duplicate_step", %{"id" => if_step["id"]})
    [first, copy, _leave] = steps(socket)
    assert copy["id"] != first["id"] and hd(copy["else"])["id"] != hd(first["else"])["id"]

    socket = socket |> event("delete_step", %{"id" => refresh["id"]}) |> event("move_step", %{"id" => affinity["id"], "dir" => "up"})
    assert [%{"else" => [%{"kind" => "affinity_refresh"}]}, _, _] = steps(socket)
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
      |> event("lib_add", %{"lib" => "fusions", "type" => "fixed"})

    fixed_id = socket.assigns.selected_def["fusions"]

    socket =
      socket
      |> event("set_fusion_target", %{"id" => fixed_id, "gift" => "Fixed Thing"})
      |> event("lib_update", %{"lib" => "fusions", "def_id" => fixed_id, "def" => %{"name" => "Fixed", "buy_missing" => "false"}})
      |> event("add_step", %{"kind" => "fusion", "ref" => fixed_id})

    [budget, sell, fixed] = steps(socket)

    socket =
      socket
      |> event("update_step", %{"step_id" => budget["id"], "step" => %{"amount" => "-150"}})
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
    assert fixed["fusions"] == [fixed_id]
    assert %{"type" => "fixed", "target" => "Fixed Thing", "buy_missing" => false} = GiftPlans.find_definition(saved(socket), "fusions", fixed_id)
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

  test "fixed fusions link ingredients to sub-fusions and protect everything they reach", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "fusions", "type" => "tiered"})
      |> then(fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["fusions"], "gift" => "Ing A"}) end)

    ing_a_id = socket.assigns.selected_def["fusions"]
    socket = event(socket, "lib_add", %{"lib" => "fusions", "type" => "fixed"})
    fixed_id = socket.assigns.selected_def["fusions"]
    socket = event(socket, "set_fusion_target", %{"id" => fixed_id, "gift" => "Fixed Thing"})

    assert GiftPlans.find_definition(saved(socket), "fusions", fixed_id)["sub_fusions"] == %{"Ing A" => ing_a_id}

    socket = event(socket, "create_sub_fusion", %{"def_id" => fixed_id, "ingredient" => "Ing B"})
    data = saved(socket)
    %{"sub_fusions" => %{"Ing B" => ing_b_id}} = GiftPlans.find_definition(data, "fusions", fixed_id)
    assert %{"type" => "tiered", "target" => "Ing B"} = GiftPlans.find_definition(data, "fusions", ing_b_id)

    socket = event(socket, "set_sub_fusion", %{"def_id" => fixed_id, "ingredient" => "Ing A", "sub" => ""})
    assert GiftPlans.find_definition(saved(socket), "fusions", fixed_id)["sub_fusions"] == %{"Ing B" => ing_b_id}
    assert GiftPlans.issues(saved(socket), socket.assigns.gifts_by_name) == []

    html = render(event(socket, "set_tab", %{"tab" => "shop"}))
    assert html =~ "fuse via Ing B"
    assert html =~ "+ Fixed"
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

  test "a fusion's routes can become its tier's default, which new fusions of that tier start with", %{socket: socket} do
    socket =
      socket
      |> event("lib_add", %{"lib" => "fusions"})
      |> then(fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["fusions"], "gift" => "Glimpse of Flames"}) end)

    source_id = socket.assigns.selected_def["fusions"]

    socket =
      socket
      |> event("rt_add", %{"def_id" => source_id, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_make_default", %{"def_id" => source_id})
      |> event("lib_add", %{"lib" => "fusions"})
      |> then(fn s -> event(s, "set_fusion_target", %{"id" => s.assigns.selected_def["fusions"], "gift" => "Glimpse of Flames"}) end)

    combos = fn id -> Enum.map(GiftPlans.find_definition(saved(socket), "fusions", id)["routes"], & &1["combo"]) end
    new_id = socket.assigns.selected_def["fusions"]

    assert combos.(new_id) == [[3, 3, 2], [4, 2, 2], [4, 4]]

    socket = event(socket, "rt_delete", %{"def_id" => new_id, "route_id" => hd(GiftPlans.find_definition(saved(socket), "fusions", new_id)["routes"])["id"]})
    assert combos.(new_id) == [[4, 2, 2], [4, 4]]

    event(socket, "rt_use_default", %{"def_id" => new_id})
    assert combos.(new_id) == [[3, 3, 2], [4, 2, 2], [4, 4]]
  end

  test "workflows can be copied in from another plan", %{socket: socket} do
    {:ok, source_id} = Plans.save(:gift_plans, %{name: "Source", data: GiftPlans.blank("burn")})
    source = Plans.get(:gift_plans, source_id)
    [%{"id" => wf_id}] = source.data["workflows"]

    socket =
      socket
      |> event("import_source", %{"plan_id" => Integer.to_string(source_id)})
      |> event("import_workflows", %{"workflow" => wf_id})

    assert Enum.map(saved(socket)["workflows"], & &1["name"]) == ["Standard", "Standard (Source)"]
  end

  test "milestones: new upties and fusions join the top one, entries reorder, group, include, and conditions skip cycles", %{socket: socket} do
    [%{"id" => shop_id, "name" => "Shop Done"}] = saved(socket)["milestones"]

    socket = socket |> event("add_milestone", %{}) |> event("move_milestone", %{"id" => shop_id, "dir" => "down"})
    [%{"id" => top_id}, %{"id" => ^shop_id}] = saved(socket)["milestones"]

    socket = socket |> event("lib_add", %{"lib" => "upties"}) |> event("lib_add", %{"lib" => "fusions", "type" => "tiered"}) |> event("lib_add", %{"lib" => "lists"})
    uptie_id = socket.assigns.selected_def["upties"]
    fusion_id = socket.assigns.selected_def["fusions"]
    list_id = socket.assigns.selected_def["lists"]
    uptie_ref = GiftPlans.entry_ref("upties", uptie_id)
    gift_ref = GiftPlans.entry_ref("lists", list_id, "Fiery Down")

    assert Enum.map(GiftPlans.milestone_entries(saved(socket), top_id), & &1.ref) == [uptie_ref, GiftPlans.entry_ref("fusions", fusion_id)]
    assert GiftPlans.milestone_entries(saved(socket), shop_id) == []

    socket =
      socket
      |> event("lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down"})
      |> event("toggle_milestone", %{"lib" => "upties", "id" => uptie_id, "milestone" => shop_id})

    assert GiftPlans.assignments(saved(socket), gift_ref) == %{}

    socket =
      socket
      |> event("toggle_milestone", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down", "milestone" => shop_id})
      |> event("reorder_milestone_blocks", %{"scope" => shop_id, "ids" => [GiftPlans.entry_key(gift_ref), GiftPlans.entry_key(uptie_ref)]})

    assert Enum.map(GiftPlans.milestone_entries(saved(socket), shop_id), & &1.ref) == [gift_ref, uptie_ref]

    keep_entry = %{"milestone_id" => shop_id, "lib" => "lists", "def_id" => list_id, "gift" => "Fiery Down"}
    uptie_entry = %{"milestone_id" => shop_id, "lib" => "upties", "def_id" => uptie_id}

    socket =
      socket
      |> event("set_entry_group", Map.put(keep_entry, "group", "new"))
      |> event("set_entry_group", Map.put(uptie_entry, "group", "A"))
      |> event("set_group_min", %{"milestone_id" => shop_id, "group" => "A", "min" => "2"})

    assert [%{group: "A"}, %{group: "A"}] = GiftPlans.milestone_entries(saved(socket), shop_id)

    socket = event(socket, "set_entry_group", Map.put(uptie_entry, "group", "optional"))
    assert [%{group: "A"}, %{optional: true, ref: ^uptie_ref}] = GiftPlans.milestone_entries(saved(socket), shop_id)
    assert render(event(socket, "set_tab", %{"tab" => "shop"}) |> event("select_milestone", %{"id" => shop_id})) =~ ~s(value="optional" selected)
    socket = event(socket, "set_entry_group", Map.put(uptie_entry, "group", "A"))

    socket = event(socket, "move_milestone_entry", %{"scope" => shop_id, "id" => GiftPlans.entry_key(uptie_ref), "ids" => [GiftPlans.entry_key(uptie_ref), "group:A"]})
    assert [%{group: nil, ref: ^uptie_ref}, %{group: "A"}] = GiftPlans.milestone_entries(saved(socket), shop_id)
    socket = event(socket, "move_milestone_entry", %{"scope" => "#{shop_id}|A", "id" => GiftPlans.entry_key(uptie_ref), "ids" => [GiftPlans.entry_key(gift_ref), GiftPlans.entry_key(uptie_ref)]})
    assert [%{group: "A", ref: ^gift_ref}, %{group: "A", ref: ^uptie_ref}] = GiftPlans.milestone_entries(saved(socket), shop_id)
    assert GiftPlans.group_min(Enum.at(saved(socket)["milestones"], 1), "A") == 2
    assert render(event(socket, "set_tab", %{"tab" => "shop"}) |> event("select_milestone", %{"id" => shop_id})) =~ "Group A: at least"

    socket = event(socket, "lib_toggle_gift", %{"lib" => "lists", "id" => list_id, "gift" => "Fiery Down"})
    assert GiftPlans.assignments(saved(socket), gift_ref) == %{}

    socket = event(socket, "include_milestone", %{"milestone_id" => shop_id, "sub" => top_id})
    assert GiftPlans.assignments(saved(socket), GiftPlans.entry_ref("milestones", top_id)) == %{shop_id => nil}
    socket = event(socket, "include_milestone", %{"milestone_id" => top_id, "sub" => shop_id})
    assert GiftPlans.milestone_entries(saved(socket), top_id) |> Enum.all?(&(&1.lib != "milestones"))

    socket =
      socket
      |> event("cond_add", %{"milestone_id" => top_id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"milestone_id" => top_id, "path" => "0", "op" => "milestone", "milestone" => shop_id})

    assert Enum.at(saved(socket)["milestones"], 0)["condition"] == %{"op" => "and", "children" => [%{"op" => "cost_gte", "value" => 0}]}
    assert Live.milestone_options(saved(socket), top_id) == []

    socket = event(socket, "add_step", %{"kind" => "milestone", "ref" => shop_id})
    [step] = steps(socket)
    assert step["milestone"] == shop_id
    socket = event(socket, "update_step", %{"step_id" => step["id"], "step" => %{"milestone" => top_id}})
    assert hd(steps(socket))["milestone"] == top_id
    assert render(event(socket, "set_tab", %{"tab" => "workflows"})) =~ "Work on Milestone"

    socket = event(socket, "lib_delete", %{"lib" => "upties", "id" => uptie_id})
    assert GiftPlans.milestone_entries(saved(socket), shop_id) |> Enum.map(& &1.lib) == ["milestones"]

    socket = event(socket, "delete_milestone", %{"id" => top_id})
    assert GiftPlans.milestone_entries(saved(socket), shop_id) == []
    assert socket.assigns.selected_milestone_id == shop_id
  end
end
