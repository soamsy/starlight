defmodule StarlightBotWeb.Live.ThemePackPlanDuplicateTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Repo, Strategies}
  alias StarlightBotWeb.Live.ThemePackPlanEditorLive, as: Live

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {:ok, socket} = Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
    %{socket: socket}
  end

  test "duplicating a plan saves a copy with the same data and opens it", %{socket: socket} do
    data = %{"version" => 1, "mode_schedule" => [%{"from_floor" => 4, "mode" => "hard"}], "search_floors" => [5], "packs" => %{"thm_3" => %{"normal" => %{"priority" => "hunt"}}}}
    {:ok, id} = Strategies.save(:theme_pack_plans, %{name: "Saikai", data: data})

    {:noreply, socket} = Live.handle_event("duplicate_plan", %{"id" => Integer.to_string(id)}, socket)

    copy = Strategies.get(:theme_pack_plans, socket.assigns.editing_id)
    assert copy.id != id
    assert copy.name == "Saikai (copy)"
    assert copy.data == data
    assert Enum.map(socket.assigns.plans, & &1.name) |> Enum.sort() == ["Saikai", "Saikai (copy)"]
  end
end
