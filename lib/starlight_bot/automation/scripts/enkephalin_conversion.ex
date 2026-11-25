defmodule StarlightBot.Automation.Scripts.EnkephalinConversion do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{EnkephalinCharger, Recovery}
  alias StarlightBot.Ctx

  def program(count), do: [log(:info, "Localizing…") | Recovery.steps({__MODULE__, :keeps_nothing?}, 0, {__MODULE__, :located, [count]})]

  def keeps_nothing?(_screen), do: false

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
