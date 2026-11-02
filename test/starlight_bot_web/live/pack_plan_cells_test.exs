defmodule StarlightBotWeb.Live.PackPlanCellsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Plans, Teams}
  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

  setup do
    :ok = StarlightBot.TestDB.checkout()
    {:ok, team} = Teams.create_default_team()
    plan_id = Teams.get_team(team).pack_plan_id
    bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = Live.mount(%{}, %{"team_id" => team}, bare)

    pack = fn id -> %{id: id, name_en: id, normal_floors: "[1,2,3]", hard_floors: "[1,2,3]", image_path: "/x.webp"} end
    packs = [pack.("thm_a"), pack.("thm_b")]
    socket = Phoenix.Component.assign(socket, theme_packs: packs, packs_by_id: Map.new(packs, &{&1.id, &1}))
    %{socket: socket, plan_id: plan_id}
  end

  defp send_event(socket, event, params) do
    {:noreply, socket} = Live.handle_event(event, params, socket)
    socket
  end

  defp cell(socket, action, floors, pack_id \\ "thm_a", mode \\ "normal") do
    send_event(socket, "toggle_cell", %{"pack_id" => pack_id, "mode" => mode, "floors" => floors, "action" => action})
  end

  defp packs(socket), do: socket.assigns.plan_data["packs"]

  test "a pack can be favorite on one floor and banned on the next", %{socket: socket, plan_id: plan_id} do
    socket = socket |> cell("hunt", "1") |> cell("favorite", "1") |> cell("banned", "2")

    assert packs(socket) == %{"thm_a" => %{"normal" => %{"1" => "favorite", "2" => "banned"}}}
    assert Plans.get(:pack_plans, plan_id).data["packs"] == packs(socket)
  end

  test "hunting on one floor and favoriting only on the next", %{socket: socket} do
    socket = socket |> cell("hunt", "1") |> cell("hunt", "2") |> cell("favorite", "2")
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "hunt", "2" => "favorite"}
  end

  test "clicking a favorite or hunted cell clears it and empties the plan", %{socket: socket} do
    socket = socket |> cell("hunt", "1") |> cell("favorite", "1") |> cell("hunt", "1")
    assert packs(socket) == %{}
    refute Map.has_key?(socket.assigns.plan_data, "order")
  end

  test "right click toggles banned and left click turns banned into hunt", %{socket: socket} do
    socket = cell(socket, "banned", "1")
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "banned"}
    assert socket |> cell("banned", "1") |> packs() == %{}
    assert socket |> cell("hunt", "1") |> packs() == %{"thm_a" => %{"normal" => %{"1" => "hunt"}}}
  end

  test "floors a pack cannot appear on are ignored", %{socket: socket} do
    assert socket |> cell("hunt", "9") |> packs() == %{}
  end

  test "the order of a floor is independent of other floors and survives favoriting", %{socket: socket} do
    socket =
      socket
      |> cell("hunt", "1,2", "thm_a")
      |> cell("hunt", "1", "thm_b")
      |> cell("hunt", "2", "thm_b")
      |> send_event("path_reorder", %{"scope" => "normal:2:rest", "ids" => ["thm_b", "thm_a"]})

    assert socket.assigns.plan_data["order"]["normal"] == %{"1" => ["thm_a", "thm_b"], "2" => ["thm_b", "thm_a"]}

    socket = cell(socket, "favorite", "1", "thm_a")
    assert socket.assigns.plan_data["order"]["normal"]["1"] == ["thm_a", "thm_b"]
  end

  test "dragging between the dropdown lists changes the status on that floor only", %{socket: socket} do
    socket =
      socket
      |> cell("hunt", "1,2", "thm_a")
      |> send_event("path_move", %{"scope" => "normal:1:fav", "id" => "thm_a", "ids" => ["thm_a"]})

    assert packs(socket)["thm_a"]["normal"] == %{"1" => "favorite", "2" => "hunt"}

    socket = send_event(socket, "toggle_favorite", %{"pack_id" => "thm_a", "mode" => "normal", "floor" => "2"})
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "favorite", "2" => "favorite"}
  end

  test "clearing a floor removes hunted packs there but keeps bans and other floors", %{socket: socket} do
    socket =
      socket
      |> cell("hunt", "1,2", "thm_a")
      |> cell("banned", "1", "thm_b")
      |> send_event("path_clear_floor", %{"floor" => "1"})

    assert packs(socket) == %{"thm_a" => %{"normal" => %{"2" => "hunt"}}, "thm_b" => %{"normal" => %{"1" => "banned"}}}
  end

  defp html(socket) do
    assigns = Map.put(socket.assigns, :__changed__, nil)
    assigns |> Live.render() |> Phoenix.LiveViewTest.rendered_to_string()
  end

  test "the chart shows a star on hunted floors and no priority lists", %{socket: socket} do
    socket = socket |> cell("hunt", "1") |> cell("hunt", "2") |> cell("favorite", "2") |> cell("banned", "3")
    html = html(socket)

    assert html =~ ~s(phx-value-action="favorite")
    assert html =~ "bg-warning/30"
    assert html =~ "bg-success/30"
    assert html =~ "bg-error/30"
    assert html =~ "★"
    refute html =~ "priority-list-"
    refute html =~ "copy_priority"
  end

  defp row_status(socket, status, floors \\ "1,2,3") do
    send_event(socket, "set_row_status", %{"pack_id" => "thm_a", "mode" => "normal", "floors" => floors, "status" => status})
  end

  test "a row status button sets every floor, then clears them all", %{socket: socket} do
    socket = socket |> cell("hunt", "1") |> cell("banned", "2") |> row_status("favorite")
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "favorite", "2" => "favorite", "3" => "favorite"}

    socket = row_status(socket, "favorite")
    assert packs(socket) == %{}
    refute Map.has_key?(socket.assigns.plan_data, "order")
  end

  test "switching a row between statuses replaces the old one on every floor", %{socket: socket} do
    socket = socket |> row_status("hunt") |> row_status("banned")
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "banned", "2" => "banned", "3" => "banned"}
    assert socket.assigns.plan_data["order"] == nil
  end

  test "a row button only touches the floors its row shows", %{socket: socket} do
    socket = socket |> cell("banned", "3") |> row_status("hunt", "1,2")
    assert packs(socket)["thm_a"]["normal"] == %{"1" => "hunt", "2" => "hunt", "3" => "banned"}
  end
end
