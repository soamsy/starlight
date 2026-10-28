defmodule StarlightBotWeb.Live.BattlePlanEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BattlePlans, Plans, Repo, Teams}
  alias StarlightBotWeb.Live.BattlePlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
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

  test "duplicating a plan copies its data under a new name and opens the copy", %{socket: socket} do
    original = Plans.get(:battle_plans, socket.assigns.editing_id)
    socket = event(socket, "duplicate_plan", %{"id" => to_string(original.id)})
    copy = Plans.get(:battle_plans, socket.assigns.editing_id)

    assert copy.id != original.id
    assert copy.name == "#{original.name} (copy)"
    assert copy.data == original.data
  end

  test "if blocks hold then and else actions and a hook condition tree", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [_win_rate, _commit, block] = actions(socket, playbook_id)
    id = block["id"]

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "ego", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "target", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "retry", "parent" => id, "branch" => "else"})
      |> event("cond_update", %{"action" => id, "path" => "0", "op" => "hook_off", "hook" => "battle_combat_ready"})
      |> event("cond_add", %{"action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"action" => id, "path" => "1", "op" => "hook_on", "hook" => "battle_chain"})
      |> event("cond_add", %{"action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"action" => id, "path" => "2", "op" => "sinners_eq", "hook" => ""})
      |> event("cond_update", %{"action" => id, "path" => "2", "op" => "sinners_eq", "value" => "1"})

    [_, _, block] = actions(socket, playbook_id)
    [ego, target] = block["then"]
    assert Enum.map(block["else"], & &1["type"]) == ["retry"]
    assert BattlePlans.condition_label(block["condition"]) == "battle_combat_ready off AND battle_chain on AND sinners = 1"

    socket =
      socket
      |> event("update_action", %{"action" => ego["id"], "grade" => "he", "pick" => "last"})
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

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "slots", "pick" => "first"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 0), ["who", "slots", "skill"]) == %{"who" => "slots", "slots" => %{"row" => "bottom", "is" => true, "match" => "envy"}, "skill" => %{"pick" => "all"}}

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "slots", "pick" => "first", "slot_is" => "false"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 0)["skill"] == %{"pick" => "first", "start" => 1, "end" => 1}

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "chosen", "pick" => "first"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 0), ["who", "chosen", "skill"]) == %{"who" => "chosen", "chosen" => %{"join" => "and", "conditions" => [%{"kind" => "top"}]}, "skill" => %{"pick" => "all"}}
    refute Map.has_key?(Enum.at(block["then"], 0), "slots")

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "chosen", "pick" => "all", "chosen_join" => "or", "chosen_c" => %{"0" => %{"kind" => "using", "values" => ["pride"]}, "1" => %{"kind" => "bottom"}}})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 0)["chosen"] == %{"join" => "or", "conditions" => [%{"kind" => "using", "values" => ["pride"]}, %{"kind" => "bottom"}]}

    socket = event(socket, "add_chosen", %{"action" => ego["id"]})
    [_, _, block] = actions(socket, playbook_id)
    assert length(Enum.at(block["then"], 0)["chosen"]["conditions"]) == 3

    socket = event(socket, "remove_chosen", %{"action" => ego["id"], "index" => "0"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.map(Enum.at(block["then"], 0)["chosen"]["conditions"], & &1["kind"]) == ["bottom", "top"]

    socket = event(socket, "update_action", %{"action" => ego["id"], "who" => "only", "pick" => "all"})

    socket = event(socket, "remove_sinner", %{"action" => ego["id"], "sinner" => "faust"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 0)["sinners"] == ["ryoshu"]
    assert block["else"] == []
    socket = event(socket, "close_action_condition", %{})
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

  test "retries per battle saves non-negative integers only", %{socket: socket} do
    socket = event(socket, "set_max_retries", %{"max_retries" => "5"})
    socket = event(socket, "set_max_retries", %{"max_retries" => "-2"})
    assert Plans.get(:battle_plans, socket.assigns.editing_id).data["max_retries"] == 5
    assert render(socket) =~ "Retries per battle"
  end

  test "an if block with a chain in a branch sorts last and blocks a second chain", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"action" => hd(chain["actions"])["id"]})
    socket = event(socket, "add_action", %{"container" => "root", "type" => "if"})
    [block] = actions(socket, chain["id"])

    socket =
      socket
      |> event("add_action", %{"container" => "root", "type" => "chain_a_res", "parent" => block["id"], "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "chain_fast", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain_fast", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain_fast"})
      |> event("add_action", %{"container" => "root", "type" => "ego"})

    assert [%{"type" => "ego"}, %{"type" => "if"} = block] = actions(socket, chain["id"])
    assert Enum.map(block["then"], & &1["type"]) == ["chain_a_res"]
    assert Enum.map(block["else"], & &1["type"]) == ["chain_fast"]
    refute "dodge" in BattlePlans.action_types("chain")
    assert "dodge" in BattlePlans.action_types("focused")
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
    assert ego["enemy"] == %{"pick" => "last", "n" => 1}

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "first", "grade" => "he", "enemy_pick" => "first", "enemy_n" => "3", "enemy_step" => "left"})
    [_, _, ego] = actions(socket, playbook_id)
    assert ego["enemy"] == %{"pick" => "first", "n" => 3, "step" => "left"}
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

    socket = event(socket, "update_action", Map.merge(base, %{"automate_rest" => "true"}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "continue"}
    assert render(socket) =~ ~s(name="rest[enemy_pick]")

    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "priority", "pick" => "all", "enemy_pick" => "last", "enemy_n" => "2"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "last", "n" => 2}

    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "priority", "pick" => "all", "enemy_pick" => "continue"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["enemy"] == %{"pick" => "continue"}
  end

  test "rest rows can be reordered and a head never keeps continue", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    base = %{"action" => target["id"], "pick" => "first", "enemy_pick" => "last", "enemy_n" => "2"}
    socket = event(socket, "update_action", Map.merge(base, %{"automate_rest" => "true"}))
    socket = event(socket, "update_action", Map.merge(base, %{"rest" => %{"kind" => "dodge", "pick" => "all", "enemy_pick" => "continue"}}))
    [_, _, target] = actions(socket, playbook_id)
    assert target["rest"]["type"] == "dodge"

    socket = event(socket, "reorder_rows", %{"scope" => target["id"] <> "|", "ids" => ["1", "0"]})
    [_, _, moved] = actions(socket, playbook_id)
    assert moved["id"] == target["id"]
    assert moved["type"] == "dodge"
    assert moved["enemy"] == %{"pick" => "none"}
    assert moved["rest"]["type"] == "target"
    assert moved["rest"]["enemy"] == %{"pick" => "last", "n" => 2}
    refute Map.has_key?(moved["rest"], "rest")
  end

  test "a focused action and its rest rows can do nothing", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"container" => "root", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    base = %{"action" => target["id"], "pick" => "first", "enemy_pick" => "first"}
    socket = event(socket, "update_action", Map.merge(base, %{"kind" => "nothing", "automate_rest" => "true"}))
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
    assert target["enemy"] == %{"pick" => "first", "n" => 1}
  end

  test "playbooks can be reordered within their kind", %{socket: socket} do
    socket = event(socket, "new_playbook", %{"kind" => "chain"})
    chains = fn socket -> for %{"kind" => "chain"} = pb <- socket.assigns.data["playbooks"], do: pb["id"] end
    [first, second] = chains.(socket)

    socket = event(socket, "reorder_playbooks", %{"scope" => "chain", "ids" => [second, first]})
    assert chains.(socket) == [second, first]
    assert render(socket) =~ ~s(data-sort-event="reorder_playbooks")
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
      |> event("set_sinner_profile", %{"sinner" => "faust", "profile_id" => to_string(faust_profile)})
      |> event("set_sinner_profile", %{"sinner" => "ryoshu", "profile_id" => to_string(ryoshu_profile)})
      |> event("add_action", %{"container" => "root", "type" => "ego"})

    [_, _, ego] = actions(socket, focused["id"])
    socket = event(socket, "add_sinner", %{"action" => ego["id"]})
    socket = event(socket, "add_sinner", %{"action" => ego["id"]})
    socket = event(socket, "add_sinner", %{"action" => ego["id"]})
    [_, _, ego] = actions(socket, focused["id"])
    assert Enum.sort(ego["sinners"]) == ["faust", "ryoshu"]

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

    socket = event(socket, "update_action", %{"action" => target["id"], "pick" => "last", "slot_from" => "2", "slot_to" => "3", "enemy_pick" => "first_with", "row" => "top"})
    [_, _, target] = actions(socket, playbook_id)
    assert target["skill"] == %{"pick" => "last", "start" => 2, "end" => 3}
    assert target["enemy"] == %{"pick" => "first", "n" => 1}
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

    pin_params = %{"pick" => "all", "kind" => "priority", "priority_order" => ["wrath", "s2"], "automate_rest" => "true"}
    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => pin_params}})
    [chain_action] = actions(socket, chain["id"])
    [pin] = chain_action["pins"]
    assert pin["priority"] == %{"order" => ["wrath", "s2"]}
    assert %{"type" => "target", "row" => "priority", "who" => "everyone", "skill" => %{"pick" => "all"}} = pin["rest"]
    assert render(socket) =~ ~s(name="pins[0][rest][kind]")

    rest_params = %{"kind" => "dodge", "pick" => "last", "slot_from" => "1", "slot_to" => "2", "who" => "everyone", "automate_rest" => "true"}
    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => Map.put(pin_params, "rest", rest_params)}})
    [chain_action] = actions(socket, chain["id"])
    assert %{"type" => "dodge", "skill" => %{"pick" => "last", "start" => 1, "end" => 2}, "rest" => %{"type" => "target"}} = hd(chain_action["pins"])["rest"]
    assert render(socket) =~ ~s(name="pins[0][rest][rest][kind]")
    assert render(socket) =~ ~s(name="pins[0][rest][automate_rest]")
    refute render(socket) =~ ~s(name="pins[0][rest][rest][automate_rest]")

    pin_params = Map.put(pin_params, "automate_rest", "false")
    socket = event(socket, "update_action", %{"action" => chain_action["id"], "pins" => %{"0" => pin_params}})
    [chain_action] = actions(socket, chain["id"])
    refute Map.has_key?(hd(chain_action["pins"]), "rest")

    socket =
      socket
      |> event("add_pin", %{"action" => chain_action["id"]})
      |> event("update_action", %{"action" => chain_action["id"], "pins" => %{"0" => pin_params, "1" => %{"pick" => "all", "row" => "top"}}})
      |> event("reorder_pins", %{"scope" => chain_action["id"], "ids" => ["1", "0"]})

    [chain_action] = actions(socket, chain["id"])
    assert Enum.map(chain_action["pins"], & &1["row"]) == ["top", "priority"]
    assert render(socket) =~ "the first pin wins"

    socket = event(socket, "reorder_pins", %{"scope" => chain_action["id"], "ids" => ["0"]})
    assert Enum.map(hd(actions(socket, chain["id"]))["pins"], & &1["row"]) == ["top", "priority"]
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
      |> event("add_action", %{"container" => "root", "type" => "chain_fast", "parent" => inner["id"], "branch" => "then"})
      |> event("add_action", %{"container" => "root", "type" => "chain_a_res", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain_fast", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"container" => "root", "type" => "chain_fast", "parent" => outer["id"], "branch" => "then"})
      |> event("cond_update", %{"action" => inner["id"], "path" => "0", "op" => "tray_count", "match" => "pride", "cmp" => "eq", "value" => "1", "sinner" => ""})

    [outer] = actions(socket, chain["id"])
    [inner] = outer["else"]
    assert Enum.map(outer["then"], & &1["type"]) == ["win_rate", "chain_fast"]
    assert Enum.map(inner["then"], & &1["type"]) == ["chain_fast"]
    assert Enum.map(inner["else"], & &1["type"]) == ["chain_a_res"]
    assert BattlePlans.condition_label(inner["condition"]) == "pride slots = 1"
    assert render(socket) =~ "pride slots = 1"
  end
end
