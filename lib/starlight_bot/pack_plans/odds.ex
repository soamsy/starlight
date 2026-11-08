defmodule StarlightBot.PackPlans.Odds do
  alias StarlightBot.Automation.Scripts.ThemePackSelector
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBot.{StarlightBudget, ThemePacks}

  @prune 1.0e-9
  @pinned_floor 5

  def for_run(plan_data, theme_packs, floor_modes, grace_picks), do: run(plan_data, theme_packs, floor_modes, grace_picks).floors

  def run(plan_data, theme_packs, floor_modes, grace_picks) do
    setups = Enum.map(floor_modes, fn {floor, mode} -> {floor, setup(plan_data, theme_packs, mode, floor, grace_picks)} end)
    pool_ids = Map.new(setups, fn {floor, setup} -> {floor, setup.pool_ids} end)

    {results, states} =
      Enum.map_reduce(setups, %{{MapSet.new(), 0} => 1.0}, fn {floor, setup}, states ->
        later = for {other, ids} <- pool_ids, other > floor, reduce: MapSet.new(), do: (acc -> MapSet.union(acc, ids))
        {marginal, available, searched, next} = advance(setup, states, later)
        {{floor, finish(setup, marginal, available, searched)}, next}
      end)

    searches = Enum.reduce(states, %{}, fn {{_taken, count}, weight}, acc -> Map.update(acc, count, weight, &(&1 + weight)) end)
    %{floors: Map.new(results), searches: searches}
  end

  def expected_search_cost(searches) do
    Enum.sum(for {count, prob} <- searches, do: prob * StarlightBudget.pack_search_cost(count))
  end

  def expected_searches(searches), do: Enum.sum(for {count, prob} <- searches, do: prob * count)

  defp setup(plan_data, theme_packs, mode, floor, grace_picks) do
    pool = ThemePackSelector.floor_pool(theme_packs, mode, floor)
    {hunt, backup} = ThemePackSelector.hunt_and_backup(plan_data, theme_packs, mode, floor)
    overrides = Enum.filter(pool, &Resolver.extreme_override?(plan_data, &1.id, mode))
    hunting? = overrides != [] or ThemePackSelector.packs_with_priority(plan_data, theme_packs, mode, floor, "hunt") != []
    wanted = if hunting?, do: Enum.uniq_by(overrides ++ hunt, & &1.id), else: []
    backup = Enum.reject(backup, fn pack -> Enum.any?(wanted, &(&1.id == pack.id)) end)
    refreshes = ThemePackSelector.refresh_budget(grace_picks)
    listed_ids = MapSet.new(wanted ++ backup, & &1.id)
    unlisted = Enum.filter(pool, &(not MapSet.member?(listed_ids, &1.id) and Resolver.priority_at(plan_data, &1, mode, floor) != "banned"))
    fallback_railway_share = if unlisted == [], do: 0.0, else: Enum.count(unlisted, &StarlightBudget.railway_pack?/1) / length(unlisted)

    fallback_floating = if unlisted == [], do: 0.0, else: Enum.sum(Enum.map(unlisted, &ThemePacks.floating_nodes/1)) / length(unlisted)

    %{
      fallback_railway_share: fallback_railway_share,
      fallback_floating: fallback_floating,
      pool_ids: MapSet.new(pool, & &1.id),
      pool_count: length(pool),
      wanted: wanted,
      backup: backup,
      hunting?: hunting?,
      shown: ThemePackSelector.expected_pack_count(grace_picks) - if(floor == @pinned_floor, do: 1, else: 0),
      refreshes: refreshes,
      looks: refreshes + 1,
      searching?: Resolver.searchable_floor?(floor) and floor in Map.get(plan_data, "search_floors", [])
    }
  end

  defp outcome(%{hunting?: false}, _taken), do: []

  defp outcome(setup, taken) do
    {wanted, backup, pool} = remaining(setup, taken)

    cond do
      setup.searching? ->
        case wanted do
          [top | _] -> [{top.id, 1.0}]
          [] -> []
        end

      true ->
        odds = ranked(pool, setup.shown, length(wanted), length(backup), setup.looks)
        Enum.zip(Enum.map(wanted, & &1.id), odds.wanted) ++ Enum.zip(Enum.map(backup, & &1.id), odds.backup)
    end
  end

  defp remaining(setup, taken) do
    wanted = Enum.reject(setup.wanted, &MapSet.member?(taken, &1.id))
    backup = Enum.reject(setup.backup, &MapSet.member?(taken, &1.id))
    pool = setup.pool_count - Enum.count(setup.pool_ids, &MapSet.member?(taken, &1))
    {wanted, backup, pool}
  end

  defp search_chance(%{searching?: true, hunting?: true} = setup, taken) do
    case remaining(setup, taken) do
      {[], _backup, _pool} -> 0.0
      {wanted, _backup, pool} -> ranked(pool, setup.shown, length(wanted), 0, setup.looks).miss |> :math.pow(setup.looks)
    end
  end

  defp search_chance(_setup, _taken), do: 0.0

  defp advance(setup, states, later) do
    listed = Enum.map(setup.wanted ++ setup.backup, & &1.id)

    Enum.reduce(states, {%{}, %{}, 0.0, %{}}, fn {{taken, count}, weight}, {marginal, available, searched, next} ->
      available = Enum.reduce(listed, available, fn id, acc -> if MapSet.member?(taken, id), do: acc, else: Map.update(acc, id, weight, &(&1 + weight)) end)
      picks = outcome(setup, taken)
      none = max(1.0 - Enum.sum(Enum.map(picks, &elem(&1, 1))), 0.0)
      search = search_chance(setup, taken)
      searched = searched + weight * search

      {marginal, next} =
        for {id, prob} <- [{nil, none} | picks], {added, split} <- [{1, search}, {0, 1.0 - search}], reduce: {marginal, next} do
          {marg, nxt} ->
            mass = weight * prob * split
            marg = if id && added == 0, do: Map.update(marg, id, weight * prob, &(&1 + weight * prob)), else: marg
            key = {taken |> then(&if(id, do: MapSet.put(&1, id), else: &1)) |> MapSet.intersection(later), count + added}
            nxt = if mass < @prune, do: nxt, else: Map.update(nxt, key, mass, &(&1 + mass))
            {marg, nxt}
        end

      {marginal, available, searched, next}
    end)
  end

  defp finish(setup, marginal, available, searched) do
    pool = setup.pool_count
    shown = min(setup.shown, pool)
    fresh = ranked(pool, shown, length(setup.wanted), length(setup.backup), setup.looks)
    wanted_ids = Enum.map(setup.wanted, & &1.id)

    rows =
      setup.wanted
      |> Enum.zip(fresh.per_look)
      |> Enum.with_index(1)
      |> Enum.map(fn {{pack, per_look}, i} -> %{pack: pack, kind: :wanted, rank: i, choose: {pool - i, shown - 1}, per_look: per_look, fresh: Enum.at(fresh.wanted, i - 1)} end)
      |> Kernel.++(
        setup.backup
        |> Enum.with_index(1)
        |> Enum.map(fn {pack, j} ->
          %{pack: pack, kind: :backup, rank: j, choose: {pool - length(setup.wanted) - j, shown - 1}, per_look: nil, fresh: Enum.at(fresh.backup, j - 1)}
        end)
      )
      |> Enum.map(fn row ->
        Map.merge(row, %{final: Map.get(marginal, row.pack.id, 0.0), available: Map.get(available, row.pack.id, 0.0)})
      end)

    fallback = max(1.0 - Enum.sum(Enum.map(rows, & &1.final)), 0.0)
    listed_railway = rows |> Enum.filter(&StarlightBudget.railway_pack?(&1.pack)) |> Enum.map(& &1.final) |> Enum.sum()
    listed_floating = rows |> Enum.map(&(&1.final * ThemePacks.floating_nodes(&1.pack))) |> Enum.sum()
    any = rows |> Enum.filter(&(&1.pack.id in wanted_ids)) |> Enum.map(& &1.final) |> Enum.sum()

    %{
      probs: Map.new(rows, &{&1.pack.id, &1.final}),
      any: any,
      shown: shown,
      refreshes: setup.refreshes,
      looks: setup.looks,
      searching?: setup.searching?,
      hunting?: setup.hunting?,
      pool: pool,
      wanted_count: length(setup.wanted),
      backup_count: length(setup.backup),
      miss: fresh.miss,
      scale: fresh.scale,
      last_miss: fresh.last_miss,
      fallback: fallback,
      search: searched,
      railway: listed_railway + fallback * setup.fallback_railway_share,
      floating: listed_floating + fallback * setup.fallback_floating,
      rows: rows
    }
  end

  def ranked(pool, shown, wanted, backup, looks) do
    shown = min(shown, pool)
    total = binomial(pool, shown)
    miss = if total == 0, do: 1.0, else: binomial(pool - wanted, shown) / total
    hit_scale = if miss >= 1.0, do: 0.0, else: (1 - :math.pow(miss, looks)) / (1 - miss)
    last_miss = :math.pow(miss, looks - 1)

    per_look = for i <- 1..wanted//1, do: if(total == 0, do: 0.0, else: binomial(pool - i, shown - 1) / total)
    wanted_probs = Enum.map(per_look, &(&1 * hit_scale))

    backup_probs =
      for j <- 1..backup//1, do: if(total == 0, do: 0.0, else: binomial(pool - wanted - j, shown - 1) / total * last_miss)

    %{
      wanted: wanted_probs,
      per_look: per_look,
      backup: backup_probs,
      miss: miss,
      scale: hit_scale,
      last_miss: last_miss,
      fallback: max(:math.pow(miss, looks) - Enum.sum(backup_probs), 0.0),
      any: if(wanted == 0, do: 0.0, else: 1 - :math.pow(miss, looks))
    }
  end

  defp binomial(_n, k) when k < 0, do: 0
  defp binomial(n, k) when k > n or n < 0, do: 0
  defp binomial(n, k), do: Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - k + i), i) end)

  def percent(prob) when prob >= 0.995, do: "100%"
  def percent(prob) when prob < 0.0005, do: "0%"
  def percent(prob) when prob < 0.1, do: "#{Float.round(prob * 100, 1)}%"
  def percent(prob), do: "#{round(prob * 100)}%"
end
