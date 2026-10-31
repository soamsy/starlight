defmodule StarlightBot.DailyProgress do
  import Ecto.Query
  alias StarlightBot.{LuxSchedule, RunsRepo}

  @kinds ~w(exp thread md)

  def kinds, do: @kinds

  def record(kind, amount, %DateTime{} = at \\ DateTime.utc_now()) when kind in @kinds and is_integer(amount) and amount > 0 do
    RunsRepo.insert_all("daily_progress", [%{kind: kind, amount: amount, completed_at: DateTime.to_iso8601(DateTime.truncate(at, :second))}])
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, "scheduler", :daily_progress)
    :ok
  end

  def completed(%DateTime{} = now \\ DateTime.utc_now()) do
    since = DateTime.to_iso8601(LuxSchedule.day_start(now))

    totals =
      RunsRepo.all(
        from(p in "daily_progress",
          where: p.completed_at >= ^since,
          group_by: p.kind,
          select: {p.kind, sum(p.amount)}
        )
      )
      |> Map.new()

    Map.new(@kinds, fn kind -> {kind, Map.get(totals, kind, 0)} end)
  end

  def targets(settings), do: %{"exp" => settings.exp_waves, "thread" => settings.thread_waves, "md" => settings.md_runs}

  def remaining(settings, %DateTime{} = now \\ DateTime.utc_now()) do
    done = completed(now)
    Map.new(targets(settings), fn {kind, target} -> {kind, max(target - done[kind], 0)} end)
  end

  def remaining_label(remaining) do
    [{"exp", "EXP wave", "s"}, {"thread", "thread wave", "s"}, {"md", "MD run", "s"}]
    |> Enum.filter(fn {kind, _, _} -> remaining[kind] > 0 end)
    |> Enum.map_join(", ", fn {kind, label, plural} -> "#{remaining[kind]} #{label}#{if remaining[kind] == 1, do: "", else: plural}" end)
  end

  def pending?(remaining), do: Enum.any?(remaining, fn {_kind, left} -> left > 0 end)
end
