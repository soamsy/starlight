defmodule StarlightBot.Automation.EnkephalinCharger do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

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

  def charge(from, 0, ctx) do
    with {:ok, home} <- Engine.goto(from, :home, ctx) do
      if Engine.check(:home_enkephalin_spendable) do
        charge_from(home, 0, ctx)
      else
        Ctx.log(ctx, :info, "no lunacy conversions and home_enkephalin_spendable is off, skipping enkephalin")
        {:ok, home}
      end
    end
  end

  def charge(from, count, ctx) when is_integer(count) and count in 1..@max_convert_count,
    do: charge_from(from, count, ctx)

  defp charge_from(from, count, ctx) do
    Ctx.log(ctx, :info, "charging enkephalin (up to #{count} lunacy spend(s))")

    with {:ok, lunacy_tab} <- Engine.goto(from, :charge_enkephalin_lunacy_tab, ctx) do
      spend_lunacy(count, ctx)

      with {:ok, modules_tab} <- Engine.goto(lunacy_tab, :charge_enkephalin_modules_tab, ctx) do
        make_modules(ctx)
        Engine.goto(modules_tab, :home, ctx)
      end
    end
  end

  defp spend_lunacy(0, ctx) do
    Ctx.log(ctx, :info, "lunacy spend not requested — skipping")
  end

  defp spend_lunacy(target, ctx) do
    case detect_spent_count(ctx) do
      {:ok, spent} when spent >= target ->
        Ctx.log(ctx, :info, "already spent #{spent}/#{target} today — nothing to do")

      {:ok, spent} ->
        Ctx.log(ctx, :info, "spent #{spent} so far, spending up to #{target}")
        run_spend_steps(spent, target, ctx)

      :unknown ->
        Ctx.log(ctx, :info, "could not determine today's lunacy spend count — skipping")
    end
  end

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

  defp run_spend_steps(spent, target, _ctx) when spent >= target, do: :ok

  defp run_spend_steps(spent, target, ctx) do
    cost_hook = Enum.at(@spend_cost_hooks, spent)

    case Engine.act(spend_steps(cost_hook), ctx) do
      {:ok, _} ->
        Ctx.log(ctx, :ok, "spent lunacy (#{spent + 1}/#{target})")
        run_spend_steps(spent + 1, target, ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "spend lunacy failed at step #{spent + 1}: #{inspect(reason)} — moving on")
    end
  end

  defp spend_steps(cost_hook) do
    [
      click(:charge_enkephalin_popup_confirm),
      move_to(:charge_enkephalin_popup_safe_area),
      await(not_hook(cost_hook), timeout: 3_000),
    ]
  end

  defp make_modules(ctx) do
    Ctx.log(ctx, :info, "making as many enkephalin modules as possible")

    case Engine.act(make_modules_steps(), ctx) do
      {:ok, _} -> Ctx.log(ctx, :ok, "modules made")
      {:error, reason} -> Ctx.log(ctx, :error, "make modules failed: #{inspect(reason)}")
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
