defmodule StarlightBotWeb.Live.PackPlanDuplicateTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Plans, Repo}
  alias StarlightBotWeb.Live.PackPlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    %{socket: socket}
  end

  test "duplicating a plan saves a copy with the same data and opens it", %{socket: socket} do
    data = %{"version" => 1, "mode_schedule" => [%{"from_floor" => 4, "mode" => "hard"}], "search_floors" => [5], "packs" => %{"thm_3" => %{"normal" => %{"priority" => "hunt"}}}}
    {:ok, id} = Plans.save(:pack_plans, %{name: "Saikai", data: data})

    {:noreply, socket} = Live.handle_event("duplicate_plan", %{"id" => Integer.to_string(id)}, socket)

    copy = Plans.get(:pack_plans, socket.assigns.editing_id)
    assert copy.id != id
    assert copy.name == "Saikai (copy)"
    assert copy.data == data
    assert Enum.map(socket.assigns.plans, & &1.name) |> Enum.sort() == ["Saikai", "Saikai (copy)"]
  end
end
