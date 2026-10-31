defmodule StarlightBot.Automation.Scripts.ChargeEnkephalin do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, EnkephalinCharger}
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Catalog

  def program, do: [log(:info, "Localizing…"), locate_screen(then: {__MODULE__, :located, []})]

  def located({:ok, start}, _frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{start}")

    case Catalog.plan_path(start, :charge_enkephalin) do
      {:ok, _transitions} ->
        {:steps, [goto(start, :home, then: {__MODULE__, :at_home, []})]}

      {:error, :no_path} ->
        Ctx.log(ctx, :error, "charge enkephalin not reachable from #{start}")
        {:error, :not_reachable}
    end
  end

  def located(:unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def at_home({:ok, home}, _frame, ctx) do
    can_make_modules? = Engine.check(:home_enkephalin_spendable)
    Ctx.log(ctx, :info, "home_enkephalin_spendable: #{can_make_modules?}")
    {:steps, [goto(home, :charge_enkephalin_lunacy_tab, then: {__MODULE__, :at_lunacy_tab, [can_make_modules?]})]}
  end

  def at_home({:error, _} = err, _frame, _ctx), do: err

  def at_lunacy_tab(can_make_modules?, {:ok, lunacy_tab}, _frame, ctx) do
    ready? =
      Engine.check_all([:charge_enkephalin_tab_lunacy_0_10, :charge_enkephalin_tab_lunacy_cost_26])
      |> Map.values()
      |> Enum.all?()

    if ready? do
      Ctx.log(ctx, :info, "spending lunacy on enkephalin")
      spent = [log(:ok, "lunacy spent — can make modules now"), call(__MODULE__, :finish, [true, lunacy_tab])]
      {:steps, [attempt(spend_lunacy_steps() ++ spent, else: {__MODULE__, :spend_failed, [can_make_modules?, lunacy_tab]})]}
    else
      Ctx.log(ctx, :info, "lunacy charge not available at 0/10 @ 26 — skipping")
      finish(can_make_modules?, lunacy_tab, nil, ctx)
    end
  end

  def at_lunacy_tab(_can_make_modules?, {:error, _} = err, _frame, _ctx), do: err

  def spend_failed(can_make_modules?, lunacy_tab, {:error, reason}, frame, ctx) do
    Ctx.log(ctx, :error, "spend lunacy failed: #{inspect(reason)}")
    finish(can_make_modules?, lunacy_tab, frame, ctx)
  end

  def finish(true, lunacy_tab, _frame, _ctx), do: {:steps, [goto(lunacy_tab, :charge_enkephalin_modules_tab, then: {__MODULE__, :at_modules_tab, []})]}
  def finish(false, lunacy_tab, _frame, _ctx), do: {:steps, [goto(lunacy_tab, :home)]}

  def at_modules_tab({:ok, modules_tab}, _frame, ctx) do
    Ctx.log(ctx, :info, "making as many modules as possible")
    make = make_modules_steps() ++ [log(:ok, "modules made"), call(EnkephalinCharger, :mark_converted, [])]
    {:steps, [attempt(make, else: {__MODULE__, :make_failed, []}), goto(modules_tab, :home)]}
  end

  def at_modules_tab({:error, _} = err, _frame, _ctx), do: err

  def make_failed({:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :error, "make modules failed: #{inspect(reason)}")
    {:ok, nil}
  end

  defp spend_lunacy_steps do
    [
      retry_until(
        not_hook(:charge_enkephalin_tab_lunacy_cost_26),
        [
          click(:charge_enkephalin_popup_confirm)
        ],
        every: 1_000,
        tries: 2),
      sleep(1000),
    ]
  end

  defp make_modules_steps do
    [
      click(:charge_enkephalin_tab_modules_all),
      sleep(300),
      click(:charge_enkephalin_popup_confirm),
      sleep(1000),
    ]
  end
end
