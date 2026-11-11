defmodule StarlightBotWeb.Components.PlanHistoryTest do
  use ExUnit.Case, async: true

  alias StarlightBotWeb.Components.PlanHistory

  defp socket(data) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, data: data, persisted: []}}
    |> PlanHistory.attach(:data, persist: &persist/1)
    |> PlanHistory.reset()
  end

  defp persist(socket), do: Phoenix.Component.update(socket, :persisted, &[socket.assigns.data | &1])

  defp edit(socket, data, mark \\ nil) do
    state = %{socket.private.plan_history | mark: mark}

    socket
    |> Phoenix.LiveView.put_private(:plan_history, state)
    |> Phoenix.Component.assign(:data, data)
    |> PlanHistory.record()
  end

  defp mark(key, at), do: %{token: make_ref(), key: key, at: at}

  test "undo and redo walk the recorded states" do
    socket = socket(%{n: 0}) |> edit(%{n: 1}) |> edit(%{n: 2})
    assert socket.assigns.can_undo
    refute socket.assigns.can_redo

    socket = PlanHistory.undo(socket)
    assert socket.assigns.data == %{n: 1}
    assert socket.assigns.persisted == [%{n: 1}]
    assert socket.assigns.can_redo

    socket = socket |> PlanHistory.undo() |> PlanHistory.undo()
    assert socket.assigns.data == %{n: 0}
    refute socket.assigns.can_undo

    socket = socket |> PlanHistory.redo() |> PlanHistory.redo()
    assert socket.assigns.data == %{n: 2}
    refute socket.assigns.can_redo
  end

  test "a new edit clears redo" do
    socket = socket(%{n: 0}) |> edit(%{n: 1}) |> PlanHistory.undo() |> edit(%{n: 5})
    refute socket.assigns.can_redo
    assert PlanHistory.undo(socket).assigns.data == %{n: 0}
  end

  test "unchanged data records nothing" do
    socket = socket(%{n: 0}) |> edit(%{n: 0})
    refute socket.assigns.can_undo
  end

  test "persists within one event share a single undo step" do
    event = mark(nil, 0)
    socket = socket(%{n: 0}) |> edit(%{n: 1}, event) |> edit(%{n: 2}, event)
    socket = PlanHistory.undo(socket)
    assert socket.assigns.data == %{n: 0}
    refute socket.assigns.can_undo
  end

  test "rapid form changes on the same field coalesce, other fields and pauses do not" do
    socket =
      socket(%{text: ""})
      |> edit(%{text: "a"}, mark({"update", ["name"]}, 0))
      |> edit(%{text: "ab"}, mark({"update", ["name"]}, 400))
      |> edit(%{text: "abc"}, mark({"update", ["name"]}, 900))

    assert PlanHistory.undo(socket).assigns.data == %{text: ""}

    paused = socket(%{text: ""}) |> edit(%{text: "a"}, mark({"update", ["name"]}, 0)) |> edit(%{text: "ab"}, mark({"update", ["name"]}, 2000))
    assert PlanHistory.undo(paused).assigns.data == %{text: "a"}

    other = socket(%{text: ""}) |> edit(%{text: "a"}, mark({"update", ["name"]}, 0)) |> edit(%{text: "ab"}, mark({"update", ["note"]}, 100))
    assert PlanHistory.undo(other).assigns.data == %{text: "a"}
  end

  test "history is capped" do
    socket = Enum.reduce(1..150, socket(%{n: 0}), &edit(&2, %{n: &1}))
    socket = Enum.reduce(1..150, socket, fn _, acc -> PlanHistory.undo(acc) end)
    assert socket.assigns.data == %{n: 50}
  end

  test "reconcile runs on restore" do
    socket =
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, data: %{n: 0}, persisted: [], seen: nil}}
      |> PlanHistory.attach(:data, persist: &persist/1, reconcile: &Phoenix.Component.assign(&1, :seen, &1.assigns.data))
      |> PlanHistory.reset()
      |> edit(%{n: 1})
      |> PlanHistory.undo()

    assert socket.assigns.seen == %{n: 0}
  end
end
