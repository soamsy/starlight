defmodule StarlightBot.Automation.Scripts.ChargeEnkephalin do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Catalog

  def run(ctx \\ Ctx.new()) do
    with {:ok, start} <- localize(ctx),
         :ok <- ensure_reachable(start, ctx),
         {:ok, home} <- Engine.goto(start, :home, ctx) do
      can_make_modules? = Engine.check(:home_enkephalin_spendable)
      Ctx.log(ctx, :info, "home_enkephalin_spendable: #{can_make_modules?}")

      with {:ok, lunacy_tab} <- Engine.goto(home, :charge_enkephalin_lunacy_tab, ctx) do
        can_make_modules? = maybe_spend_lunacy(can_make_modules?, ctx)

        if can_make_modules? do
          with {:ok, modules_tab} <- Engine.goto(lunacy_tab, :charge_enkephalin_modules_tab, ctx) do
            make_modules(ctx)
            Engine.goto(modules_tab, :home, ctx)
          end
        else
          Engine.goto(lunacy_tab, :home, ctx)
        end
      end
    end
  end

  defp localize(ctx) do
    Ctx.log(ctx, :info, "Localizing…")

    case Engine.localize() do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized")
        {:error, :unknown_screen}
    end
  end

  defp ensure_reachable(from, ctx) do
    case Catalog.plan_path(from, :charge_enkephalin) do
      {:ok, _transitions} ->
        :ok

      {:error, :no_path} ->
        Ctx.log(ctx, :error, "charge enkephalin not reachable from #{from}")
        {:error, :not_reachable}
    end
  end

  defp maybe_spend_lunacy(can_make_modules?, ctx) do
    ready? =
      Engine.check_all([:charge_enkephalin_tab_lunacy_0_10, :charge_enkephalin_tab_lunacy_cost_26])
      |> Map.values()
      |> Enum.all?()

    if ready? do
      Ctx.log(ctx, :info, "spending lunacy on enkephalin")

      case Engine.act(spend_lunacy_steps(), ctx) do
        {:ok, _} ->
          Ctx.log(ctx, :ok, "lunacy spent — can make modules now")
          true

        {:error, reason} ->
          Ctx.log(ctx, :error, "spend lunacy failed: #{inspect(reason)}")
          can_make_modules?
      end
    else
      Ctx.log(ctx, :info, "lunacy charge not available at 0/10 @ 26 — skipping")
      can_make_modules?
    end
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

  defp make_modules(ctx) do
    Ctx.log(ctx, :info, "making as many modules as possible")

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
      sleep(1000),
    ]
  end
end
