defmodule StarlightBot.Automation.EnkephalinCharger do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.{Ctx, EnkephalinSchedule}

  @max_convert_count 4

  @spend_state_hooks [
    :charge_enkephalin_tab_lunacy_0_10,
    :charge_enkephalin_tab_lunacy_1_10,
    :charge_enkephalin_tab_lunacy_2_10,
    :charge_enkephalin_tab_lunacy_3_10,
    :charge_enkephalin_tab_lunacy_4_10
  ]

  @spend_cost_hooks [
    :charge_enkephalin_tab_lunacy_cost_26,
    :charge_enkephalin_tab_lunacy_cost_52,
    :charge_enkephalin_tab_lunacy_cost_78,
    :charge_enkephalin_tab_lunacy_cost_104
  ]

  def max_convert_count, do: @max_convert_count

  def steps(from, 0), do: [goto(from, :home, then: {__MODULE__, :at_home, []})]

  def steps(from, count) when is_integer(count) and count in 1..@max_convert_count do
    [
      log(:info, "charging enkephalin (up to #{count} lunacy spend(s))"),
      goto(from, :charge_enkephalin_lunacy_tab, then: {__MODULE__, :at_lunacy_tab, [count]})
    ]
  end

  def at_home({:ok, home}, _frame, ctx) do
    if Engine.check(:home_enkephalin_spendable) do
      {:steps, make_modules_from(home)}
    else
      Ctx.log(ctx, :info, "no lunacy conversions and home_enkephalin_spendable is off, skipping enkephalin")
      {:steps, [result({:ok, home})]}
    end
  end

  def at_home({:error, _} = err, _frame, _ctx), do: err

  def at_lunacy_tab(count, {:ok, lunacy_tab}, _frame, _ctx),
    do: {:steps, [call(__MODULE__, :spend_lunacy, [count]) | make_modules_from(lunacy_tab)]}

  def at_lunacy_tab(_count, {:error, _} = err, _frame, _ctx), do: err

  def spend_lunacy(target, _frame, ctx) do
    case detect_spent_count(ctx) do
      {:ok, spent} when spent >= target ->
        Ctx.log(ctx, :info, "already spent #{spent}/#{target} today — nothing to do")
        {:ok, nil}

      {:ok, spent} ->
        Ctx.log(ctx, :info, "spent #{spent} so far, spending up to #{target}")
        spend(spent, target, nil, ctx)

      :unknown ->
        Ctx.log(ctx, :info, "could not determine today's lunacy spend count — skipping")
        {:ok, nil}
    end
  end

  def spend(spent, target, _frame, _ctx) when spent >= target, do: {:ok, nil}

  def spend(spent, target, _frame, _ctx) do
    cost_hook = Enum.at(@spend_cost_hooks, spent)

    steps = [
      click(:charge_enkephalin_popup_confirm),
      move_to(:charge_enkephalin_popup_safe_area),
      await(not_hook(cost_hook), timeout: 3_000),
      log(:ok, "spent lunacy (#{spent + 1}/#{target})"),
      call(__MODULE__, :spend, [spent + 1, target])
    ]

    {:steps, [attempt(steps, else: {__MODULE__, :spend_failed, [spent]})]}
  end

  def spend_failed(spent, {:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :error, "spend lunacy failed at step #{spent + 1}: #{inspect(reason)} — moving on")
    {:ok, nil}
  end

  def at_modules_tab({:ok, modules_tab}, _frame, ctx) do
    Ctx.log(ctx, :info, "making as many enkephalin modules as possible")
    make = make_modules_steps() ++ [log(:ok, "modules made"), call(__MODULE__, :mark_converted, [])]
    {:steps, [attempt(make, else: {__MODULE__, :make_failed, []}), goto(modules_tab, :home)]}
  end

  def at_modules_tab({:error, _} = err, _frame, _ctx), do: err

  def mark_converted(_frame, _ctx) do
    EnkephalinSchedule.mark_converted()
    {:ok, nil}
  end

  def make_failed({:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :error, "make modules failed: #{inspect(reason)}")
    {:ok, nil}
  end

  defp make_modules_from(from), do: [goto(from, :charge_enkephalin_modules_tab, then: {__MODULE__, :at_modules_tab, []})]

  defp detect_spent_count(ctx) do
    matched_hooks =
      Engine.check_all(@spend_state_hooks)
      |> Enum.filter(fn {_hook, matched?} -> matched? end)
      |> Enum.map(fn {hook, _matched?} -> hook end)

    case matched_hooks do
      [hook] ->
        {:ok, Enum.find_index(@spend_state_hooks, &(&1 == hook))}

      other ->
        Ctx.log(
          ctx,
          :info,
          "ambiguous lunacy spend state: #{length(other)} state(s) matched: #{Enum.join(other, ", ")}"
        )

        :unknown
    end
  end

  defp make_modules_steps do
    [
      click(:charge_enkephalin_tab_modules_all),
      sleep(300),
      click(:charge_enkephalin_popup_confirm),
      sleep(1000)
    ]
  end
end
