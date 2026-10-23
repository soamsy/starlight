defmodule StarlightBot.Automation.Shop.Actions.Heal do
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.Ctx
  alias StarlightBot.GiftPlans

  @menu_check_ms 1_000
  @heal_settle_ms 500
  @heal_settle_poll_ms 100
  @first_check_settle_ms 500

  def run(%{"kind" => kind, "sinner" => nil}, _definition, state, _ctx) when kind in ["heal", "revive"],
    do: {:failed, "no sinner selected", state}

  def run(%{"kind" => "revive", "sinner" => sinner}, _definition, state, ctx) do
    state = close_menu(state, ctx)

    with true <- Ops.sinner_dead?(sinner),
         {:ok, state} <- open_menu(state, ctx),
         :ok <- Ops.revive(sinner, ctx) do
      spend(ctx)
      {:done, "revived #{sinner}", state}
    else
      false ->
        {:skipped, "#{sinner} isn't dead", state}

      :no_hook ->
        {:failed, "no shop_dead hook for #{sinner}", state}

      {:error, :heal_disabled} ->
        Ops.recover_to_shop(ctx)
        {:skipped, "heal is disabled", %{state | heal_menu_open: false}}

      {:error, {:option_disabled, hook}} ->
        {:skipped, "#{hook} is on, bailing", state}

      {:error, reason} ->
        {:failed, inspect(reason), state}
    end
  end

  def run(step, _definition, state, ctx) do
    target = if step["kind"] == "heal", do: step["sinner"], else: :all

    with false <- target != :all and settled_full?(target, state),
         {:ok, state} <- open_menu(state, ctx),
         {:ok, healed} <- Ops.heal(target, ctx) do
      spend(ctx)
      {:done, heal_message(target, healed), %{state | last_heal: {healed, now()}}}
    else
      true ->
        {:skipped, "#{target} already has full HP and SP", state}

      {:error, :heal_disabled} ->
        Ops.recover_to_shop(ctx)
        {:skipped, "heal is disabled", %{state | heal_menu_open: false}}

      {:error, {:option_disabled, hook}} ->
        {:skipped, "#{hook} is on, bailing", state}

      {:error, reason} -> {:failed, inspect(reason), state}
    end
  end

  defp settled_full?(sinner, %{last_heal: {healed, healed_at}}) when healed == sinner or healed == :all,
    do: poll_full(sinner, healed_at + @heal_settle_ms)

  defp settled_full?(sinner, _state), do: poll_full(sinner, now() + @first_check_settle_ms)

  defp poll_full(sinner, deadline) do
    cond do
      full?(sinner) -> true
      now() >= deadline -> false
      true ->
        Process.sleep(@heal_settle_poll_ms)
        poll_full(sinner, deadline)
    end
  end

  defp full?(sinner), do: Ops.sinner_full?(sinner, :sp) == true and Ops.sinner_full?(sinner, :hp) == true

  defp now, do: System.monotonic_time(:millisecond)

  defp heal_message(:all, :all), do: "healed every sinner"
  defp heal_message(target, target), do: "healed #{target}"
  defp heal_message(target, healed), do: "#{target} was already full, healed #{healed} instead"

  def preview(%{"kind" => "revive", "sinner" => sinner}, _definition, state, _ctx) when is_binary(sinner) do
    case Ops.sinner_dead?(sinner) do
      true -> {:would_run, "#{sinner} is dead, would revive", state}
      false -> {:would_run, "#{sinner} isn't dead", state}
      :no_hook -> {:failed, "no shop_dead hook for #{sinner}", state}
    end
  end

  def preview(_step, _definition, state, _ctx), do: {:failed, "no sinner selected", state}

  defp close_menu(%{heal_menu_open: true} = state, ctx) do
    Ops.close_heal_menu(ctx)
    Ops.detect_and_update_cost(ctx)
    %{state | heal_menu_open: false}
  end

  defp close_menu(state, _ctx), do: state

  defp open_menu(%{heal_menu_open: true} = state, ctx) do
    if Engine.check_within(:shop_heal_menu, @menu_check_ms) do
      {:ok, state}
    else
      Ctx.log(ctx, :info, "shop heal: heal menu closed on its own, reopening it")
      open_menu(%{state | heal_menu_open: false}, ctx)
    end
  end

  defp open_menu(state, ctx) do
    with :ok <- Ops.open_heal_menu(ctx), do: {:ok, %{state | heal_menu_open: true}}
  end

  defp spend(ctx) do
    case RunMemory.cost(ctx) do
      nil -> :ok
      cost -> RunMemory.put_cost(ctx, cost - GiftPlans.heal_cost())
    end
  end
end
