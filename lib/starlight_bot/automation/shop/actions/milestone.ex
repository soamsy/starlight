defmodule StarlightBot.Automation.Shop.Actions.Milestone do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Scripts.ShopRunner
  alias StarlightBot.Automation.Shop.Actions.{AffinityRefresh, Fusion, Heal, Refresh, Sell, SkillReplace}
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  @passes [:upties, :buys, :fixed, :tiered, :upties]
  @max_actions 20
  @max_refresh_rounds 20

  def run(_step, milestone, state, ctx), do: run_rounds(milestone, state, ctx, 1, [], [])

  defp run_rounds(milestone, state, ctx, round, details, outcomes) do
    {outcome, detail, state} = work(milestone, state, ctx)
    details = details ++ [detail]
    outcomes = outcomes ++ [outcome]

    case if(reached?(milestone, state, ctx), do: nil, else: refresh_case(milestone, state, ctx)) do
      nil ->
        finish(milestone, details, outcomes, state, ctx)

      %{"action" => "leave"} ->
        finish(milestone, details ++ ["leaving the shop"], outcomes, Map.put(state, :left, true), ctx)

      _refresh_case when round >= @max_refresh_rounds ->
        finish(milestone, details ++ ["stopped after #{@max_refresh_rounds} refreshes"], outcomes, state, ctx)

      refresh_case ->
        Ops.close_fuse_popup(ctx)

        case refresh(refresh_case, state, ctx) do
          {:done, refreshed, state} ->
            state = Map.update(state, :case_runs, %{refresh_case["id"] => 1}, &Map.update(&1, refresh_case["id"], 1, fn runs -> runs + 1 end))
            Ops.detect_and_update_cost(ctx)
            run_rounds(milestone, state, ctx, round + 1, details ++ [refreshed], outcomes ++ [:partial])

          {_outcome, reason, state} ->
            finish(milestone, details ++ ["refresh: #{reason}"], outcomes, state, ctx)
        end
    end
  end

  defp finish(milestone, details, outcomes, state, ctx) do
    outcome =
      cond do
        reached?(milestone, state, ctx) and Enum.any?(outcomes, &(&1 == :done)) -> :done
        Enum.any?(outcomes, &(&1 in [:done, :partial])) -> :partial
        true -> List.last(outcomes)
      end

    {outcome, Enum.join(details, "; "), state}
  end

  defp refresh_case(milestone, state, ctx), do: GiftPlans.matching_refresh_case(milestone, ShopRunner.condition_env(state, ctx))

  defp refresh(%{"action" => "affinity_refresh"} = refresh_case, state, ctx), do: AffinityRefresh.run(%{"affinity" => refresh_case["affinity"]}, nil, state, ctx)
  defp refresh(_refresh_case, state, ctx), do: Refresh.run(%{}, nil, state, ctx)

  defp refresh_preview(milestone, state, ctx) do
    if GiftPlans.any_refresh_cases?(milestone) do
      case refresh_case(milestone, state, ctx) do
        nil -> ["no refresh case matches now"]
        refresh_case -> ["then would #{refresh_label(refresh_case)}"]
      end
    else
      []
    end
  end

  defp refresh_label(%{"action" => "affinity_refresh", "affinity" => affinity}) when is_binary(affinity), do: "keyword refresh for #{affinity}"
  defp refresh_label(%{"action" => action}), do: String.downcase(GiftPlans.refresh_action_label(action))

  defp work(milestone, state, ctx) do
    {sold_lines, sold?, state} = Sell.run_entries(sells(milestone, state), entries(milestone, state), keep(state), state, ctx)
    {heal_lines, healed?, state} = Heal.run_entries(GiftPlans.heal_entries(entries(milestone, state)), state, ctx)
    {replace_lines, replaced?, state} = SkillReplace.run_entries(GiftPlans.skill_replace_entries(entries(milestone, state)), state, ctx)
    sell_lines = sold_lines ++ heal_lines ++ replace_lines
    sold? = sold? or healed? or replaced?

    if reached?(milestone, state, ctx) do
      detail = Enum.join(sell_lines ++ ["#{milestone["name"]} already reached"], "; ")
      {if(sold?, do: :done, else: :skipped), detail, state}
    else
      state = Map.put(state, :milestone_entries, entries(milestone, state))

      {lines, progressed?, state} =
        Enum.reduce(@passes, {sell_lines, sold?, state}, fn pass, {lines, progressed?, state} ->
          {pass_lines, pass_progressed?, state} = run_pass(pass, milestone, state, ctx)
          {lines ++ pass_lines, progressed? or pass_progressed?, state}
        end)

      detail = if lines == [], do: "nothing to do right now", else: Enum.join(lines, "; ")

      cond do
        reached?(milestone, state, ctx) -> {:done, detail <> "; #{milestone["name"]} reached", state}
        progressed? -> {:partial, detail, state}
        true -> {:skipped, detail, state}
      end
    end
  end

  def heals?(milestone, state), do: milestone |> entries(state) |> GiftPlans.heal_entries() != []

  def heal_only(milestone, state, ctx) do
    {lines, healed?, state} = Heal.run_entries(GiftPlans.heal_entries(entries(milestone, state)), state, ctx)
    {if(healed?, do: :done, else: :skipped), Enum.join(lines ++ ["#{milestone["name"]} already reached, only healing"], "; "), state}
  end

  def heal_only_preview(milestone, state) do
    heals = milestone |> entries(state) |> GiftPlans.heal_entries() |> Enum.map(&heal_label/1)
    {:would_run, "check heals: #{Enum.join(heals, ", ")}; #{milestone["name"]} already reached, only healing", state}
  end

  def preview(_step, milestone, state, ctx) do
    sold = Sell.plan(sells(milestone, state), entries(milestone, state), keep(state), state, ctx)
    selling = if sold == [], do: [], else: ["sell " <> Enum.map_join(sold, ", ", fn {gift, _entry} -> gift.name end)]
    heals = milestone |> entries(state) |> GiftPlans.heal_entries() |> Enum.map(&heal_label/1)
    selling = selling ++ if(heals == [], do: [], else: ["check heals: " <> Enum.join(heals, ", ")])
    replaces = milestone |> entries(state) |> GiftPlans.skill_replace_entries() |> Enum.flat_map(fn entry -> Enum.filter(entry.sinners, &SkillReplace.pending?(&1, entry, ctx)) end)
    selling = selling ++ if(replaces == [], do: [], else: ["check skill replace for " <> Enum.join(Enum.uniq(replaces), ", ")])

    if reached?(milestone, state, ctx) do
      {:would_run, Enum.join(selling ++ ["#{milestone["name"]} already reached"], "; "), state}
    else
      progress = progress(milestone, state, ctx)
      needed = Enum.filter(progress.entries, &GiftPlans.needed?(progress, &1))
      optional = Enum.filter(progress.entries, &(&1.goal == "optional" and GiftPlans.status(progress, &1) != :done))

      plan =
        summarize([
          {"uptie", needed |> upties(progress) |> Enum.map(& &1.gift)},
          {"buy if on the shelf", needed |> Enum.filter(& &1.buy) |> Enum.map(& &1.gift) |> Enum.reject(&owned?(&1, ctx))},
          {"fuse", needed |> fixed() |> Enum.map(& &1.gift)},
          {"fuse", needed |> tiered() |> tier_order(state) |> Enum.map(&"T#{target_tier(&1, state)} #{&1.gift}")}
        ])

      extras =
        summarize([
          {"uptie", optional |> upties(progress) |> Enum.map(& &1.gift)},
          {"buy", (optional ++ ignored(progress)) |> Enum.filter(& &1.buy) |> Enum.map(&GiftPlans.subject_label(&1.subject))},
          {"fuse", optional |> Enum.filter(& &1.fuse) |> Enum.map(& &1.gift)}
        ])

      detail =
        case {plan, extras} do
          {"", ""} -> "nothing left to work on"
          {"", extras} -> "would only try optionals: #{extras}"
          {plan, ""} -> "would #{plan}, then uptie again"
          {plan, extras} -> "would #{plan}, then uptie again; optionals if possible: #{extras}"
        end

      {:would_run, Enum.join(selling ++ [detail] ++ refresh_preview(milestone, state, ctx), "; "), state}
    end
  end

  defp run_pass(:upties, milestone, state, ctx) do
    Ops.close_fuse_popup(ctx)
    {lines, progressed?} = uptie_loop(milestone, state, RunMemory.cost(ctx) || 0, [], ctx)

    if progressed? do
      Ops.recover_to_shop(ctx)
      Ops.detect_and_update_cost(ctx)
    end

    {lines, progressed?, state}
  end

  defp run_pass(:buys, milestone, state, ctx) do
    buy_loop(milestone, state, [], ctx)
  end

  defp run_pass(:fixed, milestone, state, ctx) do
    progress = progress(milestone, state, ctx)
    {required, optional} = progress.entries |> fixed() |> split_optional()
    {lines, progressed?, state} = fuse_each(required, state, ctx, &GiftPlans.needed?(progress(milestone, state, ctx), &1))
    {more, more?, state} = fuse_each(optional, state, ctx, &(not owned?(&1.gift, ctx) and ingredients_owned?(&1, state, ctx)))
    {lines ++ more, progressed? or more?, state}
  end

  defp run_pass(:tiered, milestone, state, ctx) do
    progress = progress(milestone, state, ctx)
    {required, optional} = progress.entries |> tiered() |> tier_order(state) |> split_optional()
    {lines, progressed?, state} = fuse_each(required, state, ctx, &GiftPlans.needed?(progress(milestone, state, ctx), &1))

    fusions_done? = fn ->
      now = progress(milestone, state, ctx)
      now.entries |> Enum.filter(& &1.fuse) |> Enum.reject(&(&1.goal == "optional")) |> Enum.all?(&(not GiftPlans.needed?(now, &1)))
    end

    {more, more?, state} = fuse_each(optional, state, ctx, &(not owned?(&1.gift, ctx) and fusions_done?.()))
    {lines ++ more, progressed? or more?, state}
  end

  defp uptie_loop(_milestone, _state, _cost, done, _ctx) when length(done) >= @max_actions, do: {["upties: " <> Enum.join(done, ", ")], true}

  defp uptie_loop(milestone, state, cost, done, ctx) do
    progress = progress(milestone, state, ctx)
    {required, optional} = progress.entries |> upties(progress) |> split_optional()

    needed =
      Enum.filter(required, &GiftPlans.needed?(progress, &1)) ++
        Enum.filter(optional, &(GiftPlans.status(progress, &1) == :partial))

    definitions = Enum.map(needed, &%{"gift" => &1.gift, "target_level" => &1.uptie})

    case GiftPlans.uptie_plan(definitions, RunMemory.ego_gifts(ctx), state.gifts_by_name, cost, 1) do
      {[item], _reason} ->
        case Ops.uptie_gift(item.gift.id, item.from, item.to, ctx) do
          {:ok, level} ->
            RunMemory.set_ego_gift_uptie(ctx, item.gift.id, level)
            done = done ++ ["#{item.gift.name} +#{level}"]
            price = GiftPlans.uptie_cost(item.gift.tier, item.from, level) || item.price

            if level == item.to,
              do: uptie_loop(milestone, state, cost - price, done, ctx),
              else: uptie_summary(done, "couldn't afford +#{item.to}")

          {:error, reason} ->
            uptie_summary(done, "#{item.gift.name} +#{item.to} failed: #{inspect(reason)}")
        end

      {[], reason} ->
        uptie_summary(done, if(reason == "end of list", do: nil, else: reason))
    end
  end

  defp uptie_summary([], nil), do: {[], false}
  defp uptie_summary([], reason), do: {["upties: #{reason}"], false}
  defp uptie_summary(done, nil), do: {["uptied " <> Enum.join(done, ", ")], true}
  defp uptie_summary(done, reason), do: {["uptied #{Enum.join(done, ", ")} (#{reason})"], true}

  defp buy_loop(_milestone, state, bought, _ctx) when length(bought) >= @max_actions, do: buy_done(bought, nil, state)

  defp buy_loop(milestone, state, bought, ctx) do
    progress = progress(milestone, state, ctx)
    buyable = Enum.filter(progress.entries, & &1.buy)
    wanted = buyable |> Enum.filter(&GiftPlans.needed?(progress, &1)) |> Enum.reject(&owned?(&1.gift, ctx))

    extras =
      Enum.filter(buyable, fn entry ->
        (entry.goal == "optional" and GiftPlans.status(progress, entry) == :open and not owned?(entry.gift, ctx)) or
          (entry.disposition == "ignore" and under_buy_cap?(entry, state))
      end)

    if wanted == [] and extras == [] do
      buy_done(bought, nil, state)
    else
      case Ops.shelf_items(ctx) do
        {:ok, items} ->
          case shelf_matches(items, wanted, state, ctx) do
            [] -> shelf_matches(items, extras, state, ctx)
            matches -> matches
          end
          |> Ops.buy_first_affordable(ctx)
          |> case do
            {:bought, item} -> buy_loop(milestone, count_bought(state, item, wanted ++ extras), bought ++ [item.gift_name], ctx)
            :none_available -> buy_done(bought, if(bought == [], do: "nothing wanted and affordable on the shelf"), state)
          end

        {:error, reason} ->
          buy_done(bought, "shelf scan failed: #{inspect(reason)}", state)
      end
    end
  end

  defp buy_done(bought, reason, state) do
    {lines, progressed?} = buy_summary(bought, reason)
    {lines, progressed?, state}
  end

  defp under_buy_cap?(entry, state), do: not (is_integer(entry.max) and Map.get(Map.get(state, :bought, %{}), entry.id, 0) >= entry.max)

  defp count_bought(state, item, entries) do
    gift = Map.get(state, :gifts_by_id, %{})[item.gift_id] || %{name: item.gift_name, tier: nil}

    case Enum.find(entries, &GiftPlans.subject_matches?(&1.subject, gift)) do
      %{max: max, id: id} when is_integer(max) -> Map.put(state, :bought, Map.update(Map.get(state, :bought, %{}), id, 1, &(&1 + 1)))
      _ -> state
    end
  end

  defp buy_summary([], nil), do: {[], false}
  defp buy_summary([], reason), do: {["buys: #{reason}"], false}
  defp buy_summary(bought, nil), do: {["bought " <> Enum.join(bought, ", ")], true}
  defp buy_summary(bought, reason), do: {["bought #{Enum.join(bought, ", ")} (#{reason})"], true}

  defp fuse_each(entries, state, ctx, eligible?) do
    Enum.reduce(entries, {[], false, state}, fn entry, {lines, progressed?, state} ->
      if eligible?.(entry) do
        {outcome, detail, state} = Fusion.obtain(entry, %{"max_retries" => nil}, state, ctx, [])
        if outcome == :failed, do: Ops.recover_to_shop(ctx)
        {lines ++ ["#{entry.gift}: #{detail}"], progressed? or outcome in [:done, :partial], state}
      else
        {lines, progressed?, state}
      end
    end)
  end

  defp shelf_matches(items, entries, state, ctx) do
    items
    |> Enum.reject(&owned?(&1.gift_name, ctx))
    |> Enum.uniq_by(& &1.gift_id)
    |> Enum.map(fn item ->
      gift = Map.get(state, :gifts_by_id, %{})[item.gift_id] || %{name: item.gift_name, tier: nil}
      {item, Enum.find_index(entries, &GiftPlans.subject_matches?(&1.subject, gift))}
    end)
    |> Enum.reject(fn {_item, rank} -> is_nil(rank) end)
    |> Enum.sort_by(fn {_item, rank} -> rank end)
    |> Enum.map(fn {item, _rank} -> item end)
  end

  defp split_optional(entries), do: entries |> Enum.split_with(&(&1.goal == "optional")) |> then(fn {optional, required} -> {required, optional} end)

  defp ingredients_owned?(entry, state, ctx) do
    case state.gifts_by_name[entry.gift] do
      nil ->
        false

      target ->
        inventory = RunMemory.ego_gifts(ctx)
        ids = GiftPlans.recipe_ids(target)
        fusable_here? = state.shop_type != :normal or length(GiftPlans.ingredient_ids(target)) <= 3
        fusable_here? and ids != [] and Enum.all?(ids, &Map.has_key?(inventory, &1))
    end
  end

  defp summarize(sections) do
    sections
    |> Enum.reject(fn {_verb, names} -> names == [] end)
    |> Enum.map_join("; ", fn {verb, names} -> "#{verb} #{Enum.join(Enum.uniq(names), ", ")}" end)
  end

  defp upties(entries, progress), do: Enum.filter(entries, &(&1.uptie > 0 and not MapSet.member?(progress.pending, &1.gift)))
  defp fixed(entries), do: Enum.filter(entries, &(&1.fuse and GiftPlans.fixed_fusion?(&1)))
  defp tiered(entries), do: Enum.filter(entries, &(&1.fuse and GiftPlans.tiered_fusion?(&1)))
  defp ignored(progress), do: Enum.filter(progress.entries, &(&1.disposition == "ignore"))

  defp heal_label(%{subject: %{"action" => "heal_all"}} = entry), do: GiftPlans.subject_label(entry.subject)
  defp heal_label(entry), do: "#{GiftPlans.subject_label(entry.subject)} #{Enum.join(entry.sinners, ", ")}"

  defp owned?(nil, _ctx), do: false
  defp owned?(name, ctx), do: ctx |> RunMemory.ego_gifts() |> Enum.any?(fn {_id, entry} -> entry.name == name end)

  defp tier_order(entries, state), do: Enum.sort_by(entries, &(-target_tier(&1, state)))

  defp target_tier(entry, state) do
    case state.gifts_by_name[entry.gift] do
      %{tier: tier} when is_integer(tier) -> tier
      _ -> 0
    end
  end

  defp sells(milestone, state), do: milestone |> entries(state) |> GiftPlans.sell_entries()
  defp entries(milestone, state), do: GiftPlans.resolved_entries(milestone, shop_floor(state))

  defp keep(state), do: Map.get_lazy(state, :protected, fn -> GiftPlans.keep_set(state.plan, shop_floor(state)) end)

  defp shop_floor(state), do: Map.get(state, :floor) || 1

  defp progress(milestone, state, ctx), do: GiftPlans.progress(state.plan, milestone["id"], env(state, ctx))

  defp reached?(milestone, state, ctx), do: milestone |> progress(state, ctx) |> GiftPlans.reached?()

  defp env(state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)

    env = %{
      plan: state.plan,
      floor: shop_floor(state),
      wallet: wallet(state, ctx),
      gifts: state.gifts_by_name,
      refreshes: Map.get(state, :refreshes, 0),
      owned: inventory |> Map.values() |> MapSet.new(& &1.name),
      inventory: inventory,
      skill_replaces: RunMemory.skill_replaces(ctx)
    }

    case Map.get(state, :gifts_by_id) do
      nil -> env
      by_id -> Map.put(env, :gifts_by_id, by_id)
    end
  end

  defp wallet(state, ctx) do
    case RunMemory.cost(ctx) do
      nil -> nil
      cost -> cost - state.reserve
    end
  end
end
