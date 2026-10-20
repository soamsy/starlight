defmodule StarlightBot.Automation.Shop.Actions.Milestone do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.Fusion
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  @passes [:upties, :buys, :fixed, :tiered, :upties]
  @max_actions 20

  def run(_step, milestone, state, ctx) do
    if reached?(milestone, state, ctx) do
      {:skipped, "#{milestone["name"]} already reached", state}
    else
      entries = GiftPlans.work_entries(state.plan, milestone["id"])

      {lines, progressed?, state} =
        Enum.reduce(@passes, {[], false, state}, fn pass, {lines, progressed?, state} ->
          {pass_lines, pass_progressed?, state} = run_pass(pass, entries, state, ctx)
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

  def preview(_step, milestone, state, ctx) do
    if reached?(milestone, state, ctx) do
      {:would_run, "#{milestone["name"]} already reached", state}
    else
      all = GiftPlans.work_entries(state.plan, milestone["id"])
      entries = Enum.filter(all, &GiftPlans.entry_needed?(state.plan, &1, env(state, ctx)))
      optional = Enum.filter(all, &(&1.optional and GiftPlans.entry_status(state.plan, &1, env(state, ctx)) != :done))

      plan =
        summarize([
          {"uptie", entries |> of(:upties) |> Enum.map(& &1.definition["gift"])},
          {"buy if on the shelf", entries |> of(:buys) |> Enum.map(&buy_name/1) |> Enum.reject(&owned?(&1, ctx)) |> Enum.uniq()},
          {"fuse", entries |> of(:fixed) |> Enum.map(& &1.definition["target"])},
          {"fuse", entries |> of(:tiered) |> tier_order(state) |> Enum.map(&"T#{target_tier(&1, state)} #{&1.definition["target"]}")}
        ])

      extras =
        summarize([
          {"uptie", optional |> of(:upties) |> Enum.map(& &1.definition["gift"])},
          {"buy", optional |> Enum.filter(&(&1.lib == "lists")) |> Enum.map(&GiftPlans.entry_label(&1.gift))},
          {"fuse", optional |> of(:fusions) |> Enum.map(& &1.definition["target"])}
        ])

      detail =
        case {plan, extras} do
          {"", ""} -> "nothing left to work on"
          {"", extras} -> "would only try optionals: #{extras}"
          {plan, ""} -> "would #{plan}, then uptie again"
          {plan, extras} -> "would #{plan}, then uptie again; optionals if possible: #{extras}"
        end

      {:would_run, detail, state}
    end
  end

  defp run_pass(:upties, entries, state, ctx) do
    Ops.close_fuse_popup(ctx)
    {lines, progressed?} = uptie_loop(of(entries, :upties), state, RunMemory.cost(ctx) || 0, [], ctx)

    if progressed? do
      Ops.recover_to_shop(ctx)
      Ops.detect_and_update_cost(ctx)
    end

    {lines, progressed?, state}
  end

  defp run_pass(:buys, entries, state, ctx) do
    {lines, progressed?} = buy_loop(of(entries, :buys), state, [], ctx)
    {lines, progressed?, state}
  end

  defp run_pass(:fixed, entries, state, ctx) do
    fixed = of(entries, :fixed)
    {required, optional} = split_optional(fixed)
    {lines, progressed?, state} = fuse_each(required, state, ctx, &GiftPlans.entry_needed?(state.plan, &1, env(state, ctx)))
    {more, more?, state} = fuse_each(optional, state, ctx, &(not owned?(&1.definition["target"], ctx) and ingredients_owned?(&1, state, ctx)))
    {lines ++ more, progressed? or more?, state}
  end

  defp run_pass(:tiered, entries, state, ctx) do
    {required, optional} = entries |> of(:tiered) |> tier_order(state) |> split_optional()
    {lines, progressed?, state} = fuse_each(required, state, ctx, &GiftPlans.entry_needed?(state.plan, &1, env(state, ctx)))
    fusions_done? = fn -> entries |> of(:fusions) |> Enum.reject(& &1.optional) |> Enum.all?(&(not GiftPlans.entry_needed?(state.plan, &1, env(state, ctx)))) end
    {more, more?, state} = fuse_each(optional, state, ctx, &(not owned?(&1.definition["target"], ctx) and fusions_done?.()))
    {lines ++ more, progressed? or more?, state}
  end

  defp uptie_loop(_entries, _state, _cost, done, _ctx) when length(done) >= @max_actions, do: {["upties: " <> Enum.join(done, ", ")], true}

  defp uptie_loop(entries, state, cost, done, ctx) do
    {required, optional} = split_optional(entries)

    needed =
      Enum.filter(required, &GiftPlans.entry_needed?(state.plan, &1, env(state, ctx))) ++
        Enum.filter(optional, &(GiftPlans.entry_status(state.plan, &1, env(state, ctx)) == :partial))

    needed = Enum.map(needed, & &1.definition)

    case GiftPlans.uptie_plan(needed, RunMemory.ego_gifts(ctx), state.gifts_by_name, cost, 1) do
      {[item], _reason} ->
        case Ops.uptie_gift(item.gift.id, item.from, item.to, ctx) do
          {:ok, level} ->
            RunMemory.set_ego_gift_uptie(ctx, item.gift.id, level)
            done = done ++ ["#{item.gift.name} +#{level}"]
            price = GiftPlans.uptie_cost(item.gift.tier, item.from, level) || item.price

            if level == item.to,
              do: uptie_loop(entries, state, cost - price, done, ctx),
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

  defp buy_loop(_entries, _state, bought, _ctx) when length(bought) >= @max_actions, do: buy_summary(bought, nil)

  defp buy_loop(entries, state, bought, ctx) do
    {required, optional} = split_optional(entries)
    wanted = required |> Enum.filter(&GiftPlans.entry_needed?(state.plan, &1, env(state, ctx))) |> Enum.map(&buy_name/1) |> Enum.reject(&owned?(&1, ctx)) |> Enum.uniq()
    extras = optional |> Enum.filter(&(&1.lib == "lists")) |> Enum.map(& &1.gift) |> Enum.reject(&(not GiftPlans.pattern_entry?(&1) and owned?(&1, ctx))) |> Enum.uniq()

    if wanted == [] and extras == [] do
      buy_summary(bought, nil)
    else
      case Ops.shelf_items(ctx) do
        {:ok, items} ->
          case shelf_matches(items, wanted, state, ctx) do
            [] -> shelf_matches(items, extras, state, ctx)
            matches -> matches
          end
          |> Ops.buy_first_affordable(ctx)
          |> case do
            {:bought, item} -> buy_loop(entries, state, bought ++ [item.gift_name], ctx)
            :none_available -> buy_summary(bought, if(bought == [], do: "nothing wanted and affordable on the shelf"))
          end

        {:error, reason} ->
          buy_summary(bought, "shelf scan failed: #{inspect(reason)}")
      end
    end
  end

  defp buy_summary([], nil), do: {[], false}
  defp buy_summary([], reason), do: {["buys: #{reason}"], false}
  defp buy_summary(bought, nil), do: {["bought " <> Enum.join(bought, ", ")], true}
  defp buy_summary(bought, reason), do: {["bought #{Enum.join(bought, ", ")} (#{reason})"], true}

  defp fuse_each(entries, state, ctx, eligible?) do
    Enum.reduce(entries, {[], false, state}, fn entry, {lines, progressed?, state} ->
      if eligible?.(entry) do
        {outcome, detail, state} = Fusion.obtain(entry.definition, %{"max_retries" => nil}, state, ctx, [])
        if outcome == :failed, do: Ops.recover_to_shop(ctx)
        {lines ++ ["#{entry.definition["name"]}: #{detail}"], progressed? or outcome in [:done, :partial], state}
      else
        {lines, progressed?, state}
      end
    end)
  end

  defp shelf_matches(items, entries, state, ctx) do
    items
    |> Enum.reject(&owned?(&1.gift_name, ctx))
    |> Enum.uniq_by(& &1.gift_id)
    |> Enum.map(&{&1, GiftPlans.list_rank(entries, Map.get(state, :gifts_by_id, %{})[&1.gift_id] || %{name: &1.gift_name, tier: nil})})
    |> Enum.reject(fn {_item, rank} -> is_nil(rank) end)
    |> Enum.sort_by(fn {_item, rank} -> rank end)
    |> Enum.map(fn {item, _rank} -> item end)
  end

  defp split_optional(entries), do: entries |> Enum.split_with(& &1.optional) |> then(fn {optional, required} -> {required, optional} end)

  defp ingredients_owned?(entry, state, ctx) do
    case state.gifts_by_name[entry.definition["target"]] do
      nil ->
        false

      target ->
        inventory = RunMemory.ego_gifts(ctx)
        ids = GiftPlans.ingredient_ids(target)
        ids != [] and Enum.all?(ids, &Map.has_key?(inventory, &1))
    end
  end

  defp summarize(sections) do
    sections
    |> Enum.reject(fn {_verb, names} -> names == [] end)
    |> Enum.map_join("; ", fn {verb, names} -> "#{verb} #{Enum.join(names, ", ")}" end)
  end

  defp of(entries, :upties), do: Enum.filter(entries, &(&1.lib == "upties"))
  defp of(entries, :fusions), do: Enum.filter(entries, &(&1.lib == "fusions"))
  defp of(entries, :buys), do: Enum.filter(entries, &(&1.lib in ["lists", "upties", "fusions"]))
  defp of(entries, :fixed), do: Enum.filter(entries, &(&1.lib == "fusions" and GiftPlans.fixed_fusion?(&1.definition)))
  defp of(entries, :tiered), do: Enum.filter(entries, &(&1.lib == "fusions" and not GiftPlans.fixed_fusion?(&1.definition)))

  defp buy_name(%{lib: "lists", gift: gift}), do: gift
  defp buy_name(%{lib: "upties", definition: definition}), do: definition["gift"]
  defp buy_name(%{lib: "fusions", definition: definition}), do: definition["target"]

  defp owned?(name, ctx), do: ctx |> RunMemory.ego_gifts() |> Enum.any?(fn {_id, entry} -> entry.name == name end)

  defp tier_order(entries, state), do: Enum.sort_by(entries, &(-target_tier(&1, state)))

  defp target_tier(entry, state) do
    case state.gifts_by_name[entry.definition["target"]] do
      %{tier: tier} when is_integer(tier) -> tier
      _ -> 0
    end
  end

  defp reached?(milestone, state, ctx), do: GiftPlans.milestone_reached?(state.plan, milestone["id"], env(state, ctx))

  defp env(state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)
    %{plan: state.plan, wallet: wallet(state, ctx), gifts: state.gifts_by_name, refreshes: Map.get(state, :refreshes, 0), owned: inventory |> Map.values() |> MapSet.new(& &1.name), inventory: inventory}
  end

  defp wallet(state, ctx) do
    case RunMemory.cost(ctx) do
      nil -> nil
      cost -> cost - state.reserve
    end
  end
end
