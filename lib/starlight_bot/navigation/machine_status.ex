defmodule StarlightBot.Navigation.MachineStatus do
  use GenServer

  @table :machine_status

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put(status), do: :ets.insert(@table, {self(), status})

  def delete, do: :ets.delete(@table, self())

  def all do
    for {pid, status} <- :ets.tab2list(@table), Process.alive?(pid), do: Map.put(status, :pid, pid)
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
