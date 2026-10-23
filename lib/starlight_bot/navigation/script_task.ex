defmodule StarlightBot.Navigation.ScriptTask do
  alias StarlightBot.Automation.RunMemory

  def run(navigator, kind, {mod, fun, args}, ctx, run_memory_seeds) do
    ctx = start_run_memory(ctx, run_memory_seeds)
    result = apply(mod, fun, args ++ [ctx])
    RunMemory.stop(ctx)
    send(navigator, {:nav_result, kind, result})
  end

  defp start_run_memory(ctx, nil), do: ctx

  defp start_run_memory(ctx, seeds) do
    {:ok, run_memory} = RunMemory.start_link()
    ctx = %{ctx | run_memory: run_memory}
    Enum.each(seeds, fn {put, value} -> apply(RunMemory, put, [ctx, value]) end)
    ctx
  end
end
