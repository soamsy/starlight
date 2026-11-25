defmodule StarlightBot.Perf.Procs do
  @clk_tck 100
  @root_comm "starlight"
  @child_labels [{"WebKitWebProces", "web"}, {"WebKitNetworkPr", "network"}, {"WebKitGPUProces", "gpu"}]
  @thread_rows 6

  def discover do
    stats = proc_stats()
    roots = for {pid, {comm, _ppid}} <- stats, comm == @root_comm, do: pid

    children =
      for {pid, {comm, ppid}} <- stats, ppid in roots, {prefix, label} <- @child_labels, String.starts_with?(comm, prefix), do: {pid, label}

    Enum.map(roots, &{&1, "app"}) ++ children
  end

  def sample(targets) do
    for {pid, label} <- targets, threads = read_threads(pid), threads != %{}, into: %{} do
      {pid, %{label: label, threads: threads}}
    end
  end

  def cpu(prev, now, seconds) do
    now
    |> Enum.map(fn {pid, %{label: label, threads: threads}} ->
      old = get_in(prev, [pid, :threads]) || %{}

      deltas =
        for {tid, {name, ticks}} <- threads do
          {name, max(ticks - elem(Map.get(old, tid, {name, ticks}), 1), 0) * 100 / (@clk_tck * seconds)}
        end

      by_name = Enum.reduce(deltas, %{}, fn {name, pct}, acc -> Map.update(acc, name, pct, &(&1 + pct)) end)
      total = by_name |> Map.values() |> Enum.sum()
      top = by_name |> Enum.sort_by(fn {_name, pct} -> -pct end) |> Enum.take(@thread_rows) |> Enum.map(fn {name, pct} -> {name, Float.round(pct, 1)} end)
      %{pid: pid, label: label, cpu: Float.round(total, 1), threads: top}
    end)
    |> Enum.sort_by(& &1.pid)
  end

  defp proc_stats do
    for entry <- File.ls!("/proc"),
        pid = parse_int(entry),
        pid != nil,
        {:ok, raw} <- [File.read("/proc/#{entry}/stat")],
        {comm, _rest} = split_stat(raw),
        [ppid | _] = fields_after_comm(raw),
        into: %{} do
      {pid, {comm, String.to_integer(ppid)}}
    end
  end

  defp read_threads(pid) do
    case File.ls("/proc/#{pid}/task") do
      {:ok, tids} ->
        for tid <- tids, {:ok, raw} <- [File.read("/proc/#{pid}/task/#{tid}/stat")], into: %{} do
          {comm, _} = split_stat(raw)
          fields = fields_after_comm(raw)
          {String.to_integer(tid), {comm, String.to_integer(Enum.at(fields, 10)) + String.to_integer(Enum.at(fields, 11))}}
        end

      {:error, _} ->
        %{}
    end
  end

  defp split_stat(raw) do
    [_, comm, rest] = Regex.run(~r/^\d+ \((.*)\) (.*)$/s, raw)
    {comm, rest}
  end

  defp fields_after_comm(raw) do
    {_comm, rest} = split_stat(raw)
    rest |> String.trim() |> String.split(" ") |> Enum.drop(1)
  end

  defp parse_int(entry) do
    case Integer.parse(entry) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
