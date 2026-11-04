defmodule StarlightBot.Scheduler.Overview do
  alias StarlightBot.{DailyProgress, EnkephalinSchedule, Scheduler}

  def build(now \\ Scheduler.local_now()) do
    runs = Scheduler.get_settings()
    charger = EnkephalinSchedule.get_settings()
    remaining = DailyProgress.remaining(runs)
    blocked = Scheduler.blocked()
    busy? = Scheduler.busy?()

    %{
      runs_on: runs.enabled,
      charger_on: charger.enabled,
      blocked: blocked,
      runs_pending: DailyProgress.pending?(remaining),
      runs_text: runs.enabled && (Scheduler.outlook(now, runs, remaining, busy?, blocked) || close_text(runs, busy?)),
      charge_text: EnkephalinSchedule.outlook(now, charger, blocked, busy?),
      label: label(now, runs, remaining, charger, blocked, busy?)
    }
  end

  defp close_text(%{close_game_when_done: true}, true) do
    if close_armed?(), do: "Will close Limbus when this run finishes if the daily goals are met"
  end

  defp close_text(_runs, _busy?), do: nil

  defp close_armed? do
    GenServer.whereis(Scheduler.Server) != nil and Scheduler.Server.status().close_armed
  end

  def label(now, runs, remaining, charger, blocked, busy?) do
    upcoming =
      [
        {"Runs", runs.enabled && DailyProgress.pending?(remaining) && Scheduler.next_start(now, runs, blocked)},
        {"Charge", charger.enabled && EnkephalinSchedule.next_charge(now, charger, blocked)}
      ]
      |> Enum.filter(fn {_name, at} -> at end)

    cond do
      not runs.enabled and not charger.enabled -> "off"
      busy? -> "busy now"
      upcoming == [] -> "done today"
      blocked -> "held until #{Scheduler.clock12(Scheduler.to_local(elem(blocked, 1)))}"
      true -> upcoming |> Enum.min_by(&elem(&1, 1), NaiveDateTime) |> upcoming_label(now)
    end
  end

  defp upcoming_label({name, at}, now) do
    case NaiveDateTime.diff(at, now, :second) do
      seconds when seconds <= 0 -> "#{name} due now"
      seconds -> "#{name} in #{Scheduler.duration_label(seconds)}"
    end
  end
end
