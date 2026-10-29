defmodule StarlightBot.Vision.HookRegistry do
  use GenServer
  require Logger
  alias StarlightBot.Hooks
  alias StarlightBot.Vision.Hook

  @table :hook_registry

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def find(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, hook}] -> {:ok, hook}
      [] -> {:error, :not_found}
    end
  end

  def all_names do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  def invalidate(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:invalidate, name})
  end

  def reload_all do
    GenServer.cast(__MODULE__, :reload_all)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:invalidate, name}, state) do
    reload_one(name)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reload_all, state) do
    :ets.delete_all_objects(@table)
    load_all()
    {:noreply, state}
  end

  defp load_all do
    rows = Hooks.effective_rows()

    if rows == [] do
      Logger.warning("HookRegistry: no hooks loaded (run `mix db.setup`?)", module: __MODULE__)
    end

    Enum.each(rows, &insert_row/1)
    Logger.info("HookRegistry: loaded #{length(rows)} hook(s)", module: __MODULE__)
  end

  defp reload_one(name) do
    case Hooks.effective_row(Atom.to_string(name)) do
      nil ->
        :ets.delete(@table, name)
        Logger.debug("HookRegistry: evicted #{name}", module: __MODULE__)

      row ->
        insert_row(row)
        Logger.debug("HookRegistry: reloaded #{name}", module: __MODULE__)
    end
  end

  defp insert_row(row) do
    if File.exists?(Hooks.image_path(row)) do
      try do
        hook = Hook.from_db_row(row)
        :ets.insert(@table, {hook.name, hook})
      rescue
        e ->
          Logger.warning(
            "HookRegistry: failed to decode hook #{inspect(row.name)}: #{Exception.message(e)}",
            module: __MODULE__
          )
      end
    else
      Logger.debug("HookRegistry: skipping #{inspect(row.name)} — no image saved yet", module: __MODULE__)
    end
  end
end
