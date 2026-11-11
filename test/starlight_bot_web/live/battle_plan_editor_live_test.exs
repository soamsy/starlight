defmodule StarlightBotWeb.Live.BattlePlanEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BattlePlans, Plans, Teams}
  alias StarlightBotWeb.Live.BattlePlanEditorLive, as: Live

  setup do
    :ok = StarlightBot.TestDB.checkout()
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    {:noreply, socket} = Live.handle_event("new_plan", %{}, socket)
    focused = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "focused"))
    {:noreply, socket} = Live.handle_event("select_playbook", %{"id" => focused["id"]}, socket)
    %{socket: socket, playbook_id: focused["id"]}
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  defp render(socket) do
    socket.assigns |> Live.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  defp actions(socket, playbook_id) do
    saved = Plans.get(:battle_plans, socket.assigns.editing_id).data
    Enum.find(saved["playbooks"], &(&1["id"] == playbook_id))["actions"]
  end

  test "new plans are named after the team, numbered when the name is taken" do
    {:ok, team_id} = Teams.save_team(%{name: "Burn Team"})
    assert Plans.new_name(:battle_plans, team_id) == "Burn Team"
    {:ok, _} = Plans.save(:battle_plans, %{name: "Burn Team", data: BattlePlans.blank()})
    assert Plans.new_name(:battle_plans, team_id) == "Burn Team 2"
    assert Plans.new_name(:pack_plans, team_id) == "Burn Team"
    assert Plans.new_name(:battle_plans, nil) =~ "New Plan"
  end

  test "a copied battle plan pastes into another team and warns about profiles it lacks" do
    {:ok, source} = Teams.create_default_team()
    {:ok, target} = Teams.create_default_team()
    source_plan = Teams.get_team(source).battle_plan_id
    {:ok, profile} = StarlightBot.SinnerProfiles.save(%{name: "Faust test", sinner: "faust", locator_hook: "some_hook"})
    data = BattlePlans.blank() |> BattlePlans.put_profile("faust", profile) |> BattlePlans.put_profile("ryoshu", -1)
    {:ok, _} = Plans.save(:battle_plans, %{id: source_plan, name: Plans.get(:battle_plans, source_plan).name, data: data})
    bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    {:ok, source_socket} = Live.mount(%{}, %{"team_id" => source}, bare)
    source_socket = event(source_socket, "copy_plan", %{})
    [["copy_plan_json", %{text: text}]] = source_socket.private.live_temp.push_events

    {:ok, socket} = Live.mount(%{}, %{"team_id" => target}, bare)
    socket = event(socket, "paste_plan", %{"text" => text})

    target_plan = Teams.get_team(target).battle_plan_id
    assert socket.assigns.editing_id == target_plan
    assert target_plan != source_plan
    assert Plans.get(:battle_plans, target_plan).data == data
    assert socket.assigns.flash["error"] =~ "Ryoshu"
    refute socket.assigns.flash["error"] =~ "Faust"
  end

  test "target rows and chain pins collapse to a summary until opened", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    target = List.last(actions(socket, playbook_id))
    assert socket.assigns.open_editor_id == target["id"]
    assert render(socket) =~ "close_editor"

    socket = event(socket, "close_editor", %{})
    html = render(socket)
    assert html =~ "everyone, all slots: pick"
    assert html =~ ~s(title="s3")
    refute html =~ "data-chip-strip"
    assert html =~ ~s(phx-value-action="#{target["id"]}")

    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    [chain_action] = chain["actions"]
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("add_pin", %{"action" => chain_action["id"]})
    assert socket.assigns.open_editor_id == "#{chain_action["id"]}|pins[0]"

    socket = event(socket, "close_editor", %{})
    assert render(socket) =~ "everyone, all slots: pick"

    socket = event(socket, "open_editor", %{"action" => "#{chain_action["id"]}|pins[0]"})
    assert render(socket) =~ "Collapse this pin"
  end

  test "if blocks hold then and else actions and a hook condition tree", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [_win_rate, _commit, block] = actions(socket, playbook_id)
    id = block["id"]

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "target", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "target", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "retry", "parent" => id, "branch" => "else"})
      |> event("cond_update", %{"action" => id, "path" => "0", "op" => "hook", "not" => "true", "hook" => "battle_combat_ready"})
      |> event("cond_add", %{"action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"action" => id, "path" => "1", "op" => "hook", "not" => "false", "hook" => "battle_chain"})
      |> event("cond_add", %{"action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"action" => id, "path" => "2", "op" => "sinner_count", "hook" => ""})
      |> event("cond_update", %{"action" => id, "path" => "2", "op" => "sinner_count", "cmp" => "eq", "value" => "1"})

    [_, _, block] = actions(socket, playbook_id)
    [ego, _target] = block["then"]
    assert Enum.map(block["else"], & &1["type"]) == ["retry"]
    assert BattlePlans.condition_label(block["condition"]) == "battle_combat_ready off AND battle_chain on AND sinners = 1"

    socket =
      socket
      |> event("update_action", %{"action" => ego["id"], "kind" => "ego", "grade" => "he", "pick" => "last"})
      |> event("remove_action", %{"action" => hd(block["else"])["id"]})

    [_, _, block] = actions(socket, playbook_id)
    assert Enum.map(block["then"], & &1["type"]) == ["ego", "target"]
    assert Enum.at(block["then"], 0)["grade"] == "he"

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "except", "add_sinner" => "faust", "pick" => "all"})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "except", "sinners" => ["faust"], "add_sinner" => "ryoshu", "pick" => "all"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 0), ["who", "sinners"]) == %{"who" => "except", "sinners" => ["faust", "ryoshu"]}
    assert render(socket) =~ "all but"

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "everyone", "pick" => "all"})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 0), ["who", "sinners"]) == %{"who" => "only", "sinners" => ["faust", "ryoshu"]}

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "everyone", "pick" => "all"})
    socket = event(socket, "add_where", %{"action" => ego["id"]})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 0), ["who", "where", "skill"]) == %{"who" => "everyone", "where" => %{"join" => "and", "conditions" => [%{"kind" => "using", "values" => ["top"]}]}, "skill" => %{"pick" => "all"}}

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "everyone", "pick" => "all", "where_join" => "or", "where_c" => %{"0" => %{"kind" => "using", "values" => ["pride"]}, "1" => %{"kind" => "bottom"}}})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 0)["where"] == %{"join" => "or", "conditions" => [%{"kind" => "using", "values" => ["pride"]}, %{"kind" => "using", "values" => ["bottom"]}]}

    socket = event(socket, "add_chosen", %{"action" => ego["id"]})
    [_, _, block] = actions(socket, playbook_id)
    assert length(Enum.at(block["then"], 0)["where"]["conditions"]) == 3

    socket = event(socket, "remove_chosen", %{"action" => ego["id"], "index" => "0"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.map(Enum.at(block["then"], 0)["where"]["conditions"], & &1["values"]) == [["bottom"], ["top"]]

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "before", "pick" => "all", "sinners" => ["faust", "ryoshu"]})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.map(Enum.at(block["then"], 0)["where"]["conditions"], & &1["values"]) == [["bottom"], ["top"]]

    socket = event(socket, "remove_where", %{"action" => ego["id"]})
    [_, _, block] = actions(socket, playbook_id)
    refute Map.has_key?(Enum.at(block["then"], 0), "where")

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "everyone", "pick" => "all"})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all"})

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all", "sinners_csv" => "ryoshu"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 0)["sinners"] == ["ryoshu"]
    assert block["else"] == []
    socket = event(socket, "close_editor", %{})
    assert render(socket) =~ "battle_combat_ready off AND battle_chain on AND sinners = 1"
  end

  test "schedules wrap an action, tab per turn, and unwrap back into the list", %{socket: socket, playbook_id: playbook_id} do
    [win_rate, _commit] = actions(socket, playbook_id)

    socket = event(socket, "add_schedule", %{"action" => win_rate["id"]})
    [schedule, _commit] = actions(socket, playbook_id)
    assert schedule["type"] == "schedule"
    assert render(socket) =~ "Turns 1+"

    socket = event(socket, "split_schedule", %{"schedule" => schedule["id"], "turn" => "3"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.segment_froms(schedule) == [1, 3]
    assert socket.assigns.schedule_tabs[schedule["id"]] == 3
    assert render(socket) =~ "Turns 3+"

    socket = event(socket, "move_schedule_segment", %{"schedule" => schedule["id"], "from" => "3", "to" => "6"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.segment_froms(schedule) == [1, 6]

    socket = event(socket, "add_action", %{"container" => schedule["id"] <> "|6", "type" => "retry"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert Enum.map(Enum.at(schedule["segments"], 1)["actions"], & &1["type"]) == ["win_rate", "retry"]

    socket = event(socket, "remove_schedule_segment", %{"schedule" => schedule["id"], "from" => "6"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.segment_froms(schedule) == [1]

    socket = event(socket, "remove_schedule", %{"schedule" => schedule["id"]})
    assert Enum.map(actions(socket, playbook_id), & &1["type"]) == ["win_rate", "commit"]
  end

  test "a schedule can loop from a turn and the loop can be cleared", %{socket: socket, playbook_id: playbook_id} do
    [win_rate, _commit] = actions(socket, playbook_id)
    socket = event(socket, "add_schedule", %{"action" => win_rate["id"]})
    [schedule, _commit] = actions(socket, playbook_id)

    socket = event(socket, "set_schedule_loop", %{"schedule" => schedule["id"], "turn" => "2"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.loop_from(schedule) == 2
    assert BattlePlans.segment_froms(schedule) == [1, 2]
    assert render(socket) =~ "Loop T1"

    socket = event(socket, "set_schedule_loop", %{"schedule" => schedule["id"], "turn" => ""})
    [schedule, _commit] = actions(socket, playbook_id)
    refute BattlePlans.looping?(schedule)
  end

  test "a loop can get intro tabs and loop tabs, shrink, and be removed", %{socket: socket, playbook_id: playbook_id} do
    [win_rate, _commit] = actions(socket, playbook_id)
    socket = event(socket, "add_schedule", %{"action" => win_rate["id"]})
    [schedule, _commit] = actions(socket, playbook_id)
    id = schedule["id"]

    socket = event(socket, "set_schedule_loop", %{"schedule" => id, "turn" => "1"})
    socket = event(socket, "add_intro_tab", %{"schedule" => id, "turn" => "1"})
    socket = event(socket, "add_intro_tab", %{"schedule" => id, "turn" => "2"})
    socket = event(socket, "split_schedule", %{"schedule" => id, "turn" => "4"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.loop_from(schedule) == 3
    assert BattlePlans.segment_froms(schedule) == [1, 2, 3, 4]
    html = render(socket)
    assert html =~ "Loop T1" and html =~ "Loop T2"

    socket = event(socket, "remove_schedule_segment", %{"schedule" => id, "from" => "4"})
    [schedule, _commit] = actions(socket, playbook_id)
    assert BattlePlans.segment_froms(schedule) == [1, 2, 3]

    socket = event(socket, "set_schedule_loop", %{"schedule" => id, "turn" => ""})
    [schedule, _commit] = actions(socket, playbook_id)
    refute BattlePlans.looping?(schedule)
    assert BattlePlans.segment_froms(schedule) == [1, 2, 3]
  end

  test "dragging an action into a schedule tab and back", %{socket: socket, playbook_id: playbook_id} do
    [win_rate, commit] = actions(socket, playbook_id)
    socket = event(socket, "add_schedule", %{"action" => win_rate["id"]})
    [schedule, _commit] = actions(socket, playbook_id)
    tab = schedule["id"] <> "|1"

    socket = event(socket, "move_action_to", %{"scope" => tab, "from" => "root", "id" => commit["id"], "ids" => [win_rate["id"], commit["id"]]})
    [schedule] = actions(socket, playbook_id)
    assert Enum.map(hd(schedule["segments"])["actions"], & &1["type"]) == ["win_rate", "commit"]

    socket = event(socket, "move_action_to", %{"scope" => "root", "from" => tab, "id" => commit["id"], "ids" => [commit["id"], schedule["id"]]})
    assert Enum.map(actions(socket, playbook_id), & &1["type"]) == ["commit", "schedule"]

    socket = event(socket, "reorder_actions", %{"scope" => "root", "ids" => [schedule["id"], commit["id"]]})
    assert Enum.map(actions(socket, playbook_id), & &1["type"]) == ["schedule", "commit"]
  end

  test "retries per battle is saved on the selected playbook, non-negative integers only", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "set_max_retries", %{"max_retries" => "3"})
    socket = event(socket, "set_max_retries", %{"max_retries" => "-2"})
    data = Plans.get(:battle_plans, socket.assigns.editing_id).data
    refute Map.has_key?(data, "max_retries")
    assert Enum.find(data["playbooks"], &(&1["id"] == playbook_id))["max_retries"] == 3
    assert Enum.count(data["playbooks"], &(&1["max_retries"] == 3)) == 1
    assert render(socket) =~ "Retries per battle"
  end

  test "an if block with a chain in a branch keeps its place, and each list allows one chain", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"action" => hd(chain["actions"])["id"]})
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [block] = actions(socket, chain["id"])

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => block["id"], "branch" => "then"})
      |> event("add_else", %{"parent" => block["id"]})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain"})
      |> event("add_action", %{"container" => "root", "type" => "chain"})
      |> event("add_action", %{"container" => "root", "type" => "ego"})

    assert [%{"type" => "if"} = block, %{"type" => "ego"}, %{"type" => "chain"}] = actions(socket, chain["id"])
    assert Enum.map(block["then"], & &1["type"]) == ["chain"]
    assert Enum.map(block["else"], & &1["type"]) == ["chain"]
    assert BattlePlans.action_types("chain") == ~w(chain win_rate damage_rate ego dodge if commit retry)
    assert BattlePlans.action_types("focused") == ~w(win_rate damage_rate target if commit retry)
  end

  test "one action row switches between priority, dodge and ego, and targets can be skipped", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    socket = event(socket, "update_action", %{"action" => target["id"], "kind" => "dodge", "pick" => "first"})
    [_, _, dodge] = actions(socket, playbook_id)
    assert dodge["type"] == "dodge"
    assert dodge["enemy"] == %{"pick" => "none"}

    socket = event(socket, "update_action", %{"action" => target["id"], "kind" => "ego", "pick" => "first", "grade" => "he", "corrode" => "true"})
    [_, _, ego] = actions(socket, playbook_id)
    assert Map.take(ego, ["type", "grade", "corrode"]) == %{"type" => "ego", "grade" => "he", "corrode" => true}
    assert ego["enemy"] == %{"pick" => "none"}

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "first", "grade" => "he", "enemy_pick" => "last"})
    [_, _, ego] = actions(socket, playbook_id)
    assert ego["enemy"] == %{"pick" => "last", "offset" => 0, "step" => "left"}

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "first", "grade" => "he", "enemy_pick" => "first", "enemy_offset" => "2", "enemy_step" => "left"})
    [_, _, ego] = actions(socket, playbook_id)
    assert ego["enemy"] == %{"pick" => "first", "offset" => 2, "step" => "right"}

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "first", "grade" => "he", "enemy_pick" => "first", "enemy_offset" => "2", "enemy_step" => "left"})
    [_, _, ego] = actions(socket, playbook_id)
    assert ego["enemy"] == %{"pick" => "first", "offset" => 2, "step" => "left"}
    assert render(socket) =~ ~s(name="enemy_step")

    socket = event(socket, "update_action", %{"action" => target["id"], "kind" => "top", "pick" => "first", "enemy_pick" => "none"})
    [_, _, top] = actions(socket, playbook_id)
    assert Map.take(top, ["type", "row", "enemy"]) == %{"type" => "target", "row" => "top", "enemy" => %{"pick" => "none"}}
    refute Map.has_key?(top, "grade")
    html = render(socket)
    assert html =~ "Priority"
    refute html =~ "Top skill"
    refute html =~ "Bottom skill"
  end

  test "target ignores can be added, edited and removed, including inside a rest form", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    base = %{"action" => target["id"], "pick" => "first", "enemy_pick" => "first"}
    socket = event(socket, "update_action", Map.put(base, "enemy_ignore_add", "left"))
    socket = event(socket, "update_action", Map.merge(base, %{"enemy_ignore" => %{"0" => %{"side" => "left", "n" => "3"}}, "enemy_ignore_add" => "top"}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["enemy"]["ignore"] == [%{"side" => "left", "n" => 3}, %{"side" => "top", "n" => 1}]
    assert render(socket) =~ ~s(name="enemy_ignore[1][side]")

    socket = event(socket, "remove_ignore", %{"action" => target["id"], "path" => "", "index" => "0"})
    [_, _, target] = actions(socket, playbook_id)
    assert target["enemy"]["ignore"] == [%{"side" => "top", "n" => 1}]

    socket = event(socket, "add_rest", %{"action" => target["id"], "path" => ""})
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "continue"}
    assert render(socket) =~ ~s(name="rest[enemy_pick]")

    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "priority", "pick" => "all", "enemy_pick" => "last", "enemy_offset" => "1"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "last", "offset" => 1, "step" => "left"}

    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "priority", "pick" => "all", "enemy_pick" => "continue"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "continue"}
  end

  test "rest rows can be reordered and a head never keeps continue", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    base = %{"action" => target["id"], "pick" => "first", "enemy_pick" => "last", "enemy_offset" => "1"}
    socket = event(socket, "add_rest", %{"action" => target["id"], "path" => ""})
    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "dodge", "pick" => "all", "enemy_pick" => "continue"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["type"] == "dodge"

    socket = event(socket, "reorder_rows", %{"scope" => target["id"] <> "|", "ids" => ["1", "0"]})
    [_, _, moved] = actions(socket, playbook_id)
    assert moved["id"] == target["id"]
    assert moved["type"] == "dodge"
    assert moved["enemy"] == %{"pick" => "none"}
    assert moved["rest"]["type"] == "target"
    assert moved["rest"]["enemy"] == %{"pick" => "last", "offset" => 1, "step" => "left"}
    refute Map.has_key?(moved["rest"], "rest")
  end

  test "a focused action and its rest rows can do nothing", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    base = %{"action" => target["id"], "pick" => "first", "enemy_pick" => "first"}
    socket = event(socket, "update_action", Map.merge(base, %{"kind" => "nothing"}))
    socket = event(socket, "add_rest", %{"action" => target["id"], "path" => ""})
    [_, _, target] = actions(socket, playbook_id)
    assert target["type"] == "nothing"
    refute Map.has_key?(target, "enemy")
    assert render(socket) =~ ~s(value="nothing")

    socket = event(socket, "update_action", Map.merge(base, %{"kind" => "nothing", "rest" => %{"kind" => "nothing", "pick" => "all"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["type"] == "nothing"

    socket = event(socket, "update_action", Map.merge(base, %{"kind" => "priority"}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["type"] == "target"
    assert target["enemy"] == %{"pick" => "first", "offset" => 0, "step" => "right"}
  end

  test "a playbook copied to the clipboard pastes as a new playbook of its kind with fresh ids", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"type" => "if", "container" => "root"})
    source = Enum.find(socket.assigns.data["playbooks"], &(&1["id"] == playbook_id))
    text = StarlightBot.PlanClipboard.encode_playbook(source)

    socket = event(socket, "paste_playbook", %{"text" => text, "kind" => "focused"})
    pasted = List.last(socket.assigns.data["playbooks"])
    assert pasted["kind"] == "focused"
    assert pasted["name"] == source["name"] <> " copy"
    assert socket.assigns.playbook_id == pasted["id"]
    ids = fn playbook -> playbook["actions"] |> BattlePlans.flatten_actions() |> Enum.map(& &1["id"]) end
    assert length(ids.(pasted)) == length(ids.(source))
    assert MapSet.disjoint?(MapSet.new(ids.(pasted)), MapSet.new(ids.(source)))
    assert Enum.map(Plans.get(:battle_plans, socket.assigns.editing_id).data["playbooks"], & &1["id"]) == Enum.map(socket.assigns.data["playbooks"], & &1["id"])

    socket = event(socket, "paste_playbook", %{"text" => text, "kind" => "chain"})
    assert socket.assigns.flash["error"] =~ "focused playbook, not a chain playbook"
    assert length(socket.assigns.data["playbooks"]) == 4
  end

  test "playbooks can be reordered within their kind", %{socket: socket} do
    socket = event(socket, "new_playbook", %{"kind" => "chain"})
    chains = fn socket -> for %{"kind" => "chain"} = pb <- socket.assigns.data["playbooks"], do: pb["id"] end
    [first, middle, second] = chains.(socket)

    socket = event(socket, "reorder_playbooks", %{"scope" => "chain", "ids" => [second, middle, first]})
    assert chains.(socket) == [second, middle, first]
    assert render(socket) =~ ~s(data-sort-event="reorder_playbooks")
  end

  test "lineups copy, paste, reorder and rename from their list", %{socket: socket} do
    socket = event(socket, "toggle_lineup_sinner", %{"sinner" => "faust"})
    source = BattlePlans.find_lineup(socket.assigns.data, socket.assigns.lineup_id)
    text = StarlightBot.PlanClipboard.encode_lineup(source)

    socket = event(socket, "paste_lineup", %{"text" => text})
    pasted = List.last(BattlePlans.lineups(socket.assigns.data))
    assert pasted["name"] == source["name"] <> " copy"
    assert pasted["sinners"] == ["faust"]
    assert pasted["id"] != source["id"]
    assert socket.assigns.lineup_id == pasted["id"]

    socket = event(socket, "reorder_lineups", %{"ids" => [pasted["id"], source["id"]]})
    assert Enum.map(BattlePlans.lineups(socket.assigns.data), & &1["id"]) == [pasted["id"], source["id"]]
    assert render(socket) =~ ~s(data-sort-event="reorder_lineups")

    socket = event(socket, "paste_lineup", %{"text" => "hello"})
    assert socket.assigns.flash["error"] =~ "doesn't hold a Starlight lineup"
  end

  test "double-clicking a playbook row renames that playbook", %{socket: socket, playbook_id: playbook_id} do
    other = socket.assigns.data["playbooks"] |> Enum.find(&(&1["id"] != playbook_id)) |> Map.fetch!("id")
    socket = event(socket, "start_rename_playbook", %{"id" => other})
    assert socket.assigns.renaming_playbook_id == other
    socket = event(socket, "rename_playbook", %{"value" => "Renamed"})
    assert socket.assigns.renaming_playbook_id == nil
    assert Enum.find(socket.assigns.data["playbooks"], &(&1["id"] == other))["name"] == "Renamed"
  end

  test "sinner pickers only offer sinners with a profile and + adds the first free one" do
    {:ok, faust_profile} = StarlightBot.SinnerProfiles.save(%{name: "Faust test", sinner: "faust"})
    {:ok, ryoshu_profile} = StarlightBot.SinnerProfiles.save(%{name: "Ryoshu test", sinner: "ryoshu"})
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    socket = event(socket, "new_plan", %{})
    focused = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "focused"))

    socket =
      socket
      |> event("select_playbook", %{"id" => focused["id"]})
      |> event("set_sinner_profile", %{"sinner" => "faust", "profile_ids" => to_string(faust_profile)})
      |> event("set_sinner_profile", %{"sinner" => "ryoshu", "profile_ids" => to_string(ryoshu_profile)})
      |> event("add_action", %{"container" => "root", "type" => "target"})

    [_, _, ego] = actions(socket, focused["id"])
    socket = event(socket, "update_action", %{"action" => ego["id"], "who_mode" => "sinners", "who" => "only", "pick" => "all"})
    [_, _, ego] = actions(socket, focused["id"])
    assert ego["sinners"] == ["faust"]

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all", "sinners_csv" => ""})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who_mode" => "everyone", "pick" => "all"})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who_mode" => "sinners", "who" => "only", "pick" => "all"})
    [_, _, ego] = actions(socket, focused["id"])
    assert ego["sinners"] == []

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all", "sinners_csv" => "faust,ryoshu,bogus,faust"})
    [_, _, ego] = actions(socket, focused["id"])
    assert ego["sinners"] == ["faust", "ryoshu"]

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "first"})
    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "sinners" => ["faust", "gregor"], "pick" => "first"})
    assert render(socket) =~ "no profile in this plan"
  end

  test "chain pins and focused targets can pick their row by a mixed priority list", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    socket =
      socket
      |> event("update_action", %{"action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority"})
      |> event("update_action", %{"action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority", "priority_order" => ["s3", "wrath", "dodge", ""]})

    [_, _, target] = actions(socket, playbook_id)
    assert target["priority"] == %{"order" => ["s3", "wrath", "dodge"]}

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "last", "chip" => %{"0" => %{"at" => "1", "on" => "true"}, "1" => %{"at" => "2", "on" => "true"}}, "gap_lead" => "false", "gap_trail" => "false", "enemy_pick" => "first_with", "row" => "top"})
    [_, _, target] = actions(socket, playbook_id)
    assert target["skill"] == %{"pick" => "last", "chips" => [%{"at" => 1, "on" => true}, %{"at" => 2, "on" => true}], "gaps" => %{"lead" => false, "mid" => [], "trail" => false}}

    socket = event(socket, "add_slot_chip", %{"action" => target["id"], "path" => ""})
    [_, _, target] = actions(socket, playbook_id)
    assert Enum.map(target["skill"]["chips"], & &1["at"]) == [1, 2, 3]
    assert render(socket) =~ ~s(name="chip[2][at]")

    socket = event(socket, "step_slot_chip", %{"action" => target["id"], "path" => "", "index" => "2", "delta" => "1"})
    [_, _, target] = actions(socket, playbook_id)
    assert Enum.map(target["skill"]["chips"], & &1["at"]) == [1, 2, 4]
    assert target["enemy"] == %{"pick" => "first", "offset" => 0, "step" => "right"}
    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority", "priority_order" => ["s3", "wrath", "dodge"]})
    html = render(socket)
    assert html =~ "data-chip-strip"
    assert html =~ ~s(src="/images/sin/wrath.webp")
    assert html =~ ~s(name="priority_order[]")

    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    [chain_action] = chain["actions"]

    socket =
      socket
      |> event("select_playbook", %{"id" => chain["id"]})
      |> event("add_pin", %{"action" => chain_action["id"]})
      |> event("update_action", %{"action" => chain_action["id"], "pins" => %{"0" => %{"pick" => "all", "row" => "top"}}})
      |> event("update_action", %{"action" => chain_action["id"], "pins" => %{"0" => %{"pick" => "all", "row" => "priority"}}})

    [chain_action] = actions(socket, chain["id"])
    assert [%{"row" => "priority", "priority" => %{"order" => ["s3", "s2", "s1"]}, "skill" => %{"pick" => "all"}}] = chain_action["pins"]

    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => %{"pick" => "all", "row" => "priority", "priority_order" => ["pride", "s2"]}}})
    [chain_action] = actions(socket, chain["id"])
    assert hd(chain_action["pins"])["priority"] == %{"order" => ["pride", "s2"]}

    pin_params = %{"pick" => "all", "kind" => "priority", "priority_order" => ["wrath", "s2"]}
    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => pin_params}})
    socket = event(socket, "add_rest", %{"action" => chain_action["id"], "path" => "pins[0]"})
    [chain_action] = actions(socket, chain["id"])
    [pin] = chain_action["pins"]
    assert pin["priority"] == %{"order" => ["wrath", "s2"]}
    assert %{"type" => "target", "row" => "priority", "who" => "everyone", "skill" => %{"pick" => "all"}} = pin["rest"]
    assert render(socket) =~ ~s(name="pins[0][rest][kind]")

    rest_params = %{"kind" => "dodge", "pick" => "last", "chip" => %{"0" => %{"at" => "0", "on" => "true"}, "1" => %{"at" => "1", "on" => "true"}}, "gap_trail" => "false", "who" => "everyone"}
    socket = event(socket, "add_rest", %{"action" => chain_action["id"], "path" => "pins[0][rest]"})
    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => Map.put(pin_params, "rest", rest_params)}})
    [chain_action] = actions(socket, chain["id"])
    assert %{"type" => "dodge", "skill" => %{"pick" => "last", "chips" => [%{"at" => 0, "on" => true}, %{"at" => 1, "on" => true}]}, "rest" => %{"type" => "target"}} = hd(chain_action["pins"])["rest"]
    assert render(socket) =~ ~s(name="pins[0][rest][rest][kind]")
    assert render(socket) =~ ~s(phx-value-path="pins[0][rest][rest]")

    socket = event(socket, "add_where", %{"action" => chain_action["id"], "path" => "pins[0]"})
    [chain_action] = actions(socket, chain["id"])
    assert hd(chain_action["pins"])["where"]["conditions"] == [%{"kind" => "has", "values" => []}]
    refute render(socket) =~ ~s(value="using")
    socket = event(socket, "remove_where", %{"action" => chain_action["id"], "path" => "pins[0]"})

    socket = event(socket, "remove_rest", %{"action" => chain_action["id"], "path" => "pins[0]"})
    [chain_action] = actions(socket, chain["id"])
    refute Map.has_key?(hd(chain_action["pins"]), "rest")

    socket = event(socket, "add_pin", %{"action" => chain_action["id"]})
    socket = event(socket, "add_pin", %{"action" => chain_action["id"]})
    assert length(hd(actions(socket, chain["id"]))["pins"]) == 1
    refute render(socket) =~ "the first pin wins"
  end

  test "an if nested in an else branch acts as else-if, with one chain per path", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"action" => hd(chain["actions"])["id"]})
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [outer] = actions(socket, chain["id"])

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "win_rate", "parent" => outer["id"], "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "if", "parent" => outer["id"], "branch" => "else"})

    [outer] = actions(socket, chain["id"])
    [inner] = outer["else"]

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => inner["id"], "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => outer["id"], "branch" => "then"})
      |> event("cond_update", %{"action" => inner["id"], "path" => "0", "op" => "tray_count", "matches" => ["pride"], "cmp" => "eq", "value" => "1", "sinners_csv" => ""})

    [outer] = actions(socket, chain["id"])
    [inner] = outer["else"]
    assert Enum.map(outer["then"], & &1["type"]) == ["win_rate", "chain"]
    assert Enum.map(inner["then"], & &1["type"]) == ["chain"]
    assert Enum.map(inner["else"], & &1["type"]) == ["chain"]
    assert BattlePlans.condition_label(inner["condition"]) == "pride slots = 1"
    assert render(socket) =~ "pride slots = 1"
  end

  test "else if branches insert anywhere in the chain and hold their own actions and conditions", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"action" => hd(chain["actions"])["id"]})
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [block] = actions(socket, chain["id"])
    assert BattlePlans.branches(block) == ["then"]

    socket = event(socket, "add_else", %{"parent" => block["id"]})
    [block] = actions(socket, chain["id"])
    assert BattlePlans.branches(block) == ["then", "else"]

    socket = event(socket, "add_elif", %{"parent" => block["id"], "after" => "then"})
    [block] = actions(socket, chain["id"])
    [first] = block["elifs"]

    socket = event(socket, "add_elif", %{"parent" => block["id"], "after" => "then"})
    [block] = actions(socket, chain["id"])
    [second, ^first] = block["elifs"]
    assert BattlePlans.branches(block) == ["then", second["id"], first["id"], "else"]

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "retry", "parent" => block["id"], "branch" => second["id"]})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => block["id"], "branch" => first["id"]})
      |> event("add_action", %{"container" => "root", "type" => "chain", "parent" => block["id"], "branch" => "else"})
      |> event("cond_update", %{"action" => first["id"], "path" => "0", "op" => "tray_count", "matches" => ["pride"], "cmp" => "eq", "value" => "1", "sinners_csv" => ""})

    [block] = actions(socket, chain["id"])
    assert Enum.map(BattlePlans.branch_actions(block, second["id"]), & &1["type"]) == ["retry"]
    assert Enum.map(BattlePlans.branch_actions(block, first["id"]), & &1["type"]) == ["chain"]
    assert Enum.map(block["else"], & &1["type"]) == ["chain"]
    assert BattlePlans.condition_label(Enum.find(block["elifs"], &(&1["id"] == first["id"]))["condition"]) == "pride slots = 1"
    assert render(socket) =~ "else if"

    socket = event(socket, "remove_elif", %{"elif" => second["id"]})
    [block] = actions(socket, chain["id"])
    assert Enum.map(block["elifs"], & &1["id"]) == [first["id"]]

    socket = event(socket, "remove_else", %{"parent" => block["id"]})
    [block] = actions(socket, chain["id"])
    assert BattlePlans.branches(block) == ["then", first["id"]]
  end

  test "duplicating a row copies it right below with fresh ids, including nested blocks", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "win_rate"})
    [win_rate | _] = Enum.filter(actions(socket, playbook_id), &(&1["type"] == "win_rate"))
    socket = event(socket, "dup_action", %{"action" => win_rate["id"]})
    rows = actions(socket, playbook_id)
    index = Enum.find_index(rows, &(&1["id"] == win_rate["id"]))
    copy = Enum.at(rows, index + 1)
    assert copy["type"] == "win_rate"
    refute copy["id"] == win_rate["id"]

    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    block = socket |> actions(playbook_id) |> Enum.find(&(&1["type"] == "if"))

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "retry", "parent" => block["id"], "branch" => "then"})
      |> event("dup_action", %{"action" => block["id"]})

    [first, second] = socket |> actions(playbook_id) |> Enum.filter(&(&1["type"] == "if"))
    refute first["id"] == second["id"]
    assert Enum.map(second["then"], & &1["type"]) == ["retry"]
    refute hd(first["then"])["id"] == hd(second["then"])["id"]
  end

  test "a sinner position condition edits its slot range with the shared chips", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"action" => hd(chain["actions"])["id"]})
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [block] = actions(socket, chain["id"])

    socket =
      socket
      |> event("cond_update", %{"action" => block["id"], "path" => "0", "op" => "sinner_position", "sinners_csv" => "faust,ryoshu", "pick" => "first"})
      |> event("cond_add_chip", %{"action" => block["id"], "path" => "0"})
      |> event("cond_step_chip", %{"action" => block["id"], "path" => "0", "index" => "1", "delta" => "1"})

    [block] = actions(socket, chain["id"])
    [leaf] = block["condition"]["children"]
    assert leaf["sinners"] == ["faust", "ryoshu"]
    assert Enum.map(leaf["position"]["chips"], & &1["at"]) == [0, 2]
    assert socket |> event("open_editor", %{"action" => block["id"]}) |> render() =~ "Add another slot position"
  end
end
