defmodule StarlightBot.LogStore do
  use GenServer

  @table :starlight_log
  @topic "log"
  @memory_limit 200_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def append(kind, text), do: GenServer.cast(__MODULE__, {:append, now(), kind, text})

  def now do
    ms = System.os_time(:millisecond)
    ms |> :calendar.system_time_to_local_time(:millisecond) |> NaiveDateTime.from_erl!({rem(ms, 1000) * 1000, 3})
  end

  def memory_limit, do: @memory_limit

  def recent(count), do: before(:infinity, count)

  def before(seq, count) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      collect_before(@table, seq, count, [])
    end
  end

  def first_seq do
    case :ets.whereis(@table) != :undefined and :ets.first(@table) do
      seq when is_integer(seq) -> seq
      _ -> nil
    end
  end

  def file_path, do: GenServer.call(__MODULE__, :file_path)

  def format(entry), do: "#{format_time(entry.at)} [#{entry.kind}] #{entry.text}"

  def format_time(at), do: at |> NaiveDateTime.truncate(:millisecond) |> NaiveDateTime.to_string()

  defp collect_before(_table, _seq, 0, acc), do: acc

  defp collect_before(table, seq, count, acc) do
    case if(seq == :infinity, do: :ets.last(table), else: :ets.prev(table, seq)) do
      :"$end_of_table" ->
        acc

      prev ->
        [{^prev, entry}] = :ets.lookup(table, prev)
        collect_before(table, prev, count - 1, [entry | acc])
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    {path, device} = open_file(Application.get_env(:starlight_bot, :bot_log_dir, "log"))
    {:ok, %{seq: 0, path: path, device: device}}
  end

  @impl true
  def handle_cast({:append, at, kind, text}, state) do
    seq = state.seq + 1
    entry = %{seq: seq, at: at, kind: kind, text: to_string(text)}
    :ets.insert(@table, {seq, entry})
    if seq > @memory_limit, do: :ets.delete(@table, seq - @memory_limit)
    if state.device, do: IO.write(state.device, format(entry) <> "\n")
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:log_entry, entry})
    {:noreply, %{state | seq: seq}}
  end

  @impl true
  def handle_call(:file_path, _from, state), do: {:reply, state.path, state}

  defp open_file(nil), do: {nil, nil}

  defp open_file(dir) do
    File.mkdir_p!(dir)
    stamp = NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string() |> String.replace([" ", ":"], "_")
    path = Path.expand(Path.join(dir, "starlight_#{stamp}.log"))
    {path, File.open!(path, [:append, :utf8, {:delayed_write, 64_000, 1_000}])}
  end
end
