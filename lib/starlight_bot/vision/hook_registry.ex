defmodule StarlightBot.Vision.HookRegistry do
  use GenServer
  require Logger
  alias StarlightBot.Hooks
  alias StarlightBot.Vision.Hook

  @table :hook_registry
  @max_loaded_pixels 16_000_000
  @load_timeout 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def find(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, _row, %Hook{} = hook, _used, _pixels}] ->
        :ets.update_element(@table, name, {4, System.monotonic_time()})
        {:ok, hook}

      [{^name, _row, nil, _used, _pixels}] ->
        GenServer.call(__MODULE__, {:load, name}, @load_timeout)

      _ ->
        {:error, :not_found}
    end
  end

  def all_names do
    :ets.select(@table, [{{:"$1", :_, :_, :_, :_}, [], [:"$1"]}])
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
  def handle_call({:load, name}, _from, state) do
    {:reply, load(name), state}
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
    Logger.info("HookRegistry: indexed #{length(rows)} hook(s)", module: __MODULE__)
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
      :ets.insert(@table, {String.to_atom(row.name), row, nil, 0, 0})
    else
      Logger.debug("HookRegistry: skipping #{inspect(row.name)} — no image saved yet", module: __MODULE__)
    end
  end

  defp load(name) do
    case :ets.lookup(@table, name) do
      [{^name, _row, %Hook{} = hook, _used, _pixels}] -> {:ok, hook}
      [{^name, row, nil, _used, _pixels}] -> decode(name, row)
      _ -> {:error, :not_found}
    end
  end

  defp decode(name, row) do
    hook = Hook.from_db_row(row)
    :ets.update_element(@table, name, [{3, hook}, {4, System.monotonic_time()}, {5, pixel_count(hook)}])
    evict_over_budget(name)
    {:ok, hook}
  rescue
    e ->
      Logger.warning(
        "HookRegistry: failed to decode hook #{inspect(row.name)}: #{Exception.message(e)}",
        module: __MODULE__
      )

      :ets.update_element(@table, name, {3, :failed})
      {:error, :not_found}
  end

  defp pixel_count(%Hook{gray_mat: nil}), do: 0

  defp pixel_count(%Hook{gray_mat: gray_mat, mat: mat}) do
    pixels = gray_mat |> Evision.Mat.shape() |> Tuple.to_list() |> Enum.product()
    if mat, do: pixels * 4, else: pixels
  end

  defp evict_over_budget(keep) do
    loaded = :ets.select(@table, [{{:"$1", :_, :_, :"$2", :"$3"}, [{:>, :"$3", 0}], [{{:"$1", :"$2", :"$3"}}]}])

    if Enum.sum_by(loaded, &elem(&1, 2)) > @max_loaded_pixels do
      loaded
      |> Enum.reject(&(elem(&1, 0) == keep))
      |> Enum.sort_by(&elem(&1, 1))
      |> evict_oldest(Enum.sum_by(loaded, &elem(&1, 2)))
    end
  end

  defp evict_oldest([], _total), do: :ok
  defp evict_oldest(_candidates, total) when total <= @max_loaded_pixels, do: :ok

  defp evict_oldest([{name, _used, pixels} | rest], total) do
    :ets.update_element(@table, name, [{3, nil}, {4, 0}, {5, 0}])
    evict_oldest(rest, total - pixels)
  end
end
