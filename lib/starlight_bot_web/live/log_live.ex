defmodule StarlightBotWeb.Live.LogLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.LogStore

  @page_size 2000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: LogStore.subscribe()
    entries = LogStore.recent(@page_size)

    {:ok,
     socket
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
  def handle_info({:log_entry, entry}, socket) do
    {:noreply,
     socket
     |> update(:shown, &(&1 + 1))
     |> update(:oldest_seq, &(&1 || entry.seq))
     |> stream_insert(:entries, entry, at: 0)}
  end

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
