defmodule StarlightBot.LuxSchedule do
  @reset_offset_secs 3 * 3600
  @weekdays ~w(Sun Mon Tue Wed Thu Fri Sat)
  @sins ~w(wrath lust sloth gluttony gloom pride envy)a

  @exp_slots [
    %{days: [0], types: [:slash, :pierce, :blunt]},
    %{days: [1, 2], types: [:slash]},
    %{days: [3, 4], types: [:pierce]},
    %{days: [5, 6], types: [:blunt]}
  ]

  def today, do: today(DateTime.utc_now())

  def today(%DateTime{} = now), do: now |> game_date() |> Date.day_of_week() |> rem(7)

  def game_date(%DateTime{} = now), do: now |> DateTime.add(@reset_offset_secs) |> DateTime.to_date()

  def day_start(%DateTime{} = now) do
    now |> game_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.add(-@reset_offset_secs)
  end

  def exp_slot_count, do: length(@exp_slots)
  def thread_slot_count, do: length(@sins)

  def exp_slot(day), do: Enum.find_index(@exp_slots, &(day in &1.days))

  def exp_slot_label(slot), do: @exp_slots |> Enum.at(slot) |> Map.fetch!(:days) |> Enum.map_join(" ", &Enum.at(@weekdays, &1))

  def exp_slot_types(slot), do: @exp_slots |> Enum.at(slot) |> Map.fetch!(:types)

  def thread_slot_label(slot), do: Enum.at(@weekdays, slot)

  def thread_slot_sin(slot), do: Enum.at(@sins, slot)
end
