defmodule StarlightBotWeb.Live.BattleStrategyEditorLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{BattleStrategies, Repo, Strategies}
  alias StarlightBotWeb.Live.BattleStrategyEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    {:noreply, socket} = Live.handle_event("new_strategy", %{}, socket)
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
    saved = Strategies.get(:battle_strategies, socket.assigns.editing_id).data
    hd(Enum.find(saved["playbooks"], &(&1["id"] == playbook_id))["phases"])["actions"]
  end

  test "duplicating a strategy copies its data under a new name and opens the copy", %{socket: socket} do
    original = Strategies.get(:battle_strategies, socket.assigns.editing_id)
    socket = event(socket, "duplicate_strategy", %{"id" => to_string(original.id)})
    copy = Strategies.get(:battle_strategies, socket.assigns.editing_id)

    assert copy.id != original.id
    assert copy.name == "#{original.name} (copy)"
    assert copy.data == original.data
  end

  test "if blocks hold then and else actions and a hook condition tree", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"turn" => "1", "type" => "if"})
    [_win_rate, _commit, block] = actions(socket, playbook_id)
    id = block["id"]

    socket =
      socket
      |> event("add_action", %{"turn" => "1", "type" => "ego", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"turn" => "1", "type" => "target", "parent" => id, "branch" => "then"})
      |> event("add_action", %{"turn" => "1", "type" => "clear", "parent" => id, "branch" => "else"})
      |> event("cond_update", %{"turn" => "1", "action" => id, "path" => "0", "op" => "hook_off", "hook" => "battle_combat_ready"})
      |> event("cond_add", %{"turn" => "1", "action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"turn" => "1", "action" => id, "path" => "1", "op" => "hook_on", "hook" => "battle_chain"})
      |> event("cond_add", %{"turn" => "1", "action" => id, "path" => "", "node" => "leaf"})
      |> event("cond_update", %{"turn" => "1", "action" => id, "path" => "2", "op" => "sinners_eq", "hook" => ""})
      |> event("cond_update", %{"turn" => "1", "action" => id, "path" => "2", "op" => "sinners_eq", "value" => "1"})

    [_, _, block] = actions(socket, playbook_id)
    [ego, target] = block["then"]
    assert Enum.map(block["else"], & &1["type"]) == ["clear"]
    assert BattleStrategies.condition_label(block["condition"]) == "battle_combat_ready off AND battle_chain on AND sinners = 1"

    socket =
      socket
      |> event("move_action", %{"turn" => "1", "action" => target["id"], "dir" => "up"})
      |> event("update_action", %{"turn" => "1", "action" => ego["id"], "grade" => "he", "pick" => "last"})
      |> event("remove_action", %{"turn" => "1", "action" => hd(block["else"])["id"]})

    [_, _, block] = actions(socket, playbook_id)
    assert Enum.map(block["then"], & &1["type"]) == ["target", "ego"]
    assert Enum.at(block["then"], 1)["grade"] == "he"

    socket = event(socket, "update_action", %{"turn" => "1", "action" => ego["id"], "who" => "except", "add_profile" => "7", "pick" => "all"})
    socket = event(socket, "update_action", %{"turn" => "1", "action" => ego["id"], "who" => "except", "profile_ids" => ["7"], "add_profile" => "9", "pick" => "all"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 1), ["who", "profile_ids"]) == %{"who" => "except", "profile_ids" => [7, 9]}
    assert render(socket) =~ "all but"

    socket = event(socket, "update_action", %{"turn" => "1", "action" => ego["id"], "who" => "everyone", "pick" => "all"})
    socket = event(socket, "update_action", %{"turn" => "1", "action" => ego["id"], "who" => "only", "pick" => "all"})
    [_, _, block] = actions(socket, playbook_id)
    assert Map.take(Enum.at(block["then"], 1), ["who", "profile_ids"]) == %{"who" => "only", "profile_ids" => [7, 9]}

    socket = event(socket, "remove_sinner", %{"turn" => "1", "action" => ego["id"], "profile" => "7"})
    [_, _, block] = actions(socket, playbook_id)
    assert Enum.at(block["then"], 1)["profile_ids"] == [9]
    assert block["else"] == []
    assert render(socket) =~ "battle_combat_ready off AND battle_chain on AND sinners = 1"
  end

  test "retries per battle saves non-negative integers only", %{socket: socket} do
    socket = event(socket, "set_max_retries", %{"max_retries" => "5"})
    socket = event(socket, "set_max_retries", %{"max_retries" => "-2"})
    assert Strategies.get(:battle_strategies, socket.assigns.editing_id).data["max_retries"] == 5
    assert render(socket) =~ "Retries per battle"
  end

  test "an if block with a chain in a branch sorts last and blocks a second chain", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"turn" => "1", "action" => hd(hd(chain["phases"])["actions"])["id"]})
    socket = event(socket, "add_action", %{"turn" => "1", "type" => "if"})
    [block] = actions(socket, chain["id"])

    socket =
      socket
      |> event("add_action", %{"turn" => "1", "type" => "chain_a_res", "parent" => block["id"], "branch" => "then"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast", "parent" => block["id"], "branch" => "else"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast"})
      |> event("add_action", %{"turn" => "1", "type" => "dodge"})

    assert [%{"type" => "dodge"}, %{"type" => "if"} = block] = actions(socket, chain["id"])
    assert Enum.map(block["then"], & &1["type"]) == ["chain_a_res"]
    assert Enum.map(block["else"], & &1["type"]) == ["chain_fast"]
  end

  test "chain pins and focused targets can pick their row by a mixed priority list", %{socket: socket, playbook_id: playbook_id} do
    socket = event(socket, "add_action", %{"turn" => "1", "type" => "target"})
    [_, _, target] = actions(socket, playbook_id)

    socket =
      socket
      |> event("update_action", %{"turn" => "1", "action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority"})
      |> event("update_action", %{"turn" => "1", "action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority", "priority_order" => ["s3", "wrath", "dodge", ""]})

    [_, _, target] = actions(socket, playbook_id)
    assert target["priority"] == %{"order" => ["s3", "wrath", "dodge"]}

    socket = event(socket, "update_action", %{"turn" => "1", "action" => target["id"], "pick" => "first_with", "n" => "3", "match" => "gloom", "enemy_pick" => "first_with", "row" => "top"})
    [_, _, target] = actions(socket, playbook_id)
    assert target["skill"] == %{"pick" => "first_with", "n" => 3, "match" => "gloom"}
    assert target["enemy"] == %{"pick" => "first"}
    socket = event(socket, "update_action", %{"turn" => "1", "action" => target["id"], "pick" => "first", "enemy_pick" => "last", "row" => "priority", "priority_order" => ["s3", "wrath", "dodge"]})
    html = render(socket)
    assert html =~ "(else bottom)"
    assert html =~ ~s(<optgroup label="sin">)

    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    [chain_action] = hd(chain["phases"])["actions"]

    socket =
      socket
      |> event("select_playbook", %{"id" => chain["id"]})
      |> event("add_pin", %{"turn" => "1", "action" => chain_action["id"]})
      |> event("update_action", %{"turn" => "1", "action" => chain_action["id"], "pins" => %{"0" => %{"pick" => "all", "row" => "priority"}}})

    [chain_action] = actions(socket, chain["id"])
    assert [%{"row" => "priority", "priority" => %{"order" => ["s3", "s2", "s1"]}, "skill" => %{"pick" => "all"}}] = chain_action["pins"]

    socket = event(socket, "update_action", %{"turn" => "1", "action" => chain_action["id"], "pins" => %{"0" => %{"pick" => "all", "row" => "priority", "priority_order" => ["pride", "s2"]}}})
    [chain_action] = actions(socket, chain["id"])
    assert hd(chain_action["pins"])["priority"] == %{"order" => ["pride", "s2"]}

    pin_params = %{"pick" => "all", "row" => "priority", "priority_order" => ["wrath", "s2"], "keep_min" => "1", "keep_max" => "4"}
    socket = event(socket, "update_action", %{"turn" => "1", "action" => chain_action["id"], "pins" => %{"0" => pin_params}})
    [chain_action] = actions(socket, chain["id"])
    assert hd(chain_action["pins"])["priority"] == %{"order" => ["wrath", "s2"], "min" => 1, "max" => 4}
    assert render(socket) =~ ~s(name="pins[0][keep_max]")

    socket =
      socket
      |> event("add_pin", %{"turn" => "1", "action" => chain_action["id"]})
      |> event("update_action", %{"turn" => "1", "action" => chain_action["id"], "pins" => %{"0" => pin_params, "1" => %{"pick" => "all", "row" => "top"}}})
      |> event("reorder_pins", %{"scope" => "1|#{chain_action["id"]}", "ids" => ["1", "0"]})

    [chain_action] = actions(socket, chain["id"])
    assert Enum.map(chain_action["pins"], & &1["row"]) == ["top", "priority"]
    assert render(socket) =~ "the first pin wins"

    socket = event(socket, "reorder_pins", %{"scope" => "1|#{chain_action["id"]}", "ids" => ["0"]})
    assert Enum.map(hd(actions(socket, chain["id"]))["pins"], & &1["row"]) == ["top", "priority"]
  end

  test "an if nested in an else branch acts as else-if, with one chain per path", %{socket: socket} do
    chain = Enum.find(socket.assigns.data["playbooks"], &(&1["kind"] == "chain"))
    socket = socket |> event("select_playbook", %{"id" => chain["id"]}) |> event("remove_action", %{"turn" => "1", "action" => hd(hd(chain["phases"])["actions"])["id"]})
    socket = event(socket, "add_action", %{"turn" => "1", "type" => "if"})
    [outer] = actions(socket, chain["id"])

    socket =
      socket
      |> event("add_action", %{"turn" => "1", "type" => "win_rate", "parent" => outer["id"], "branch" => "then"})
      |> event("add_action", %{"turn" => "1", "type" => "if", "parent" => outer["id"], "branch" => "else"})

    [outer] = actions(socket, chain["id"])
    [inner] = outer["else"]

    socket =
      socket
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast", "parent" => inner["id"], "branch" => "then"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_a_res", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast", "parent" => inner["id"], "branch" => "else"})
      |> event("add_action", %{"turn" => "1", "type" => "chain_fast", "parent" => outer["id"], "branch" => "then"})
      |> event("cond_update", %{"turn" => "1", "action" => inner["id"], "path" => "0", "op" => "tray_count", "match" => "pride", "cmp" => "eq", "value" => "1", "profile_id" => ""})

    [outer] = actions(socket, chain["id"])
    [inner] = outer["else"]
    assert Enum.map(outer["then"], & &1["type"]) == ["win_rate", "chain_fast"]
    assert Enum.map(inner["then"], & &1["type"]) == ["chain_fast"]
    assert Enum.map(inner["else"], & &1["type"]) == ["chain_a_res"]
    assert BattleStrategies.condition_label(inner["condition"]) == "pride slots = 1"
    assert render(socket) =~ "pride slots = 1"
  end
end
