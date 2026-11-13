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

  defp milestone(socket), do: hd(saved(socket)["milestones"])
  defp entry(socket, name), do: Enum.find(milestone(socket)["entries"], &(GiftPlans.subject_gift(&1) == name))
  defp shop(socket), do: event(socket, "set_tab", %{"tab" => "shop"})

  test "a milestone copied to the clipboard pastes back as a separate milestone", %{socket: socket} do
    socket = event(socket, "ms_add_gift", %{"gift" => "Glimpse of Flames"})
    source = milestone(socket)
    text = StarlightBot.PlanClipboard.encode_milestone(source)
    socket = event(socket, "paste_milestone", %{"text" => text})
    [original, pasted] = saved(socket)["milestones"]
    assert original == source
    assert pasted["name"] == source["name"] <> " copy"
    assert socket.assigns.selected_milestone_id == pasted["id"]
    assert Enum.map(pasted["entries"], &GiftPlans.subject_gift/1) == ["Glimpse of Flames"]
    refute hd(pasted["entries"])["id"] == hd(source["entries"])["id"]

    socket = event(socket, "paste_milestone", %{"text" => "nope"})
    assert length(saved(socket)["milestones"]) == 2
    assert socket.assigns.flash["error"] =~ "doesn't hold a Starlight milestone"
  end

  test "a new plan starts as a valid v5 plan with the shop pane on its milestone", %{socket: socket} do
    assert saved(socket)["version"] == 5
    assert GiftPlans.issues(saved(socket)) == []
    assert socket.assigns.selected_milestone_id == milestone(socket)["id"]
    assert render(shop(socket)) =~ "No entries yet"

    for tab <- ~w(shop loadout) do
      assert is_binary(socket |> event("set_tab", %{"tab" => tab}) |> render())
    end
  end

  test "gifts join the milestone with keep and buy, fixed fusions bring their ingredients, and entry settings save per floor", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Fixed Thing"}) |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"})

    assert Enum.map(milestone(socket)["entries"], &GiftPlans.subject_gift/1) == ["Fixed Thing", "Ing A", "Ing B", "Glimpse of Flames"]
    assert %{"fusion" => %{"type" => "fixed"}, "floors" => [%{"fuse" => true, "buy" => true, "goal" => "required"}]} = entry(socket, "Fixed Thing")
    assert %{"fusion" => %{"type" => "tiered"}, "floors" => [%{"fuse" => false, "goal" => "optional"}]} = entry(socket, "Ing A")
    assert %{"fusion" => nil} = entry(socket, "Ing B")
    assert %{"fusion" => %{"type" => "tiered", "routes" => [_, _]}, "floors" => [%{"fuse" => true}]} = entry(socket, "Glimpse of Flames")

    html = render(socket)
    assert html =~ "Made from:" and html =~ "Added"
    assert html =~ ~s(phx-click="ms_add_gift" phx-value-gift="Fiery Down")
    refute html =~ ~s(phx-click="ms_add_gift" phx-value-gift="Glimpse of Flames")

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
      |> event("ms_set_uptie", %{"entry" => glimpse, "from" => "1", "level" => "2"})
      |> event("ms_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
      |> event("ms_split", %{"entry" => glimpse, "floor" => "5"})
      |> event("ms_update_segment", %{"entry" => glimpse, "from" => "5", "segment" => %{"disposition" => "sell", "max" => "2"}})

    assert [%{"from" => 1, "uptie" => 2, "buy" => false, "disposition" => "keep"}, %{"from" => 5, "disposition" => "sell", "max" => 2, "uptie" => 2}] =
             entry(socket, "Glimpse of Flames")["floors"]

    assert socket.assigns.entry_tabs[glimpse] == 5
    html = render(socket)
    assert html =~ "F1-4" and html =~ "F5+" and html =~ "Max per floor"

    socket = event(socket, "ms_select_tab", %{"entry" => glimpse, "from" => "1"})
    assert socket.assigns.entry_tabs[glimpse] == 1

    socket = event(socket, "ms_remove_segment", %{"entry" => glimpse, "from" => "5"})
    assert [%{"from" => 1}] = entry(socket, "Glimpse of Flames")["floors"]

    ing_b = entry(socket, "Ing B")["id"]
    socket = event(socket, "ms_remove_entry", %{"entry" => ing_b})
    assert Enum.any?(GiftPlans.issues(saved(socket), socket.assigns.gifts_by_name), &(&1 =~ "Fixed Thing needs Ing B in the milestone."))
    assert render(socket) =~ "Fixed Thing needs Ing B in the milestone."

    ids = milestone(socket)["entries"] |> Enum.map(& &1["id"]) |> Enum.reverse()
    socket = event(socket, "ms_reorder_entries", %{"scope" => milestone(socket)["id"], "ids" => ids})
    assert Enum.map(milestone(socket)["entries"], & &1["id"]) == ids
  end

  test "Add Schedule shows floor tabs, new tabs start after the last one, and a tab's start floor can move to any free floor", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    assert render(socket) =~ "ms_add_schedule"

    socket = event(socket, "ms_add_schedule", %{"entry" => glimpse})
    assert entry(socket, "Glimpse of Flames")["scheduled"] == true
    html = render(socket)
    assert html =~ "F1+" and html =~ "ms_remove_schedule"
    refute html =~ "ms_add_schedule"

    socket = socket |> event("ms_split", %{"entry" => glimpse, "floor" => "2"}) |> event("ms_split", %{"entry" => glimpse, "floor" => "3"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 2, 3]

    socket = event(socket, "ms_move_segment", %{"entry" => glimpse, "from" => "2", "to" => "8"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 3, 8]
    assert socket.assigns.entry_tabs[glimpse] == 8
    html = render(socket)
    assert html =~ "F1-2" and html =~ "F3-7" and html =~ "F8+"

    socket = event(socket, "ms_move_segment", %{"entry" => glimpse, "from" => "8", "to" => "3"})
    assert Enum.map(entry(socket, "Glimpse of Flames")["floors"], & &1["from"]) == [1, 3, 8]

    socket = socket |> event("ms_remove_segment", %{"entry" => glimpse, "from" => "3"}) |> event("ms_remove_segment", %{"entry" => glimpse, "from" => "8"})
    assert render(socket) =~ "ms_remove_schedule"
    socket = event(socket, "ms_remove_schedule", %{"entry" => glimpse})
    assert entry(socket, "Glimpse of Flames")["scheduled"] == false
    assert render(socket) =~ "ms_add_schedule"
  end

  test "Buy and Sell are exclusive, patterns show a cap for either, and a tab can abandon the gift from its floor", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("ms_add_tier", %{"tier" => "1"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    [_, t1] = milestone(socket)["entries"]
    seg = fn id -> Enum.find(milestone(socket)["entries"], &(&1["id"] == id))["floors"] end

    socket = event(socket, "ms_toggle", %{"entry" => glimpse, "from" => "1", "field" => "sell"})
    assert [%{"disposition" => "sell", "buy" => false}] = seg.(glimpse)
    socket = event(socket, "ms_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
    assert [%{"disposition" => "keep", "buy" => true}] = seg.(glimpse)
    socket = event(socket, "ms_toggle", %{"entry" => glimpse, "from" => "1", "field" => "buy"})
    assert [%{"disposition" => "keep", "buy" => false}] = seg.(glimpse)
    assert render(socket) =~ "Max per floor"

    socket = event(socket, "ms_toggle", %{"entry" => t1["id"], "from" => "1", "field" => "buy"})
    refute render(socket) =~ "Max per floor"
    socket = event(socket, "ms_toggle", %{"entry" => t1["id"], "from" => "1", "field" => "sell"})
    assert render(socket) =~ "Max per floor"

    socket = socket |> event("ms_split", %{"entry" => glimpse, "floor" => "6"}) |> event("ms_set_segment_mode", %{"entry" => glimpse, "from" => "6", "mode" => "abandon"})
    assert [%{"from" => 1}, %{"from" => 6, "abandoned" => true}] = seg.(glimpse)
    assert render(socket) =~ "Abandoned"
    socket = event(socket, "ms_set_segment_mode", %{"entry" => glimpse, "from" => "6", "mode" => "change"})
    assert [_, %{"abandoned" => false}] = seg.(glimpse)
    refute render(socket) =~ "Abandoned"

    socket = event(socket, "ms_set_segment_mode", %{"entry" => glimpse, "from" => "1", "mode" => "abandon"})
    assert [%{"from" => 1, "abandoned" => true}, _] = seg.(glimpse)
    assert render(socket) =~ "Not started"
    assert %{disposition: "keep"} = GiftPlans.resolve(Enum.find(milestone(socket)["entries"], &(&1["id"] == glimpse)), 6)

    socket = socket |> event("ms_remove_segment", %{"entry" => glimpse, "from" => "6"}) |> event("ms_remove_schedule", %{"entry" => glimpse})
    assert [%{"from" => 1, "abandoned" => false, "disposition" => "keep"}] = seg.(glimpse)
    refute render(socket) =~ "Not started"
  end

  test "a new milestone opens its name for editing, and renaming commits a trimmed, non-blank name", %{socket: socket} do
    socket = socket |> shop() |> event("add_milestone", %{})
    [_, added] = saved(socket)["milestones"]
    assert socket.assigns.editing_milestone_id == added["id"]
    assert render(socket) =~ ~s(phx-hook="FocusSelect")

    socket = event(socket, "rename_milestone", %{"id" => added["id"], "value" => "  Late Shop "})
    assert socket.assigns.editing_milestone_id == nil
    assert Enum.at(saved(socket)["milestones"], 1)["name"] == "Late Shop"

    socket = socket |> event("edit_milestone_name", %{"id" => added["id"]}) |> event("rename_milestone", %{"id" => added["id"], "value" => " "})
    assert Enum.at(saved(socket)["milestones"], 1)["name"] == "Late Shop"
  end

  test "dragging an entry into a schedule groups it, tab edits apply to the group, and dragging it out keeps a copy of the tabs", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("ms_add_gift", %{"gift" => "Fiery Down"}) |> event("ms_add_gift", %{"gift" => "Ing A"})
    [glimpse, fiery, ing] = Enum.map(["Glimpse of Flames", "Fiery Down", "Ing A"], &entry(socket, &1)["id"])
    ms_id = milestone(socket)["id"]
    order = fn socket -> Enum.map(milestone(socket)["entries"], & &1["id"]) end
    froms = fn socket, name -> Enum.map(entry(socket, name)["floors"], & &1["from"]) end

    socket =
      socket
      |> event("ms_split", %{"entry" => glimpse, "floor" => "5"})
      |> event("ms_toggle", %{"entry" => fiery, "from" => "1", "field" => "buy"})
      |> event("ms_move_entry", %{"scope" => "group:#{glimpse}", "from" => ms_id, "id" => fiery, "ids" => [glimpse, fiery]})

    group = entry(socket, "Glimpse of Flames")["group"]
    assert "grp_" <> _ = group
    assert %{"group" => ^group, "scheduled" => true, "floors" => [%{"from" => 1, "buy" => false}, %{"from" => 5}]} = entry(socket, "Fiery Down")
    assert [{:group, ^group, [_, _]}, {:single, _}] = Live.entry_chunks(milestone(socket)["entries"])

    socket = socket |> event("ms_split", %{"entry" => fiery, "floor" => "8"}) |> event("ms_set_segment_mode", %{"entry" => glimpse, "from" => "5", "mode" => "abandon"})
    assert froms.(socket, "Glimpse of Flames") == [1, 5, 8] and froms.(socket, "Fiery Down") == [1, 5, 8]
    assert Enum.all?([glimpse, fiery], fn id -> Enum.find(milestone(socket)["entries"], &(&1["id"] == id))["floors"] |> Enum.at(1) |> Map.get("abandoned") end)
    assert socket.assigns.entry_tabs[group] == 5

    socket = event(socket, "ms_reorder_entries", %{"scope" => "group:#{group}", "ids" => [fiery, glimpse]})
    assert order.(socket) == [fiery, glimpse, ing]
    socket = event(socket, "ms_reorder_entries", %{"scope" => ms_id, "ids" => [ing, "group:#{group}"]})
    assert order.(socket) == [ing, fiery, glimpse]

    socket = event(socket, "ms_move_entry", %{"scope" => ms_id, "from" => "group:#{group}", "id" => glimpse, "ids" => [ing, "group:#{group}", glimpse]})
    assert order.(socket) == [ing, fiery, glimpse]
    refute Map.has_key?(entry(socket, "Glimpse of Flames"), "group")
    assert froms.(socket, "Glimpse of Flames") == [1, 5, 8]
    assert [{:single, _}, {:group, ^group, [_]}, {:group, ^glimpse, [_]}] = Live.entry_chunks(milestone(socket)["entries"])

    socket = socket |> event("ms_remove_segment", %{"entry" => fiery, "from" => "8"}) |> event("ms_remove_segment", %{"entry" => fiery, "from" => "5"}) |> event("ms_remove_schedule", %{"entry" => fiery})
    refute Map.has_key?(entry(socket, "Fiery Down"), "group")
    assert render(socket) =~ ~s(data-sort-id="group:#{glimpse}")
  end

  test "the goal dropdown can abandon an entry, and picking a goal or Change at brings back its last goal", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("ms_add_goal", %{})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    update = fn socket, goal -> event(socket, "ms_update_segment", %{"entry" => glimpse, "from" => "1", "segment" => %{"goal" => goal}}) end

    socket = socket |> update.("A") |> update.("abandon")
    assert [%{"goal" => "A", "abandoned" => true}] = entry(socket, "Glimpse of Flames")["floors"]
    html = render(socket)
    assert html =~ "Not started" and html =~ ~s(<option value="abandon" selected)

    socket = event(socket, "ms_set_segment_mode", %{"entry" => glimpse, "from" => "1", "mode" => "change"})
    assert [%{"goal" => "A", "abandoned" => false}] = entry(socket, "Glimpse of Flames")["floors"]

    socket = socket |> update.("abandon") |> update.("optional")
    assert [%{"goal" => "optional", "abandoned" => false}] = entry(socket, "Glimpse of Flames")["floors"]
  end

  test "heal entries pick sinners and a repeat mode per floor, and never take goals or Buy/Sell", %{socket: socket} do
    [first, second | _] = StarlightBot.Teams.all_sinners()

    socket =
      socket
      |> shop()
      |> event("ms_add_action", %{"action" => "heal", "sinner" => second})
      |> event("ms_add_action", %{"action" => "revive", "sinner" => first})
      |> event("ms_add_action", %{"action" => "heal_all"})

    [heal, revive, all] = milestone(socket)["entries"]
    assert %{"subject" => %{"action" => "heal"}, "floors" => [%{"sinners" => [^second], "repeat" => "once", "buy" => false}]} = heal
    assert %{"floors" => [%{"sinners" => [^first]}]} = revive
    assert %{"floors" => [%{"sinners" => []}]} = all

    socket =
      socket
      |> event("ms_toggle_heal_sinner", %{"entry" => heal["id"], "from" => "1", "sinner" => first})
      |> event("ms_set_heal_repeat", %{"entry" => heal["id"], "from" => "1", "repeat" => "until_full"})

    assert [%{"sinners" => [^first, ^second], "repeat" => "until_full"}] = hd(milestone(socket)["entries"])["floors"]
    assert %{disposition: "ignore", buy: false, goal: nil, sinners: [^first, ^second], repeat: "until_full"} = GiftPlans.resolve(hd(milestone(socket)["entries"]), 1)

    socket = socket |> event("ms_toggle_heal_sinner", %{"entry" => revive["id"], "from" => "1", "sinner" => second}) |> event("ms_set_heal_repeat", %{"entry" => all["id"], "from" => "1", "repeat" => "3"})
    assert [%{"repeat" => "3"}] = List.last(milestone(socket)["entries"])["floors"]

    html = render(socket)
    assert html =~ "Greatly Heal" and html =~ "Heal Everyone" and html =~ "Until healed" and html =~ "Until all healed"
    assert html =~ "Cost 200-400" and html =~ "Cost 200" and html =~ "Cost 300"
    refute html =~ ~s(phx-value-field="sell")
    assert GiftPlans.keep_set(saved(socket), 1) == MapSet.new()
  end

  test "skill replace entries pick sinners, a goal and a wanted skill distribution", %{socket: socket} do
    [first | _] = StarlightBot.Teams.all_sinners()
    socket = socket |> shop() |> event("ms_add_action", %{"action" => "skill_replace", "sinner" => first})
    [replace] = milestone(socket)["entries"]
    assert [%{"sinners" => [^first], "goal" => "optional", "target" => %{"s1" => 1, "s2" => 2, "s3" => 3}}] = replace["floors"]
    assert render(socket) =~ "Skill Replace" and render(socket) =~ "Cost 240"

    socket = event(socket, "ms_update_segment", %{"entry" => replace["id"], "from" => "1", "segment" => %{"goal" => "optional"}})
    id = replace["id"]
    socket = socket |> event("ms_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s1", "delta" => "-1"}) |> event("ms_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s2", "delta" => "5"}) |> event("ms_toggle_skill_lock", %{"entry" => id, "from" => "1"})
    assert [%{"goal" => "optional", "lock_s2" => false, "target" => %{"s1" => 0, "s2" => 5, "s3" => 1}}] = hd(milestone(socket)["entries"])["floors"]
    socket = event(socket, "ms_step_skill_target", %{"entry" => id, "from" => "1", "key" => "s1", "delta" => "3"})
    assert [%{"target" => %{"s1" => 3, "s2" => 2, "s3" => 1}}] = hd(milestone(socket)["entries"])["floors"]
    assert GiftPlans.heal_entries(GiftPlans.resolved_entries(milestone(socket), 1)) == []
    assert [%{goal: "optional", lock_s2: false, target: %{"s1" => 3, "s2" => 2, "s3" => 1}}] = GiftPlans.skill_replace_entries(GiftPlans.resolved_entries(milestone(socket), 1))
  end

  test "locking S2 keeps its target at or above the starting 2", %{socket: socket} do
    [first | _] = StarlightBot.Teams.all_sinners()
    socket = socket |> shop() |> event("ms_add_action", %{"action" => "skill_replace", "sinner" => first})
    [%{"id" => id}] = milestone(socket)["entries"]
    step = fn socket, key, delta -> event(socket, "ms_step_skill_target", %{"entry" => id, "from" => "1", "key" => key, "delta" => delta}) end

    socket = step.(socket, "s2", "-5")
    assert %{"s2" => 2} = hd(hd(milestone(socket)["entries"])["floors"])["target"]

    socket = socket |> event("ms_toggle_skill_lock", %{"entry" => id, "from" => "1"}) |> step.("s2", "-5")
    assert %{"s2" => 0, "s3" => 5} = hd(hd(milestone(socket)["entries"])["floors"])["target"]

    socket = event(socket, "ms_toggle_skill_lock", %{"entry" => id, "from" => "1"})
    assert %{"s2" => 2} = hd(hd(milestone(socket)["entries"])["floors"])["target"]
  end

  test "refresh cost grid follows the cases and lets the path branch", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_refresh_case", %{}) |> event("ms_add_refresh_case", %{})
    [first, second] = milestone(socket)["refresh"]
    path_total = fn socket ->
      ~r/<td class="text-center font-semibold"><span[^>]*>\s*(\d*)\s*<img/ |> Regex.scan(render(socket), capture: :all_but_first) |> List.flatten() |> Enum.reject(&(&1 == "")) |> List.last() |> String.to_integer()
    end

    socket =
      socket
      |> event("ms_update_refresh_case", %{"case_id" => first["id"], "action" => "refresh", "max" => "2"})
      |> event("ms_update_refresh_case", %{"case_id" => second["id"], "action" => "affinity_refresh", "affinity" => "", "max" => "1"})

    assert path_total.(socket) == 150

    socket = event(socket, "rf_pick", %{"step" => "0", "kind" => "normal"})
    assert path_total.(socket) == 0

    socket = event(socket, "rf_pick", %{"step" => "1", "kind" => "keyword"})
    assert path_total.(socket) == 105

    socket = event(socket, "rf_reset", %{})
    assert path_total.(socket) == 150
  end

  test "refresh cases read like a case statement: each gets a condition and an action, and they reorder and delete", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_refresh_case", %{}) |> event("ms_add_refresh_case", %{})
    [first, second] = milestone(socket)["refresh"]
    assert %{"condition" => nil, "action" => "refresh"} = first

    socket =
      socket
      |> event("cond_add", %{"case_id" => first["id"], "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"case_id" => first["id"], "path" => "", "op" => "refreshes", "cmp" => "lte", "value" => "3", "not" => "true"})
      |> event("ms_update_refresh_case", %{"case_id" => first["id"], "action" => "affinity_refresh", "affinity" => "burn"})
      |> event("ms_update_refresh_case", %{"case_id" => second["id"], "action" => "leave"})

    assert [%{"condition" => %{"op" => "refreshes", "cmp" => "lte", "value" => 3, "not" => true}, "action" => "affinity_refresh", "affinity" => "burn"}, %{"action" => "leave", "condition" => nil}] =
             milestone(socket)["refresh"]

    html = render(socket)
    assert html =~ "else if" and html =~ "stop working on this milestone" and html =~ ~s(<option value="leave" selected)

    socket = event(socket, "ms_reorder_refresh", %{"scope" => milestone(socket)["id"], "ids" => [second["id"], first["id"]]})
    assert Enum.map(milestone(socket)["refresh"], & &1["id"]) == [second["id"], first["id"]]

    socket = event(socket, "ms_remove_refresh_case", %{"case_id" => second["id"]})
    assert [%{"id" => id}] = milestone(socket)["refresh"]
    assert id == first["id"]
  end

  test "a refresh case with a max stops matching once it has run that many times", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_refresh_case", %{})
    [refresh_case] = milestone(socket)["refresh"]
    assert refresh_case["max"] == nil

    socket = event(socket, "ms_update_refresh_case", %{"case_id" => refresh_case["id"], "action" => "refresh", "max" => "2"})
    assert [%{"max" => 2}] = milestone(socket)["refresh"]

    assert GiftPlans.matching_refresh_case(milestone(socket), %{case_runs: %{refresh_case["id"] => 1}})
    refute GiftPlans.matching_refresh_case(milestone(socket), %{case_runs: %{refresh_case["id"] => 2}})

    socket = event(socket, "ms_update_refresh_case", %{"case_id" => refresh_case["id"], "action" => "refresh", "max" => ""})
    assert [%{"max" => nil}] = milestone(socket)["refresh"]
    assert GiftPlans.matching_refresh_case(milestone(socket), %{case_runs: %{refresh_case["id"] => 99}})
  end

  test "refresh cases can be scheduled by floor and the matching case follows the shop floor", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_refresh_case", %{}) |> event("ms_refresh_add_schedule", %{})
    [base] = milestone(socket)["refresh"]
    assert milestone(socket)["refresh_scheduled"]

    socket = socket |> event("ms_refresh_split", %{"floor" => "5"}) |> event("ms_add_refresh_case", %{})
    [%{"from" => 5, "cases" => [copied, added]}] = milestone(socket)["refresh_floors"]
    assert copied["id"] != base["id"]
    assert [^base] = milestone(socket)["refresh"]

    socket = event(socket, "ms_update_refresh_case", %{"case_id" => added["id"], "action" => "leave"})
    assert render(socket) =~ "F1-4" and render(socket) =~ "F5+"

    assert %{"action" => "refresh"} = GiftPlans.matching_refresh_case(milestone(socket), %{floor: 4})
    assert %{"id" => id} = GiftPlans.matching_refresh_case(milestone(socket), %{floor: 5})
    assert id == copied["id"]

    socket = event(socket, "ms_refresh_move_segment", %{"from" => "5", "to" => "7"})
    assert [%{"from" => 7}] = milestone(socket)["refresh_floors"]

    socket = event(socket, "ms_refresh_remove_segment", %{"from" => "7"})
    assert milestone(socket)["refresh_floors"] == []

    socket = event(socket, "ms_refresh_remove_schedule", %{})
    refute milestone(socket)["refresh_scheduled"]
  end

  test "turning Fuse on for an entry without a fusion gives it the default one, and unfusable gifts can't", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Fixed Thing"})
    ing_a = entry(socket, "Ing A")["id"]
    socket = event(socket, "ms_update_segment", %{"entry" => ing_a, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "required"}})
    socket = event(socket, "ms_add_gift", %{"gift" => "Fiery Down"})
    fiery = entry(socket, "Fiery Down")["id"]
    socket = update_in(socket.assigns.plan_data["milestones"], fn [m] -> [Map.update!(m, "entries", &Enum.map(&1, fn e -> if e["id"] == fiery, do: %{e | "fusion" => nil}, else: e end))] end)

    socket = event(socket, "ms_toggle", %{"entry" => fiery, "from" => "1", "field" => "fuse"})
    assert %{"fusion" => %{"type" => "tiered", "routes" => [_, _]}, "floors" => [%{"fuse" => true}]} = entry(socket, "Fiery Down")

    html = render(socket)
    assert html =~ "This gift can&#39;t be fused"
  end

  test "goals live at the top of the milestone and entries pick one", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("ms_add_goal", %{}) |> event("ms_set_goal_min", %{"letter" => "A", "min" => "2"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    socket = event(socket, "ms_update_segment", %{"entry" => glimpse, "from" => "1", "segment" => %{"disposition" => "keep", "goal" => "A"}})

    assert milestone(socket)["goals"] == [%{"letter" => "A", "min" => 2}]
    assert [%{"goal" => "A"}] = entry(socket, "Glimpse of Flames")["floors"]
    assert render(socket) =~ "at least"

    socket = event(socket, "ms_remove_goal", %{"letter" => "A"})
    assert milestone(socket)["goals"] == []
    assert [%{"goal" => "required"}] = entry(socket, "Glimpse of Flames")["floors"]
  end

  test "any-tier and any-affinity entries can only ignore or sell", %{socket: socket} do
    socket =
      socket
      |> shop()
      |> event("ms_add_tier", %{"tier" => "1"})
      |> event("ms_add_affinity", %{"affinity" => "burn", "tier" => "3"})
      |> event("ms_add_affinity", %{"affinity" => "burn", "tier" => "3"})

    assert Enum.map(milestone(socket)["entries"], & &1["subject"]) == [%{"tiers" => [1]}, %{"affinity" => "burn", "tiers" => [3]}]
    html = render(socket)
    assert html =~ "Any T1" and html =~ "Any burn T3"
    refute html =~ ~s(<option value="keep")
  end

  test "the fusion popup edits an entry's routes, which copy, paste and become tier defaults", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Glimpse of Flames"}) |> event("ms_add_gift", %{"gift" => "Ing A"})
    glimpse = entry(socket, "Glimpse of Flames")["id"]
    ing_a = entry(socket, "Ing A")["id"]
    [top_332, top_422] = entry(socket, "Glimpse of Flames")["fusion"]["routes"]

    socket =
      socket
      |> event("ms_open_fusion", %{"entry" => glimpse})
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

    socket = socket |> event("ms_close_fusion", %{}) |> event("ms_open_fusion", %{"entry" => ing_a})
    assert [%{"combo" => [2, 1, 1], "buy_up_to" => 1}, %{"combo" => [1, 1, 1, 1]}] = entry(socket, "Ing A")["fusion"]["routes"]
    socket = event(socket, "rt_add", %{"def_id" => ing_a, "parent" => "", "tier" => "2", "combo" => "2-2"})
    assert [_, _, %{"combo" => [2, 2]}] = entry(socket, "Ing A")["fusion"]["routes"]
    refute render(event(socket, "ms_close_fusion", %{})) =~ "Fuse (tiered)"
  end

  test "a fixed fusion's popup shows its recipe and which ingredients the milestone lacks", %{socket: socket} do
    socket = socket |> shop() |> event("ms_add_gift", %{"gift" => "Fixed Thing"})
    socket = event(socket, "ms_remove_entry", %{"entry" => entry(socket, "Ing A")["id"]})
    html = render(event(socket, "ms_open_fusion", %{"entry" => entry(socket, "Fixed Thing")["id"]}))

    assert html =~ "Fixed recipe."
    assert html =~ "(not in this milestone)"
  end

  test "milestones can be added, renamed, ordered and deleted", %{socket: socket} do
    %{"id" => shop_id} = milestone(socket)
    socket = socket |> event("add_milestone", %{}) |> event("move_milestone", %{"id" => shop_id, "dir" => "down"})
    [%{"id" => top_id}, %{"id" => ^shop_id}] = saved(socket)["milestones"]
    assert socket.assigns.selected_milestone_id == top_id

    socket = event(socket, "rename_milestone", %{"id" => top_id, "value" => " Early "})
    assert hd(saved(socket)["milestones"])["name"] == "Early"

    socket = event(socket, "delete_milestone", %{"id" => top_id})
    assert [%{"id" => ^shop_id}] = saved(socket)["milestones"]
    assert socket.assigns.selected_milestone_id == shop_id
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

  test "the end state tab renders a read-only milestone built from heals and the endless milestone's refresh and buys", %{socket: socket} do
    socket =
      socket
      |> event("ms_add_action", %{"action" => "heal_all"})
      |> event("ms_set_endless", %{"endless" => "true"})
      |> event("ms_add_refresh_case", %{})
      |> event("set_tab", %{"tab" => "end_state"})

    html = render(socket)

    assert socket.assigns.active_tab == :end_state
    assert html =~ "End state for"
    assert html =~ "Heal Everyone"
    assert html =~ "Refresh"
    assert html =~ "from #{milestone(socket)["name"]}"
    refute html =~ "+ Endless"
    refute html =~ "+ Greatly heal"

    assert socket |> event("set_end_state_kind", %{"kind" => "extreme"}) |> Map.fetch!(:assigns) |> Map.fetch!(:end_state_kind) == "extreme"
  end
end
