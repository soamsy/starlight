defmodule StarlightBotWeb.Components.PlanHistory do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]

  @limit 100
  @typing_window_ms 1000

  def attach(socket, key, opts) do
    state = %{
      key: key,
      persist: Keyword.fetch!(opts, :persist),
      reconcile: Keyword.get(opts, :reconcile, & &1),
      saved: nil,
      past: [],
      future: [],
      mark: nil,
      last: nil
    }

    socket
    |> Phoenix.LiveView.put_private(:plan_history, state)
    |> assign(:can_undo, false)
    |> assign(:can_redo, false)
    |> attach_events()
  end

  defp attach_events(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: Phoenix.LiveView.attach_hook(socket, :plan_history, :handle_event, &handle_event/3),
      else: socket
  end

  defp handle_event("undo", _params, socket), do: {:halt, undo(socket)}
  defp handle_event("redo", _params, socket), do: {:halt, redo(socket)}
  defp handle_event(event, params, socket), do: {:cont, mark(socket, event, params)}

  defp mark(socket, event, params) do
    mark = %{token: make_ref(), key: typing_key(event, params), at: System.monotonic_time(:millisecond)}
    put_state(socket, %{state(socket) | mark: mark})
  end

  defp typing_key(event, %{"_target" => target}), do: {event, target}
  defp typing_key(_event, _params), do: nil

  def reset(socket) do
    case state(socket) do
      nil -> socket
      state -> socket |> put_state(%{state | saved: socket.assigns[state.key], past: [], future: [], last: nil}) |> sync_flags()
    end
  end

  def record(socket) do
    case state(socket) do
      %{saved: nil} = state -> put_state(socket, %{state | saved: socket.assigns[state.key]})
      %{key: key, saved: saved} = state -> record(socket, state, socket.assigns[key], saved)
      nil -> socket
    end
  end

  defp record(socket, _state, data, data), do: socket

  defp record(socket, %{mark: mark, last: last} = state, data, saved) do
    state =
      if merges?(mark, last) do
        %{state | saved: data, last: %{last | at: mark.at}}
      else
        %{state | past: Enum.take([saved | state.past], @limit), future: [], saved: data, last: mark}
      end

    socket |> put_state(state) |> sync_flags()
  end

  defp merges?(nil, _last), do: false
  defp merges?(_mark, nil), do: false
  defp merges?(%{token: token}, %{token: token}), do: true
  defp merges?(%{key: nil}, _last), do: false
  defp merges?(%{key: key, at: at}, %{key: key, at: last_at}), do: at - last_at < @typing_window_ms
  defp merges?(_mark, _last), do: false

  def undo(socket) do
    case state(socket) do
      %{past: [previous | rest]} = state ->
        restore(socket, %{state | past: rest, future: [socket.assigns[state.key] | state.future]}, previous)

      _ ->
        socket
    end
  end

  def redo(socket) do
    case state(socket) do
      %{future: [next | rest]} = state ->
        restore(socket, %{state | future: rest, past: [socket.assigns[state.key] | state.past]}, next)

      _ ->
        socket
    end
  end

  defp restore(socket, state, data) do
    state = %{state | saved: data, last: nil}

    socket
    |> put_state(state)
    |> assign(state.key, data)
    |> state.reconcile.()
    |> state.persist.()
    |> sync_flags()
  end

  defp sync_flags(socket) do
    %{past: past, future: future} = state(socket)
    socket |> assign(:can_undo, past != []) |> assign(:can_redo, future != [])
  end

  defp state(socket), do: socket.private[:plan_history]
  defp put_state(socket, state), do: Phoenix.LiveView.put_private(socket, :plan_history, state)

  attr :can_undo, :boolean, default: false
  attr :can_redo, :boolean, default: false
  attr :locked, :boolean, default: false

  def buttons(assigns) do
    ~H"""
    <button type="button" phx-click="undo" disabled={@locked or not @can_undo} class="btn btn-sm btn-square btn-outline" title="Undo the last change">
      <.icon name="lucide-undo-2" class="size-4" />
    </button>
    <button type="button" phx-click="redo" disabled={@locked or not @can_redo} class="btn btn-sm btn-square btn-outline" title="Redo the change you undid">
      <.icon name="lucide-redo-2" class="size-4" />
    </button>
    """
  end
end
