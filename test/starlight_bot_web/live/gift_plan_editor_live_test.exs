defmodule StarlightBotWeb.Live.GiftPlanEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BaseRepo, GiftPlans, Plans, Repo}
  alias StarlightBotWeb.Live.GiftPlanEditorLive, as: Live

  setup do
    :ok = StarlightBot.TestDB.checkout()
    Repo.query!("DELETE FROM fusion_route_user_templates")
    BaseRepo.query!("DELETE FROM fusion_route_templates")

    BaseRepo.insert_all("ego_gifts", [
      %{id: "g_glimpse", name: "Glimpse of Flames", affinity: "burn", tier: 4, buying_cost: 300, ingredients: nil, obtain_method: "Shop"},
      %{id: "g_fiery", name: "Fiery Down", affinity: "burn", tier: 2, buying_cost: 120, ingredients: nil, obtain_method: "Shop"},
      %{id: "g_a", name: "Ing A", affinity: "burn", tier: 2, buying_cost: nil, ingredients: nil, obtain_method: "Shop"},
      %{id: "g_b", name: "Ing B", affinity: "burn", tier: 2, buying_cost: nil, ingredients: nil, obtain_method: "Event"},
      %{id: "g_fixed", name: "Fixed Thing", affinity: "burn", tier: 4, buying_cost: nil, ingredients: "g_a,g_b", obtain_method: "Fuse #g_a# + #g_b#"}
    ])

    BaseRepo.insert_all("ego_gifts", [
      %{id: "g_uptied", name: "Uptied One", affinity: "burn", tier: 1, buying_cost: 50, obtain_method: "Shop", description: "Base text", uptie2: "Plus text", uptie3: "Plus plus text"}
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


  test "route selector only offers combos that work in the chosen shop, normal-usable first, then below the target tier, then fewer points" do
    keys = fn tier, shop -> Enum.map(Live.selector_combos(tier, shop), &StarlightBot.GiftPlans.Combos.combo_key(&1.combo)) end

    assert keys.(4, :super) ==
             ~w(3-3-2 3-3-3 4-3 4-2-2 4-4 3-2-2 3-2-1-1 3-1-1-1-1 3-3-1 2-2-2-2 2-2-2-1-1 4-2-1 4-1-1-1)

    assert keys.(4, :normal) == ~w(3-3-2 3-3-3 4-3 4-2-2 4-4)
    assert keys.(3, :super) == ~w(2-2-2 4-1 3-2-1 3-3 4-2 2-2-1 2-1-1-1 1-1-1-1-1 3-2 3-1-1)
    assert keys.(3, :normal) == ~w(2-2-2 4-1 3-2-1 3-3 4-2 3-2-2)
  end

  test "the route shop toggle hides routes that don't work in that shop and reordering keeps hidden routes in place" do
    routes = [%{"id" => "a", "combo" => [3, 3, 2]}, %{"id" => "b", "combo" => [3, 2, 2]}, %{"id" => "c", "combo" => [4, 4]}]

    assert Enum.filter(routes, &Live.route_in_shop?(&1, 4, :normal)) |> Enum.map(& &1["id"]) == ["a", "c"]
    assert Enum.filter(routes, &Live.route_in_shop?(&1, 4, :super)) |> Enum.map(& &1["id"]) == ["a", "b", "c"]
    assert StarlightBot.GiftPlans.Routes.reorder(routes, nil, 4, ["c", "a"]) |> Enum.map(& &1["id"]) == ["c", "b", "a"]
  end

  defp section(socket), do: hd(saved(socket)["sections"])
  defp entry(socket, name), do: Enum.find(section(socket)["entries"], &(GiftPlans.subject_gift(&1) == name))
  defp shop(socket), do: event(socket, "set_tab", %{"tab" => "shop"})

  test "a new plan starts as a valid v6 plan with the shop pane on its section", %{socket: socket} do
    assert saved(socket)["version"] == 6
    assert GiftPlans.issues(saved(socket)) == []
    assert socket.assigns.root_section_id == section(socket)["id"]
    assert render(shop(socket)) =~ "No entries yet"
    assert render(socket) =~ ~s(id="gift-shop-btn")
    assert render(socket) =~ ~s(id="gift-loadout-btn")
    refute render(socket) =~ "End state"

    for tab <- ~w(shop loadout) do
      assert is_binary(socket |> event("set_tab", %{"tab" => tab}) |> render())
    end
  end

  test "gifts join the section with keep and buy, fixed fusions bring their ingredients, and entry settings save per floor", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Fixed Thing"}) |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})

    assert Enum.map(section(socket)["entries"], &GiftPlans.subject_gift/1) == ["Fixed Thing", "Ing A", "Ing B", "Glimpse of Flames"]
    assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "buy" => true, "goal" => "required"}]} = entry(socket, "Fixed Thing")
    assert %{"fusion" => %{"type" => "tiered"}, "floors" => [%{"fuse" => false, "goal" => "optional"}]} = entry(socket, "Ing A")
    assert %{"fusion" => nil} = entry(socket, "Ing B")
    assert %{"fusion" => %{"type" => "tiered", "routes" => [_, _]}, "floors" => [%{"fuse" => true}]} = entry(socket, "Glimpse of Flames")

    html = render(socket)
    assert html =~ "Made from:" and html =~ "Added"
    assert html =~ ~s(phx-click="list_add_gift" phx-value-gift="Fiery Down")
    assert Regex.run(~r/data-added="([^"]*)"/, html) |> List.last() =~ "Glimpse of Flames"

    assert html =~ ~s(data-gift-popup="Glimpse of Flames")
    refute html =~ "No description available."
    popup = event(socket, "show_gift_popup", %{"gift" => "Glimpse of Flames", "x" => 120, "y" => 40})
    assert render(popup) =~ "No description available."
    refute render(event(popup, "hide_gift_popup", %{})) =~ "No description available."
    assert event(socket, "show_gift_popup", %{"gift" => "Glimpse of Flames", "uptie" => "2", "x" => 0, "y" => 0}).assigns.gift_popup.view == "base"
    uptied = event(socket, "show_gift_popup", %{"gift" => "Uptied One", "uptie" => "1", "x" => 0, "y" => 0})
    assert render(uptied) =~ "Plus text"
    assert render(event(uptied, "set_gift_popup_view", %{"level" => "uptie3"})) =~ "Plus plus text"

    glimpse = entry(socket, "Glimpse of Flames")["id"]

    socket =
      socket
      |> event("list_set_uptie", %{"entry" => glimpse, "from" => "1", "level" => "2"})
      |> event("list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
      |> event("list_split", %{"entry" => glimpse, "floor" => "5"})
      |> event("list_update_segment", %{"entry" => glimpse, "from" => "5", "segment" => %{"disposition" => "sell", "max" => "2"}})

    assert [%{"from" => 1, "uptie" => 2, "buy" => false, "disposition" => "keep"}, %{"from" => 5, "disposition" => "sell", "max" => 2, "uptie" => 2}] =
             entry(socket, "Glimpse of Flames")["floors"]

    assert socket.assigns.entry_tabs[glimpse] == {nil, 5}
    html = render(socket)
    assert html =~ "F1-4" and html =~ "F5+" and html =~ "Max per floor"

    socket = event(socket, "list_select_tab", %{"entry" => glimpse, "from" => "1"})
    assert socket.assigns.entry_tabs[glimpse] == {nil, 1}

    socket = event(socket, "list_remove_segment", %{"entry" => glimpse, "from" => "5"})
    assert [%{"from" => 1}] = entry(socket, "Glimpse of Flames")["floors"]

    ing_b = entry(socket, "Ing B")["id"]
    socket = event(socket, "list_remove_entry", %{"entry" => ing_b})
    assert Enum.any?(GiftPlans.issues(saved(socket), socket.assigns.gifts_by_name), &(&1 =~ "Fixed Thing needs Ing B in this stage."))
    assert render(socket) =~ "Fixed Thing needs Ing B in this stage."

    ids = section(socket)["entries"] |> Enum.map(& &1["id"]) |> Enum.reverse()
    socket = event(socket, "list_reorder_entries", %{"scope" => section(socket)["id"], "ids" => ids})
    assert Enum.map(section(socket)["entries"], & &1["id"]) == ids
  end

  test "a run type timeline gets its own tabs, edits land on it, and the base tabs stay put", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]

    socket = event(socket, "list_add_timeline", %{"entry" => glimpse, "kinds" => ["all_hard", "extreme"]})
    [%{"id" => timeline, "kinds" => ["all_hard", "extreme"]}] = entry(socket, "Glimpse of Flames")["timelines"]
    assert socket.assigns.entry_tabs[glimpse] == {timeline, 1}
    html = render(socket)
    assert html =~ "Hard from F1 + Extreme planned" and html =~ "list_toggle_timeline_kind"
    refute html =~ "list_remove_schedule"

    socket = socket |> event("list_split", %{"entry" => glimpse, "floor" => "4"}) |> event("list_toggle", %{"entry" => glimpse, "from" => "4", "field" => "sell"})
    entry = entry(socket, "Glimpse of Flames")
    assert Enum.map(entry["floors"], & &1["from"]) == [1]
    assert [%{"floors" => [%{"disposition" => "keep"}, %{"from" => 4, "disposition" => "sell"}]}] = entry["timelines"]

    socket = event(socket, "list_split", %{"entry" => glimpse, "timeline" => "", "floor" => "2"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 2]
    assert socket.assigns.entry_tabs[glimpse] == {nil, 2}

    socket = event(socket, "list_toggle_timeline_kind", %{"entry" => glimpse, "timeline" => timeline, "kind" => "extreme"})
    assert [%{"kinds" => ["all_hard"]}] = entry(socket, "Glimpse of Flames")["timelines"]

    socket = event(socket, "list_toggle_timeline_kind", %{"entry" => glimpse, "timeline" => timeline, "kind" => "all_hard"})
    refute Map.has_key?(entry(socket, "Glimpse of Flames"), "timelines")
    assert socket.assigns.entry_tabs[glimpse] == {nil, 1}

    socket = event(socket, "list_add_timeline", %{"entry" => glimpse, "kind" => "extreme"})
    assert [%{"kinds" => ["extreme"]}] = entry(socket, "Glimpse of Flames")["timelines"]
  end

  test "a tab can branch on a condition, branch edits land on the branch and the chain renders under the tab", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    socket = event(socket, "list_add_branch", %{"entry" => glimpse, "from" => "1", "timeline" => ""})
    [%{"branches" => [%{"id" => branch, "condition" => %{"op" => "and", "children" => [_]}, "buy" => true}]}] = entry(socket, "Glimpse of Flames")["floors"]
    assert socket.assigns.entry_tabs[glimpse] == {nil, 1, branch}
    assert socket.assigns.editing_condition_case_id == branch
    assert render(socket) =~ "list_select_branch"

    socket = event(socket, "list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "sell"})
    assert [%{"disposition" => "keep", "branches" => [%{"disposition" => "sell"}]}] = entry(socket, "Glimpse of Flames")["floors"]

    socket = event(socket, "cond_update", %{"entry" => glimpse, "from" => "1", "timeline" => "", "branch" => branch, "path" => "0", "op" => "refreshes", "cmp" => "gte", "value" => "2"})
    assert [%{"branches" => [%{"condition" => %{"children" => [%{"op" => "refreshes", "value" => 2}]}}]}] = entry(socket, "Glimpse of Flames")["floors"]

    socket = event(socket, "list_select_branch", %{"entry" => glimpse, "from" => "1", "timeline" => "", "branch" => ""})
    assert socket.assigns.entry_tabs[glimpse] == {nil, 1}
    socket = event(socket, "list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
    assert [%{"buy" => false, "branches" => [%{"disposition" => "sell"}]}] = entry(socket, "Glimpse of Flames")["floors"]

    socket = event(socket, "list_remove_branch", %{"entry" => glimpse, "from" => "1", "timeline" => "", "branch" => branch})
    refute Map.has_key?(hd(entry(socket, "Glimpse of Flames")["floors"]), "branches")
  end

  test "Add Schedule shows floor tabs, new tabs start after the last one, and a tab's start floor can move to any free floor", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    assert render(socket) =~ "list_add_schedule"

    socket = event(socket, "list_add_schedule", %{"entry" => glimpse})
    assert entry(socket, "Glimpse of Flames")["scheduled"] == true
    html = render(socket)
    assert html =~ "F1+" and html =~ "list_remove_schedule"
    refute html =~ "list_add_schedule"

    socket = socket |> event("list_split", %{"entry" => glimpse, "floor" => "2"}) |> event("list_split", %{"entry" => glimpse, "floor" => "3"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 2, 3]

    socket = event(socket, "list_move_segment", %{"entry" => glimpse, "from" => "2", "to" => "8"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 3, 8]
    assert socket.assigns.entry_tabs[glimpse] == {nil, 8}
    html = render(socket)
    assert html =~ "F1-2" and html =~ "F3-7" and html =~ "F8+"

    socket = event(socket, "list_move_segment", %{"entry" => glimpse, "from" => "8", "to" => "3"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 3, 8]

    socket = socket |> event("list_remove_segment", %{"entry" => glimpse, "from" => "3"}) |> event("list_remove_segment", %{"entry" => glimpse, "from" => "8"})
    assert render(socket) =~ "list_remove_schedule"
    socket = event(socket, "list_remove_schedule", %{"entry" => glimpse})
    assert entry(socket, "Glimpse of Flames")["scheduled"] == false
    assert render(socket) =~ "list_add_schedule"
  end

  test "Buy and Sell are exclusive, patterns show a cap for either, and a tab can abandon the gift from its floor", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_tier", %{"tier" => "1"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    [_, t1] = section(socket)["entries"]
    seg = fn id -> Enum.find(section(socket)["entries"], &(&1["id"] == id))["floors"] end

    socket = event(socket, "list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "sell"})
    assert [%{"disposition" => "sell", "buy" => false}] = seg.(glimpse)
    socket = event(socket, "list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
    assert [%{"disposition" => "keep", "buy" => true}] = seg.(glimpse)
    socket = event(socket, "list_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
    assert [%{"disposition" => "keep", "buy" => false}] = seg.(glimpse)
    assert render(socket) =~ "Max per floor"

    socket = event(socket, "list_toggle", %{"entry" => t1["id"], "from" => "1", "field" => "buy"})
    refute render(socket) =~ "Max per floor"
    socket = event(socket, "list_toggle", %{"entry" => t1["id"], "from" => "1", "field" => "sell"})
    assert render(socket) =~ "Max per floor"

    socket = socket |> event("list_split", %{"entry" => glimpse, "floor" => "6"}) |> event("list_set_segment_mode", %{"entry" => glimpse, "from" => "6", "mode" => "abandon"})
    assert [%{"from" => 1}, %{"from" => 6, "abandoned" => true}] = seg.(glimpse)
    assert render(socket) =~ "Abandoned"
    socket = event(socket, "list_set_segment_mode", %{"entry" => glimpse, "from" => "6", "mode" => "change"})
    assert [_, %{"abandoned" => false}] = seg.(glimpse)
    refute render(socket) =~ "Abandoned"

    socket = event(socket, "list_set_segment_mode", %{"entry" => glimpse, "from" => "1", "mode" => "abandon"})
    assert [%{"from" => 1, "abandoned" => true}, _] = seg.(glimpse)
    assert render(socket) =~ "Not started"
    assert %{disposition: "keep"} = GiftPlans.resolve(Enum.find(section(socket)["entries"], &(&1["id"] == glimpse)), 6)

    socket = socket |> event("list_remove_segment", %{"entry" => glimpse, "from" => "6"}) |> event("list_remove_schedule", %{"entry" => glimpse})
    assert [%{"from" => 1, "abandoned" => false, "disposition" => "keep"}] = seg.(glimpse)
    refute render(socket) =~ "Not started"
  end

  test "dragging an entry into a schedule groups it, tab edits apply to the group, and dragging it out keeps a copy of the tabs", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_gift", %{"gift" => "Fiery Down"}) |> event("list_add_gift", %{"gift" => "Ing A"})
    [glimpse, fiery, ing] = Enum.map(["Glimpse of Flames", "Fiery Down", "Ing A"], &entry(socket, &1)["id"])
    ms_id = section(socket)["id"]
    order = fn socket -> Enum.map(section(socket)["entries"], & &1["id"]) end
    froms = fn socket, name -> Enum.map(entry(socket, name)["floors"], & &1["from"]) end

    socket =
      socket
      |> event("list_split", %{"entry" => glimpse, "floor" => "5"})
      |> event("list_toggle", %{"entry" => fiery, "from" => "1", "field" => "buy"})
      |> event("list_move_entry", %{"scope" => "group:#{glimpse}", "from" => ms_id, "id" => fiery, "ids" => [glimpse, fiery]})

    group = entry(socket, "Glimpse of Flames")["group"]
    assert "grp_" <> _ = group
    assert %{"group" => ^group, "scheduled" => true, "floors" => [%{"from" => 1, "buy" => false}, %{"from" => 5}]} = entry(socket, "Fiery Down")
    assert [{:group, ^group, [_, _]}, {:single, _}] = Live.entry_chunks(section(socket)["entries"])

    socket = socket |> event("list_split", %{"entry" => fiery, "floor" => "8"}) |> event("list_set_segment_mode", %{"entry" => glimpse, "from" => "5", "mode" => "abandon"})
    assert froms.(socket, "Glimpse of Flames") == [1, 5, 8] and froms.(socket, "Fiery Down") == [1, 5, 8]
    assert Enum.all?([glimpse, fiery], fn id -> Enum.find(section(socket)["entries"], &(&1["id"] == id))["floors"] |> Enum.at(1) |> Map.get("abandoned") end)
    assert socket.assigns.entry_tabs[group] == {nil, 5}

    socket = event(socket, "list_reorder_entries", %{"scope" => "group:#{group}", "ids" => [fiery, glimpse]})
    assert order.(socket) == [fiery, glimpse, ing]
    socket = event(socket, "list_reorder_entries", %{"scope" => ms_id, "ids" => [ing, "group:#{group}"]})
    assert order.(socket) == [ing, fiery, glimpse]

    socket = event(socket, "list_move_entry", %{"scope" => ms_id, "from" => "group:#{group}", "id" => glimpse, "ids" => [ing, "group:#{group}", glimpse]})
    assert order.(socket) == [ing, fiery, glimpse]
    refute Map.has_key?(entry(socket, "Glimpse of Flames"), "group")
    assert froms.(socket, "Glimpse of Flames") == [1, 5, 8]
    assert [{:single, _}, {:group, ^group, [_]}, {:group, ^glimpse, [_]}] = Live.entry_chunks(section(socket)["entries"])

    socket = socket |> event("list_remove_segment", %{"entry" => fiery, "from" => "8"}) |> event("list_remove_segment", %{"entry" => fiery, "from" => "5"}) |> event("list_remove_schedule", %{"entry" => fiery})
    refute Map.has_key?(entry(socket, "Fiery Down"), "group")
    assert render(socket) =~ ~s(data-sort-id="group:#{glimpse}")
  end

  test "the goal dropdown can abandon an entry, and picking a goal or Change at brings back its last goal", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_goal", %{})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    update = fn socket, goal -> event(socket, "list_update_segment", %{"entry" => glimpse, "from" => "1", "segment" => %{"goal" => goal}}) end

    socket = socket |> update.("A") |> update.("abandon")
    assert [%{"goal" => "A", "abandoned" => true}] = entry(socket, "Glimpse of Flames")["floors"]
    html = render(socket)
    assert html =~ "Not started" and html =~ ~s(<option value="abandon" selected)

    socket = event(socket, "list_set_segment_mode", %{"entry" => glimpse, "from" => "1", "mode" => "change"})
    assert [%{"goal" => "A", "abandoned" => false}] = entry(socket, "Glimpse of Flames")["floors"]

    socket = socket |> update.("abandon") |> update.("optional")
    assert [%{"goal" => "optional", "abandoned" => false}] = entry(socket, "Glimpse of Flames")["floors"]
  end

  test "heal entries pick sinners and a repeat mode per floor, and never take goals or Buy/Sell", %{socket: socket} do
    [first, second | _] = StarlightBot.Teams.all_sinners()

    socket =
      socket
      |> shop()
      |> event("list_add_action", %{"action" => "heal", "sinner" => second})
      |> event("list_add_action", %{"action" => "revive", "sinner" => first})
      |> event("list_add_action", %{"action" => "heal_all"})

    [heal, revive, all] = section(socket)["entries"]
    assert %{"subject" => %{"action" => "heal"}, "floors" => [%{"sinners" => [^second], "repeat" => "once", "buy" => false}]} = heal
    assert %{"floors" => [%{"sinners" => [^first]}]} = revive
    assert %{"floors" => [%{"sinners" => []}]} = all

    socket =
      socket
      |> event("list_toggle_heal_sinner", %{"entry" => heal["id"], "from" => "1", "sinner" => first})
      |> event("list_set_heal_repeat", %{"entry" => heal["id"], "from" => "1", "repeat" => "until_full"})

    assert [%{"sinners" => [^first, ^second], "repeat" => "until_full"}] = hd(section(socket)["entries"])["floors"]
    assert %{disposition: "ignore", buy: false, goal: nil, sinners: [^first, ^second], repeat: "until_full"} = GiftPlans.resolve(hd(section(socket)["entries"]), 1)

    socket = socket |> event("list_toggle_heal_sinner", %{"entry" => revive["id"], "from" => "1", "sinner" => second}) |> event("list_set_heal_repeat", %{"entry" => all["id"], "from" => "1", "repeat" => "3"})
    assert [%{"repeat" => "3"}] = List.last(section(socket)["entries"])["floors"]

    html = render(socket)
    assert html =~ "Greatly Heal" and html =~ "Heal Everyone" and html =~ "Until healed" and html =~ "Until all healed"
    assert html =~ "Cost 200-400" and html =~ "Cost 200" and html =~ "Cost 300"
    refute html =~ ~s(phx-value-field="sell")
    assert GiftPlans.keep_set(saved(socket), 1) == MapSet.new()
  end

  test "skill replace entries pick sinners, a goal and a wanted skill distribution", %{socket: socket} do
    [first | _] = StarlightBot.Teams.all_sinners()
    socket = socket |> shop() |> event("list_add_action", %{"action" => "skill_replace", "sinner" => first})
    [replace] = section(socket)["entries"]
    assert [%{"sinners" => [^first], "goal" => "optional", "target" => %{"s1" => 1, "s2" => 2, "s3" => 3}}] = replace["floors"]
    assert render(socket) =~ "Skill Replace" and render(socket) =~ "Cost 240"

    socket = event(socket, "list_update_segment", %{"entry" => replace["id"], "from" => "1", "segment" => %{"goal" => "optional"}})
    id = replace["id"]
    socket = socket |> event("list_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s1", "delta" => "-1"}) |> event("list_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s2", "delta" => "5"}) |> event("list_toggle_skill_lock", %{"entry" => id, "from" => "1"})
    assert [%{"goal" => "optional", "lock_s2" => false, "target" => %{"s1" => 0, "s2" => 5, "s3" => 1}}] = hd(section(socket)["entries"])["floors"]
    socket = event(socket, "list_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s1", "delta" => "3"})
    assert [%{"target" => %{"s1" => 3, "s2" => 2, "s3" => 1}}] = hd(section(socket)["entries"])["floors"]
    assert GiftPlans.heal_entries(GiftPlans.resolved_entries(section(socket), 1)) == []
    assert [%{goal: "optional", lock_s2: false, target: %{"s1" => 3, "s2" => 2, "s3" => 1}}] = GiftPlans.skill_replace_entries(GiftPlans.resolved_entries(section(socket), 1))
  end

  test "team replace is a single action entry that holds at most three sinners, each with an identity", %{socket: socket} do
    [a, b, c, d | _] = StarlightBot.Teams.all_sinners()
    socket = socket |> shop() |> event("list_add_action", %{"action" => "team_replace"}) |> event("list_add_action", %{"action" => "team_replace"})
    [entry] = section(socket)["entries"]
    id = entry["id"]
    toggle = fn socket, sinner -> event(socket, "list_toggle_team_replace", %{"entry" => id, "from" => "1", "sinner" => sinner}) end
    replacements = fn socket -> hd(hd(section(socket)["entries"])["floors"])["replacements"] end

    socket = socket |> toggle.(a) |> toggle.(b) |> toggle.(c) |> toggle.(d)
    assert Enum.map(replacements.(socket), & &1["sinner"]) == [a, b, c]

    socket = toggle.(socket, b)
    assert Enum.map(replacements.(socket), & &1["sinner"]) == [a, c]

    socket = event(socket, "list_update_segment", %{"entry" => id, "from" => "1", "segment" => %{"team_profile" => %{a => "12", c => ""}}})
    assert [%{"sinner" => ^a, "profile" => 12}, %{"sinner" => ^c, "profile" => nil}] = replacements.(socket)

    assert [%{replacements: [%{"sinner" => ^a, "profile" => 12} | _]}] = GiftPlans.team_replace_entries(GiftPlans.resolved_entries(section(socket), 1))
    assert GiftPlans.heal_entries(GiftPlans.resolved_entries(section(socket), 1)) == []
    assert render(socket) =~ "Team Replace" and render(socket) =~ "Pick an identity"
  end

  test "locking S2 keeps its target at or above the starting 2", %{socket: socket} do
    [first | _] = StarlightBot.Teams.all_sinners()
    socket = socket |> shop() |> event("list_add_action", %{"action" => "skill_replace", "sinner" => first})
    [%{"id" => id}] = section(socket)["entries"]
    step = fn socket, key, delta -> event(socket, "list_step_skill_target", %{"entry" => id, "from" => "1", "key" => key, "delta" => delta}) end

    socket = step.(socket, "s2", "-5")
    assert %{"s2" => 2} = hd(hd(section(socket)["entries"])["floors"])["target"]

    socket = socket |> event("list_toggle_skill_lock", %{"entry" => id, "from" => "1"}) |> step.("s2", "-5")
    assert %{"s2" => 0, "s3" => 5} = hd(hd(section(socket)["entries"])["floors"])["target"]

    socket = event(socket, "list_toggle_skill_lock", %{"entry" => id, "from" => "1"})
    assert %{"s2" => 2} = hd(hd(section(socket)["entries"])["floors"])["target"]
  end

  test "refresh cost grid follows the cases and lets the path branch", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_refresh_case", %{}) |> event("list_add_refresh_case", %{})
    [first, second] = section(socket)["refresh"]
    path_total = fn socket ->
      ~r/<td class="text-center font-semibold"><span[^>]*>\s*(\d*)\s*<img/ |> Regex.scan(render(socket), capture: :all_but_first) |> List.flatten() |> Enum.reject(&(&1 == "")) |> List.last() |> String.to_integer()
    end

    socket =
      socket
      |> event("list_update_refresh_case", %{"case_id" => first["id"], "action" => "refresh", "max" => "2"})
      |> event("list_update_refresh_case", %{"case_id" => second["id"], "action" => "affinity_refresh", "affinity" => "", "max" => "1"})

    assert path_total.(socket) == 150

    socket = event(socket, "rf_pick", %{"step" => "0", "kind" => "normal"})
    assert path_total.(socket) == 0

    socket = event(socket, "rf_pick", %{"step" => "1", "kind" => "keyword"})
    assert path_total.(socket) == 105

    socket = event(socket, "rf_reset", %{})
    assert path_total.(socket) == 150
  end

  test "refresh cases read like a case statement: each gets a condition and an action, and they reorder and delete", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_refresh_case", %{}) |> event("list_add_refresh_case", %{})
    [first, second] = section(socket)["refresh"]
    assert %{"condition" => nil, "action" => "refresh"} = first

    socket =
      socket
      |> event("cond_add", %{"case_id" => first["id"], "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"case_id" => first["id"], "path" => "", "op" => "refreshes", "cmp" => "lte", "value" => "3", "not" => "true"})
      |> event("list_update_refresh_case", %{"case_id" => first["id"], "action" => "affinity_refresh", "affinity" => "burn"})
      |> event("list_update_refresh_case", %{"case_id" => second["id"], "action" => "leave"})

    assert [%{"condition" => %{"op" => "refreshes", "cmp" => "lte", "value" => 3, "not" => true}, "action" => "affinity_refresh", "affinity" => "burn"}, %{"action" => "leave", "condition" => nil}] =
             section(socket)["refresh"]

    html = render(socket)
    assert html =~ "else if" and html =~ "leave the shop" and html =~ ~s(value="leave" checked)

    socket = event(socket, "list_reorder_refresh", %{"scope" => section(socket)["id"], "ids" => [second["id"], first["id"]]})
    assert Enum.map(section(socket)["refresh"], & &1["id"]) == [second["id"], first["id"]]

    socket = event(socket, "list_remove_refresh_case", %{"case_id" => second["id"]})
    assert [%{"id" => id}] = section(socket)["refresh"]
    assert id == first["id"]
  end

  test "a refresh case needs the cost left after refreshing to reach its minimum", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_refresh_case", %{})
    [refresh_case] = section(socket)["refresh"]
    assert refresh_case["min_cost"] == 250

    env = %{wallet: 400, refresh_costs: %{"refresh" => 200}}
    refute GiftPlans.matching_refresh_case(section(socket), env)

    socket = event(socket, "list_update_refresh_case", %{"case_id" => refresh_case["id"], "action" => "refresh", "max" => "", "min_cost" => "200"})
    assert GiftPlans.matching_refresh_case(section(socket), env)

    socket = event(socket, "list_update_refresh_case", %{"case_id" => refresh_case["id"], "action" => "refresh", "max" => "", "min_cost" => "0"})
    assert GiftPlans.matching_refresh_case(section(socket), %{wallet: 10, refresh_costs: %{"refresh" => 200}})
  end

  test "refresh cases can be scheduled by floor and the matching case follows the shop floor", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_refresh_case", %{}) |> event("list_refresh_add_schedule", %{})
    [base] = section(socket)["refresh"]
    assert section(socket)["refresh_scheduled"]

    socket = socket |> event("list_refresh_split", %{"floor" => "5"}) |> event("list_add_refresh_case", %{})
    [%{"from" => 5, "cases" => [copied, added]}] = section(socket)["refresh_floors"]
    assert copied["id"] != base["id"]
    assert [^base] = section(socket)["refresh"]

    socket = event(socket, "list_update_refresh_case", %{"case_id" => added["id"], "action" => "leave"})
    assert render(socket) =~ "F1-4" and render(socket) =~ "F5+"

    assert %{"action" => "refresh"} = GiftPlans.matching_refresh_case(section(socket), %{floor: 4, wallet: 1000})
    assert %{"id" => id} = GiftPlans.matching_refresh_case(section(socket), %{floor: 5, wallet: 1000})
    assert id == copied["id"]

    socket = event(socket, "list_refresh_move_segment", %{"from" => "5", "to" => "7"})
    assert [%{"from" => 7}] = section(socket)["refresh_floors"]

    socket = event(socket, "list_refresh_remove_segment", %{"from" => "7"})
    assert section(socket)["refresh_floors"] == []

    socket = event(socket, "list_refresh_remove_schedule", %{})
    refute section(socket)["refresh_scheduled"]
  end

  test "turning Fuse on for an entry without a fusion gives it the default one, and unfusable gifts can't", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Fixed Thing"})
    ing_a = entry(socket, "Ing A")["id"]
    socket = event(socket, "list_update_segment", %{"entry" => ing_a, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "required"}})
    socket = event(socket, "list_add_gift", %{"gift" => "Fiery Down"})
    fiery = entry(socket, "Fiery Down")["id"]
    socket = update_in(socket.assigns.plan_data["sections"], fn [m] -> [Map.update!(m, "entries", &Enum.map(&1, fn e -> if e["id"] == fiery, do: %{e | "fusion" => nil}, else: e end))] end)

    socket = event(socket, "list_toggle", %{"entry" => fiery, "from" => "1", "field" => "fuse"})
    assert %{"fusion" => %{"type" => "tiered", "routes" => [_, _]}, "floors" => [%{"fuse" => true}]} = entry(socket, "Fiery Down")

    html = render(socket)
    assert html =~ "This gift can&#39;t be fused"
  end

  test "goals live at the top of the section and entries pick one", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_goal", %{}) |> event("list_set_goal_min", %{"letter" => "A", "min" => "2"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    socket = event(socket, "list_update_segment", %{"entry" => glimpse, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "A"}})

    assert section(socket)["goals"] == [%{"letter" => "A", "min" => 2}]
    assert [%{"goal" => "A"}] = entry(socket, "Glimpse of Flames")["floors"]
    assert render(socket) =~ "at least"

    socket = event(socket, "list_remove_goal", %{"letter" => "A"})
    assert section(socket)["goals"] == []
    assert [%{"goal" => "required"}] = entry(socket, "Glimpse of Flames")["floors"]
  end

  test "a stage takes its own goals and entries, new gifts go to the picked section, and entry edits follow the entry", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_stage", %{})
    [_, stage] = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
    socket = event(socket, "rename_stage", %{"id" => stage["id"], "value" => " Late game "})
    assert GiftPlans.find_section(socket.assigns.plan_data, stage["id"])["name"] == "Late game"
    socket = event(socket, "rename_stage", %{"id" => stage["id"], "value" => " "})
    assert GiftPlans.find_section(socket.assigns.plan_data, stage["id"])["name"] == "Late game"
    assert [%{"id" => root_only}] = GiftPlans.roots(socket.assigns.plan_data)
    assert root_only == socket.assigns.root_section_id

    socket = socket |> event("list_add_gift", %{"gift" => "Fiery Down"}) |> event("list_add_goal", %{"section" => stage["id"]}) |> event("list_set_goal_min", %{"letter" => "A", "min" => "2", "section" => stage["id"]})
    [root, stage] = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
    assert Enum.map(root["entries"], &GiftPlans.subject_gift/1) == ["Glimpse of Flames"]
    assert Enum.map(stage["entries"], &GiftPlans.subject_gift/1) == ["Fiery Down"]
    assert root["goals"] == []
    assert stage["goals"] == [%{"letter" => "A", "min" => 2}]

    fiery = hd(stage["entries"])["id"]
    socket = event(socket, "list_update_segment", %{"entry" => fiery, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "A"}})
    [_, stage] = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
    assert [%{"goal" => "A"}] = hd(stage["entries"])["floors"]

    socket = event(socket, "list_remove_stage", %{"id" => stage["id"]})
    assert [_] = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
  end

  test "dragging an entry between a section and its stages moves it, resets goals the target lacks and keeps the dropped order", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_stage", %{}) |> event("list_add_gift", %{"gift" => "Fiery Down"})
    root_id = socket.assigns.root_section_id
    [_, stage] = GiftPlans.sections(socket.assigns.plan_data, root_id)
    socket = event(socket, "list_add_goal", %{"section" => stage["id"]})
    fiery = hd(GiftPlans.find_section(socket.assigns.plan_data, stage["id"])["entries"])["id"]
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    socket = event(socket, "list_update_segment", %{"entry" => fiery, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "A"}})

    socket = event(socket, "list_move_entry", %{"scope" => root_id, "from" => stage["id"], "id" => fiery, "ids" => [fiery, glimpse]})
    [root, stage_after] = GiftPlans.sections(socket.assigns.plan_data, root_id)
    assert Enum.map(root["entries"], & &1["id"]) == [fiery, glimpse]
    assert stage_after["entries"] == []
    assert [%{"goal" => "required"}] = hd(root["entries"])["floors"]

    socket = event(socket, "list_move_entry", %{"scope" => stage["id"], "from" => root_id, "id" => glimpse, "ids" => [glimpse]})
    [root, stage_after] = GiftPlans.sections(socket.assigns.plan_data, root_id)
    assert Enum.map(root["entries"], & &1["id"]) == [fiery]
    assert Enum.map(stage_after["entries"], & &1["id"]) == [glimpse]
  end

  test "the Add button goes to the last stage, a drop can target any stage, and the same gift can sit in several stages", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_stage", %{}) |> event("list_add_stage", %{}) |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})
    root_id = socket.assigns.root_section_id
    [root, second, third] = GiftPlans.sections(socket.assigns.plan_data, root_id)
    assert {root["entries"], second["entries"]} == {[], []}
    assert [%{"subject" => %{"gift" => "Glimpse of Flames"}}] = third["entries"]

    html = render(socket)
    assert html =~ ~s(phx-click="list_add_gift" phx-value-gift="Fiery Down")
    assert Regex.run(~r/data-added="([^"]*)"/, html) |> List.last() =~ "Glimpse of Flames"

    socket = socket |> event("list_add_gift", %{"gift" => "Glimpse of Flames", "section" => root_id}) |> event("list_add_gift", %{"gift" => "Glimpse of Flames", "section" => root_id})
    [root, _second, third] = GiftPlans.sections(socket.assigns.plan_data, root_id)
    assert length(root["entries"]) == 1
    assert length(third["entries"]) == 1
  end

  test "heal entries always join the section itself, even with a stage picked", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_stage", %{}) |> event("list_add_action", %{"action" => "heal_all", "sinner" => ""})
    [root, stage] = GiftPlans.sections(socket.assigns.plan_data, socket.assigns.root_section_id)
    assert Enum.count(root["entries"], &GiftPlans.heal_entry?/1) == 1
    assert stage["entries"] == []
  end

  test "any-tier and any-affinity entries can only ignore or sell", %{socket: socket} do
    socket =
      socket
      |> shop()
      |> event("list_add_tier", %{"tier" => "1"})
      |> event("list_add_affinity", %{"affinity" => "burn", "tier" => "3"})
      |> event("list_add_affinity", %{"affinity" => "burn", "tier" => "3"})

    assert Enum.map(section(socket)["entries"], & &1["subject"]) == [%{"tiers" => [1]}, %{"affinity" => "burn", "tiers" => [3]}]
    html = render(socket)
    assert html =~ "Any T1" and html =~ "Any burn T3"
    refute html =~ ~s(<option value="keep")
  end

  test "the fusion popup edits an entry's routes, which copy, paste and become tier defaults", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("list_add_gift", %{"gift" => "Ing A"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    ing_a = entry(socket, "Ing A")["id"]
    [top_332, top_422] = entry(socket, "Glimpse of Flames")["fusion"]["routes"]

    socket =
      socket
      |> event("list_open_fusion", %{"entry" => glimpse})
      |> event("rt_add", %{"def_id" => glimpse, "parent" => "", "tier" => "4", "combo" => "4-4"})
      |> event("rt_update", %{"def_id" => glimpse, "route_id" => top_422["id"], "buy_up_to" => "2", "leftover" => %{"1" => "0", "2" => "1"}})
      |> event("rt_add", %{"def_id" => glimpse, "parent" => top_422["id"], "tier" => "2", "combo" => "2-2"})
      |> event("rt_duplicate", %{"def_id" => glimpse, "route_id" => top_332["id"]})

    [first, copy, edited, added] = entry(socket, "Glimpse of Flames")["fusion"]["routes"]
    assert first["combo"] == [3, 3, 2] and copy["combo"] == [3, 3, 2] and copy["id"] != first["id"]
    assert edited["buy_up_to"] == 2 and edited["leftover"] == %{"2" => 1}
    assert [%{"combo" => [2, 2]}] = edited["subgoals"]["2"]
    assert added["combo"] == [4, 4]

    html = render(socket)
    assert html =~ "modal-open" and html =~ "Sub-goal: make T3s" and html =~ "+ add T2 route"

    socket = event(socket, "rt_reorder", %{"scope" => "#{glimpse}||4", "ids" => [added["id"], first["id"]]})
    assert Enum.map(entry(socket, "Glimpse of Flames")["fusion"]["routes"], & &1["id"]) == [added["id"], copy["id"], edited["id"], first["id"]]

    socket = event(socket, "rt_delete", %{"def_id" => glimpse, "route_id" => copy["id"]})
    socket = socket |> event("rt_copy", %{"def_id" => glimpse}) |> event("rt_save_template", %{"def_id" => glimpse, "name" => "Mine"})
    assert socket.assigns.route_clipboard.tier == 4
    [%{ref: ref, name: "Mine"}] = socket.assigns.route_templates[4]

    socket = event(socket, "rt_apply_template", %{"def_id" => glimpse, "ref" => ref})
    assert Enum.map(entry(socket, "Glimpse of Flames")["fusion"]["routes"], & &1["combo"]) == [[4, 4], [4, 2, 2], [3, 3, 2]]

    socket = socket |> event("list_close_fusion", %{}) |> event("list_open_fusion", %{"entry" => ing_a})
    assert [%{"combo" => [2, 1, 1], "buy_up_to" => 1}, %{"combo" => [1, 1, 1, 1]}] = entry(socket, "Ing A")["fusion"]["routes"]
    socket = event(socket, "rt_add", %{"def_id" => ing_a, "parent" => "", "tier" => "2", "combo" => "2-2"})
    assert [_, _, %{"combo" => [2, 2]}] = entry(socket, "Ing A")["fusion"]["routes"]
    refute render(event(socket, "list_close_fusion", %{})) =~ "Fuse (tiered)"
  end

  test "a fixed fusion's popup shows its recipe and which ingredients the section lacks", %{socket: socket} do
    socket = socket |> shop() |> event("list_add_gift", %{"gift" => "Fixed Thing"})
    socket = event(socket, "list_remove_entry", %{"entry" => entry(socket, "Ing A")["id"]})
    html = render(event(socket, "list_open_fusion", %{"entry" => entry(socket, "Fixed Thing")["id"]}))

    assert html =~ "Fixed recipe."
    assert html =~ "(not in this stage)"
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

  test "keep shopping adds a section and removing it turns the flag off", %{socket: socket} do
    flag = fn socket -> hd(saved(socket)["sections"])["pursue_optional"] end
    socket = shop(socket)
    refute flag.(socket)
    assert render(socket) =~ "+ Keep shopping"
    refute render(socket) =~ "Keep shopping</span>"

    socket = event(socket, "list_set_pursue_optional", %{"value" => "true"})
    assert flag.(socket)
    assert render(socket) =~ "Keep shopping</span>"
    refute render(socket) =~ "+ Keep shopping"

    socket = event(socket, "list_set_pursue_optional", %{"value" => "false"})
    refute flag.(socket)
    refute render(socket) =~ "Keep shopping</span>"
  end

  describe "starter packs" do
    setup %{socket: socket} do
      BaseRepo.query!("DELETE FROM gift_starter_packs")
      Repo.query!("DELETE FROM gift_starter_packs")
      socket = socket |> shop() |> event("pack_new", %{})
      socket = socket |> event("list_add_gift", %{"gift" => "Fiery Down"}) |> event("list_add_gift", %{"gift" => "Glimpse of Flames"})
      ref = socket.assigns.pack_edit.ref
      socket = event(socket, "pack_close", %{})
      %{socket: socket, ref: ref}
    end

    test "creating a pack opens it for editing and closing restores the plan", %{socket: socket, ref: ref} do
      assert socket.assigns.pack_edit == nil
      assert socket.assigns.plan_data["sections"] |> hd() |> Map.fetch!("entries") == []
      assert StarlightBot.GiftStarterPacks.get(ref).data["sections"] |> hd() |> Map.fetch!("entries") |> length() == 2
      assert saved(socket)["sections"] |> hd() |> Map.fetch!("entries") == []
    end

    test "adding a pack stores only a reference and shows its entries read-only", %{socket: socket, ref: ref} do
      socket = socket |> event("pack_select", %{"ref" => ref}) |> event("pack_add", %{})

      assert [%{"ref" => ^ref}] = section(socket)["packs"]
      assert section(socket)["entries"] == []
      html = render(socket)
      assert html =~ "Starter pack"
      assert html =~ "Fiery Down"
      assert html =~ "Unpack"
    end

    test "a stage entry overrides the pack's entry and the pack row says so", %{socket: socket, ref: ref} do
      socket = socket |> event("pack_select", %{"ref" => ref}) |> event("pack_add", %{}) |> event("list_add_gift", %{"gift" => "Fiery Down"})

      assert render(socket) =~ "Overridden"
      assert length(GiftPlans.for_run(saved(socket), "all_normal")["sections"] |> hd() |> Map.fetch!("entries")) == 2
    end

    test "dragging a pack to another stage moves the reference", %{socket: socket, ref: ref} do
      socket = socket |> event("pack_select", %{"ref" => ref}) |> event("pack_add", %{}) |> event("list_add_stage", %{})
      [root, stage] = saved(socket)["sections"]
      [%{"id" => pack_id}] = root["packs"]
      socket = event(socket, "pack_move", %{"scope" => stage["id"], "from" => root["id"], "id" => pack_id, "ids" => [pack_id]})
      [root, stage] = saved(socket)["sections"]

      refute Map.has_key?(root, "packs")
      assert [%{"id" => ^pack_id, "ref" => ^ref}] = stage["packs"]
      assert render(socket) =~ "Starter pack"
    end

    test "unpacking copies the entries into the stage and drops the reference", %{socket: socket, ref: ref} do
      socket = socket |> event("pack_select", %{"ref" => ref}) |> event("pack_add", %{})
      [%{"id" => pack_id}] = section(socket)["packs"]
      socket = event(socket, "pack_unpack", %{"pack" => pack_id, "section" => section(socket)["id"]})

      refute Map.has_key?(section(socket), "packs")
      assert section(socket)["entries"] |> Enum.map(& &1["subject"]["gift"]) |> Enum.sort() == ["Fiery Down", "Glimpse of Flames"]
    end

    test "editing the pack changes every plan that uses it", %{socket: socket, ref: ref} do
      socket = socket |> event("pack_select", %{"ref" => ref}) |> event("pack_add", %{}) |> event("pack_edit", %{"ref" => ref})
      entry_id = socket.assigns.plan_data["sections"] |> hd() |> Map.fetch!("entries") |> hd() |> Map.fetch!("id")
      socket = socket |> event("list_remove_entry", %{"entry" => entry_id}) |> event("pack_close", %{})

      assert GiftPlans.for_run(saved(socket), "all_normal")["sections"] |> hd() |> Map.fetch!("entries") |> length() == 1
    end

    test "shipped packs are read-only for users and events against them are blocked", %{socket: socket, ref: ref} do
      original = Application.get_env(:starlight_bot, :data_paths)
      Application.put_env(:starlight_bot, :data_paths, %{original | mode: :user})
      StarlightBot.Data.reset_cache()
      on_exit(fn -> Application.put_env(:starlight_bot, :data_paths, original); StarlightBot.Data.reset_cache() end)

      socket = event(socket, "pack_edit", %{"ref" => ref})
      assert socket.assigns.pack_locked
      assert Live.plan_locked?(socket)
      assert render(socket) =~ "Read-only starter pack"

      socket = event(socket, "pack_close", %{})
      refute Live.plan_locked?(socket)
    end

    test "renaming a pack rejects a taken name", %{socket: socket, ref: ref} do
      {:ok, _other} = StarlightBot.GiftStarterPacks.create("Other", "any")
      socket = event(socket, "pack_edit", %{"ref" => ref})
      socket = event(socket, "pack_rename", %{"value" => "Other"})

      assert socket.assigns.flash["error"] =~ "already has that name"
      assert socket.assigns.pack_edit.name == "New starter pack"
    end
  end
end
