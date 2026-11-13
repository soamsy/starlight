defmodule StarlightBot.RestCycle do
  alias StarlightBot.{SinnerProfiles, StarlightBudget}

  @max_charge StarlightBudget.rest_per_free_sinner()

  def analyze([]), do: []

  def analyze(entries) do
    sinners = SinnerProfiles.sinners()
    count = length(entries)
    combos = Enum.map(entries, &{&1.team, &1.hook})
    free_numbering = free_numbering(entries, combos, sinners)
    team_numbering = team_numbering(entries, combos)

    grid =
      for {entry, combo} <- Enum.zip(entries, combos) do
        for sinner <- sinners, do: slot(entry, combo, sinner, free_numbering, team_numbering)
      end

    identities = grid |> Enum.map(fn row -> row |> Enum.map(& &1.identity) |> List.to_tuple() end) |> List.to_tuple()

    for {row, index} <- Enum.with_index(grid) do
      slots =
        for {slot, column} <- Enum.with_index(row) do
          steps = Enum.find(1..count, count, &(identities |> elem(Integer.mod(index - &1, count)) |> elem(column) == slot.identity))
          slot |> Map.delete(:identity) |> Map.merge(%{gap: steps - 1, charge: min(steps - 1, @max_charge)})
        end

      free = Enum.filter(slots, &(&1.kind == :free))
      assigned = Enum.filter(slots, &(&1.kind == :assigned))

      %{
        slots: slots,
        free_count: length(free),
        assigned_bonus: assigned |> Enum.map(& &1.charge) |> Enum.sum(),
        free_limit: free |> Enum.map(& &1.charge) |> Enum.sum(),
        gap: free |> Enum.map(& &1.gap) |> Enum.min(fn -> 0 end)
      }
    end
  end

  defp free_numbering(entries, combos, sinners) do
    for sinner <- sinners, into: %{} do
      distinct =
        for({entry, combo} <- Enum.zip(entries, combos), assigned_ids(entry, sinner) == [], do: combo)
        |> Enum.uniq()

      {sinner, distinct}
    end
  end

  defp team_numbering(entries, combos) do
    for team <- entries |> Enum.map(& &1.team) |> Enum.uniq(), into: %{} do
      {team, for({entry, combo} <- Enum.zip(entries, combos), entry.team == team, do: combo) |> Enum.uniq()}
    end
  end

  defp slot(entry, combo, sinner, free_numbering, team_numbering) do
    case assigned_ids(entry, sinner) do
      [] ->
        number = free_numbering |> Map.fetch!(sinner) |> Enum.find_index(&(&1 == combo)) |> Kernel.+(1)
        %{sinner: sinner, kind: :free, number: number, identity: {:free, sinner, number}}

      ids ->
        position = team_numbering |> Map.fetch!(entry.team) |> Enum.find_index(&(&1 == combo)) |> rem(length(ids))
        profile_id = Enum.at(ids, position)
        %{sinner: sinner, kind: :assigned, number: position + 1, of: length(ids), profile_id: profile_id, identity: {:profile, sinner, profile_id}}
    end
  end

  defp assigned_ids(%{assigned: assigned}, sinner), do: Map.get(assigned, sinner, [])
end
