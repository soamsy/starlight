defmodule StarlightBot.Navigation.Offload do
  alias StarlightBot.Navigation.MachineStatus

  def start_link(machine, mod, fun, args), do: {:ok, spawn_link(__MODULE__, :run, [machine, mod, fun, args])}

  def run(machine, mod, fun, args) do
    MachineStatus.put(%{
      parent: machine,
      label: nil,
      state: :running,
      current: "#{inspect(mod)}.#{fun}",
      waiting: nil,
      remaining: 0,
      started_at: System.monotonic_time(:millisecond)
    })

    outcome =
      try do
        {:returned, apply(mod, fun, args)}
      rescue
        exception -> {:raised, Exception.message(exception), Exception.format(:error, exception, __STACKTRACE__)}
      end

    send(machine, {:offloaded, self(), outcome})
  end
end
