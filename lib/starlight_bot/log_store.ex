defmodule StarlightBot.LogStore do
  use GenServer

  @table :starlight_log
  @topic "log"
  @memory_limit 200_000
  @retention_days 7
  @prune_every_ms 6 * 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def append(kind, text, lineage \\ []), do: GenServer.cast(__MODULE__, {:append, now(), kind, text, lineage})

  def now do
    ms = System.os_time(:millisecond)
    ms |> :calendar.system_time_to_local_time(:millisecond) |> NaiveDateTime.from_erl!({rem(ms, 1000) * 1000, 3})
  end

  def memory_limit, do: @memory_limit

  def recent(count), do: before(:infinity, count)

  def all, do: recent(@memory_limit)

  def before(seq, count) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      collect_before(@table, seq, count, [])
    end
  end

  def file_path, do: GenServer.call(__MODULE__, :file_path)

  def files do
    case StarlightBot.Data.log_dir() do
      nil -> []
      dir -> dir |> Path.join("starlight_*.log") |> Path.wildcard() |> Enum.map(&Path.expand/1) |> Enum.sort(:desc)
    end
  end

  def read_file(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reduce([], &parse_line/2)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, seq} -> Map.put(entry, :seq, seq) end)
  end

  defp parse_line(line, acc) do
    with [_, stamp, kind, text] <- Regex.run(~r/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) \[(\w+)\] (.*)$/, line),
         {:ok, at} <- NaiveDateTime.from_iso8601(stamp) do
      [%{at: at, kind: String.to_atom(kind), text: text, lineage: []} | acc]
    else
      _ -> continue_entry(line, acc)
    end
  end

  defp continue_entry(line, [head | rest]), do: [%{head | text: head.text <> "\n" <> line} | rest]
  defp continue_entry(_line, []), do: []

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
    dir = StarlightBot.Data.log_dir()
    {path, device} = open_file(dir)
    send(self(), :prune)
    {:ok, %{seq: 0, path: path, device: device, dir: dir}}
  end

  @impl true
  def handle_cast({:append, at, kind, text, lineage}, state) do
    seq = state.seq + 1
    entry = %{seq: seq, at: at, kind: kind, text: to_string(text), lineage: lineage}
    :ets.insert(@table, {seq, entry})
    if seq > @memory_limit, do: :ets.delete(@table, seq - @memory_limit)
    if state.device, do: IO.write(state.device, format(entry) <> "\n")
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:log_entry, entry})
    {:noreply, %{state | seq: seq}}
  end

  @impl true
  def handle_call(:file_path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_info(:prune, state) do
    prune(state.dir, state.path)
    Process.send_after(self(), :prune, @prune_every_ms)
    {:noreply, state}
  end

  def prune(nil, _current_path), do: :ok

  def prune(dir, current_path) do
    cutoff = System.os_time(:second) - @retention_days * 24 * 60 * 60

    [Path.join(dir, "starlight_*.log"), Path.join([dir, "timeouts", "*.png"])]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&(Path.expand(&1) == current_path))
    |> Enum.filter(&older_than?(&1, cutoff))
    |> Enum.each(&File.rm/1)
  end

  defp older_than?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < cutoff
      {:error, _} -> false
    end
  end

  defp open_file(nil), do: {nil, nil}

  defp open_file(dir) do
    File.mkdir_p!(dir)
    stamp = NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string() |> String.replace([" ", ":"], "_")
    path = Path.expand(Path.join(dir, "starlight_#{stamp}.log"))
    {path, File.open!(path, [:append, :utf8, {:delayed_write, 64_000, 1_000}])}
  end
end
