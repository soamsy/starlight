defmodule StarlightBotWeb.Live.LogLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.LogStore
  alias StarlightBot.Navigation.MachineStatus

  @page_size 2000
  @machine_refresh_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LogStore.subscribe()
      :timer.send_interval(@machine_refresh_ms, :refresh_machines)
    end

    entries = LogStore.recent(@page_size)

    {:ok,
     socket
     |> assign(:machines, machine_rows())
     |> assign(:file_path, LogStore.file_path())
     |> assign(:memory_limit, LogStore.memory_limit())
     |> assign(:shown, length(entries))
     |> assign_oldest(entries)
     |> stream_configure(:entries, dom_id: &"log-#{&1.seq}")
     |> stream(:entries, Enum.reverse(entries))}
  end

  @impl true
  def handle_event("load_older", _, %{assigns: %{oldest_seq: nil}} = socket), do: {:noreply, socket}

  def handle_event("load_older", _, socket) do
    older = LogStore.before(socket.assigns.oldest_seq, @page_size)

    {:noreply,
     socket
     |> update(:shown, &(&1 + length(older)))
     |> assign_oldest(older)
     |> stream(:entries, Enum.reverse(older), at: -1)}
  end

  @impl true
  def handle_info(:refresh_machines, socket), do: {:noreply, assign(socket, :machines, machine_rows())}

  @impl true
  def handle_info({:log_entry, entry}, socket) do
    {:noreply,
     socket
     |> update(:shown, &(&1 + 1))
     |> update(:oldest_seq, &(&1 || entry.seq))
     |> stream_insert(:entries, entry, at: 0)}
  end

  defp machine_rows do
    statuses = MachineStatus.all()
    pids = MapSet.new(statuses, & &1.pid)
    children = Enum.group_by(statuses, &(if MapSet.member?(pids, &1.parent), do: &1.parent, else: :root))
    now = System.monotonic_time(:millisecond)
    flatten(Map.get(children, :root, []), children, 0, now)
  end

  defp flatten(statuses, children, depth, now) do
    statuses
    |> Enum.sort_by(& &1.started_at)
    |> Enum.flat_map(fn status ->
      [Map.merge(status, %{depth: depth, waiting: waiting_text(status.waiting, now)}) | flatten(Map.get(children, status.pid, []), children, depth + 1, now)]
    end)
  end

  defp waiting_text(nil, _now), do: nil
  defp waiting_text({text, deadline}, now), do: "#{text} (#{Float.round(max(deadline - now, 0) / 1000, 1)}s left)"

  def machine_summary([]), do: "idle"

  def machine_summary(rows) do
    deepest = List.last(rows)
    Enum.join(Enum.reject([deepest.current, deepest.waiting, if(deepest.state == :paused, do: "paused")], &is_nil/1), " · ")
  end

  def machine_state_class(:paused), do: "badge-warning"
  def machine_state_class(:polling), do: "badge-info"
  def machine_state_class(_state), do: "badge-ghost"

  defp assign_oldest(socket, []), do: assign_new(socket, :oldest_seq, fn -> nil end)
  defp assign_oldest(socket, [oldest | _]), do: assign(socket, :oldest_seq, oldest.seq)

  def older_available?(nil), do: false

  def older_available?(oldest_seq) do
    case LogStore.first_seq() do
      nil -> false
      first -> first < oldest_seq
    end
  end

  def trimmed?(oldest_seq), do: oldest_seq != nil and not older_available?(oldest_seq) and oldest_seq > 1

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"
end
