defmodule StarlightBot.Automation.Scripts.EnkephalinConversion do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.EnkephalinCharger
  alias StarlightBot.Ctx

  def program(count), do: [log(:info, "Localizing…"), locate_screen(then: {__MODULE__, :located, [count]})]

  def located(count, {:ok, screen}, _frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{screen}")
    {:steps, [capture(EnkephalinCharger.steps(screen, count), then: {__MODULE__, :charged, []})]}
  end

  def located(_count, :unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def charged({:ok, screen}, _frame, _ctx), do: {:steps, [result({:ok, screen})]}
  def charged({:error, _} = err, _frame, _ctx), do: err
end
