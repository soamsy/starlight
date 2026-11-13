defmodule StarlightBot.RestCycle do
  alias StarlightBot.{SinnerProfiles, StarlightBudget}

  @max_charge StarlightBudget.rest_per_free_sinner()

  def analyze([]), do: []

  def analyze(entries) do
    sinners = SinnerProfiles.sinners()
    count = length(entries)
    combos = Enum.map(entries, &{&1.team, &1.hook})
    free_numbering = free_numbering(entries, sinners)
    team_numbering = team_numbering(entries, combos)

    grid =
      for {{entry, combo}, index} <- entries |> Enum.zip(combos) |> Enum.with_index() do
        for sinner <- sinners, do: slot(entry, combo, index, sinner, free_numbering, team_numbering)
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

  def estimate_runs, do: 6

  def estimate(assigned, runs \\ estimate_runs()) do
    entries = for hook <- 1..runs, do: %{team: 0, hook: hook, assigned: assigned}
    cycles = analyze(entries)

    per_sinner =
      for sinner <- Map.keys(assigned), into: %{} do
        total = cycles |> Enum.map(fn cycle -> Enum.find(cycle.slots, &(&1.sinner == sinner)).charge end) |> Enum.sum()
        {sinner, total / runs}
      end

    %{runs: runs, free_charge: min(runs - 1, @max_charge), per_sinner: per_sinner, average: per_sinner |> Map.values() |> Enum.sum()}
  end

  defp free_numbering(entries, sinners) do
    indexed = Enum.with_index(entries)

    for sinner <- sinners, into: %{} do
      numbers =
        indexed
        |> Enum.filter(fn {entry, _index} -> assigned_ids(entry, sinner) == [] end)
        |> Enum.with_index(1)
        |> Map.new(fn {{_entry, index}, number} -> {index, number} end)

      {sinner, numbers}
    end
  end

  defp team_numbering(entries, combos) do
    for team <- entries |> Enum.map(& &1.team) |> Enum.uniq(), into: %{} do
      {team, for({entry, combo} <- Enum.zip(entries, combos), entry.team == team, do: combo) |> Enum.uniq()}
    end
  end

  defp slot(entry, combo, index, sinner, free_numbering, team_numbering) do
    case assigned_ids(entry, sinner) do
      [] ->
        number = free_numbering |> Map.fetch!(sinner) |> Map.fetch!(index)
        %{sinner: sinner, kind: :free, number: number, identity: {:free, sinner, index}}

      ids ->
        position = team_numbering |> Map.fetch!(entry.team) |> Enum.find_index(&(&1 == combo)) |> rem(length(ids))
        profile_id = Enum.at(ids, position)
        %{sinner: sinner, kind: :assigned, number: position + 1, of: length(ids), profile_id: profile_id, identity: {:profile, sinner, profile_id}}
    end
  end

  defp assigned_ids(%{assigned: assigned}, sinner), do: Map.get(assigned, sinner, [])
end
