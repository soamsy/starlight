defmodule StarlightBotWeb.Live.PackPlanCopyTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Plans, Teams}
  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  test "a copied pack plan pastes into another team and keeps its plan" do
    data = %{"version" => 1, "mode_schedule" => [%{"from_floor" => 4, "mode" => "hard"}], "search_floors" => [5], "packs" => %{"thm_3" => %{"normal" => %{"priority" => "hunt"}}}}
    {:ok, source} = Teams.create_default_team()
    {:ok, target} = Teams.create_default_team()
    source_plan = Teams.get_team(source).pack_plan_id
    target_plan = Teams.get_team(target).pack_plan_id
    {:ok, _} = Plans.save(:pack_plans, %{id: source_plan, name: Plans.get(:pack_plans, source_plan).name, data: data})

    bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, source_socket} = Live.mount(%{}, %{"team_id" => source}, bare)
    {:noreply, source_socket} = Live.handle_event("copy_plan", %{}, source_socket)
    [["copy_plan_json", %{text: text}]] = source_socket.private.live_temp.push_events

    {:ok, socket} = Live.mount(%{}, %{"team_id" => target}, bare)
    status = fn socket, text ->
      {:noreply, socket} = Live.handle_event("clipboard_status", %{"text" => text}, socket)
      socket.assigns.paste_status
    end

    assert status.(socket, text) == :different
    assert status.(socket, "nope") == :invalid
    assert status.(socket, nil) == :unknown

    {:noreply, socket} = Live.handle_event("paste_plan", %{"text" => text}, socket)
    assert socket.assigns.paste_status == :same
    assert status.(socket, text) == :same

    assert socket.assigns.editing_id == target_plan
    assert Plans.get(:pack_plans, target_plan).data == data
    assert Teams.get_team(target).pack_plan_id == target_plan
    assert Plans.get(:pack_plans, source_plan).data == data
    assert socket.assigns.flash == %{"info" => "Plan pasted."}

    {:noreply, socket} = Live.handle_event("paste_plan", %{"text" => "nope"}, socket)
    assert socket.assigns.flash["error"] == "The clipboard doesn't hold a Starlight plan."
  end
end
