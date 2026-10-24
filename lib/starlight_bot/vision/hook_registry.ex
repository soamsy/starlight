defmodule StarlightBot.Vision.HookRegistry do
  use GenServer
  require Logger
  import Ecto.Query
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
    rows =
      try do
        StarlightBot.Repo.all(
          from h in "hooks",
            select: %{
              name: h.name,
              region_x: h.region_x,
              region_y: h.region_y,
              region_w: h.region_w,
              region_h: h.region_h,
              click_x: h.click_x,
              click_y: h.click_y,
              click_w: h.click_w,
              click_h: h.click_h,
              scan_x: h.scan_x,
              scan_y: h.scan_y,
              scan_w: h.scan_w,
              scan_h: h.scan_h,
              mask: h.mask,
              color_h: h.color_h,
              color_s: h.color_s,
              color_v: h.color_v,
              min_cluster_size: h.min_cluster_size,
              match_method: h.match_method,
              confidence: h.confidence,
              notes: h.notes
            }
        )
      rescue
        e ->
          Logger.warning(
            "HookRegistry: could not query hooks (run `mix db.setup`?): #{Exception.message(e)}",
            module: __MODULE__
          )
          []
      end

    Enum.each(rows, &insert_row/1)
    Logger.info("HookRegistry: loaded #{length(rows)} hook(s)", module: __MODULE__)
  end

  defp reload_one(name) do
    name_str = Atom.to_string(name)

    row =
      try do
        StarlightBot.Repo.one(
          from h in "hooks",
            where: h.name == ^name_str,
            select: %{
              name: h.name,
              region_x: h.region_x,
              region_y: h.region_y,
              region_w: h.region_w,
              region_h: h.region_h,
              click_x: h.click_x,
              click_y: h.click_y,
              click_w: h.click_w,
              click_h: h.click_h,
              scan_x: h.scan_x,
              scan_y: h.scan_y,
              scan_w: h.scan_w,
              scan_h: h.scan_h,
              mask: h.mask,
              color_h: h.color_h,
              color_s: h.color_s,
              color_v: h.color_v,
              min_cluster_size: h.min_cluster_size,
              match_method: h.match_method,
              confidence: h.confidence,
              notes: h.notes
            }
        )
      rescue
        _ -> nil
      end

    case row do
      nil ->
        :ets.delete(@table, name)
        Logger.debug("HookRegistry: evicted #{name}", module: __MODULE__)

      row ->
        insert_row(row)
        Logger.debug("HookRegistry: reloaded #{name}", module: __MODULE__)
    end
  end

  defp insert_row(row) do
    if File.exists?(Hooks.image_path(row.name)) do
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
