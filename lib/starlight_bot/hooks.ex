defmodule StarlightBot.Hooks do

  require Logger
  import Ecto.Query
  alias StarlightBot.{BaseRepo, Data, Repo}
  alias StarlightBot.Vision.HookRegistry

  @categories ~w(general sleeve sleevesearch locator team team_selected)

  @fields ~w(name region_x region_y region_w region_h click_x click_y click_w click_h scan_x scan_y scan_w scan_h mask color_h color_s color_v tol_h tol_s tol_v min_cluster_size match_method confidence notes category inserted_at updated_at)a

  def categories, do: @categories

  def category_for("sleevesearch_" <> _), do: "sleevesearch"
  def category_for("sleeve_" <> _), do: "sleeve"
  def category_for("locator_" <> _), do: "locator"
  def category_for("team_select" <> _), do: "general"

  def category_for("team_" <> rest) do
    if String.ends_with?(rest, "_selected"), do: "team_selected", else: "team"
  end

  def category_for(_name), do: "general"

  def resolve_category(category, _name) when category in @categories, do: category
  def resolve_category(_category, name), do: category_for(name)

  def image_path(%{name: name} = row), do: image_path(name, row[:source])

  def image_path(name) when is_binary(name) do
    source = (effective_row(name) || %{})[:source]
    image_path(name, source)
  end

  def image_path(name, source) when is_binary(name) do
    if valid_name?(name), do: Path.join(dir_for(source), name <> ".png")
  end

  def editable?(%{source: source}) do
    Data.base_writable?() or source in [:override, :user]
  end

  defp valid_name?(name), do: Regex.match?(~r/\A[a-z0-9_]+\z/, name)

  defp dir_for(:base), do: Data.base_hooks_dir()
  defp dir_for(nil), do: target().dir
  defp dir_for(_), do: Data.user_hooks_dir()

  @doc "List all hooks (metadata only, no image binary) ordered by name."
  def list_hooks, do: effective_rows()
  def list_hooks(category) when category in @categories, do: Enum.filter(effective_rows(), &(&1.category == category))

  def list_names(category) when category in @categories do
    category |> list_hooks() |> Enum.map(& &1.name)
  end

  def category_counts, do: category_counts(effective_rows())

  def category_counts(rows) do
    counts = Enum.frequencies_by(rows, & &1.category)
    Map.new(@categories, &{&1, Map.get(counts, &1, 0)})
  end

  @doc "Map of hook name => updated_at for hooks that have a template image, used to version thumbnail URLs."
  def hook_thumbnails(category) when category in @categories, do: thumbnails_for(list_hooks(category))

  def thumbnails_for(rows) do
    for row <- rows, File.exists?(image_path(row)), into: %{}, do: {row.name, row.updated_at}
  end

  @doc "Template image binary for a hook, or nil if the hook or image is missing."
  def get_hook_image(name) when is_binary(name) do
    with path when is_binary(path) <- image_path(name),
         {:ok, png} <- File.read(path) do
      png
    else
      _ -> nil
    end
  end

  def get_hook_image(name, source) when is_binary(name) do
    with path when is_binary(path) <- image_path(name, source),
         {:ok, png} <- File.read(path) do
      png
    else
      _ -> nil
    end
  end

  @doc "Get a single hook by name, including image binary. Returns nil if not found."
  def get_hook(name) when is_binary(name) do
    case effective_row(name) do
      nil -> nil
      hook -> Map.put(hook, :image, get_hook_image(name))
    end
  end

  def effective_rows do
    merge(fetch_base(nil), fetch_overrides(nil))
  rescue
    _ -> []
  end

  def effective_row(name) when is_binary(name) do
    merge(fetch_base(name), fetch_overrides(name)) |> List.first()
  rescue
    _ -> nil
  end

  defp fetch_base(nil), do: BaseRepo.all(from h in "hooks", select: map(h, ^(@fields ++ [:version])))

  defp fetch_base(name),
    do: BaseRepo.all(from h in "hooks", where: h.name == ^name, select: map(h, ^(@fields ++ [:version])))

  defp fetch_overrides(nil), do: Repo.all(from h in "hook_overrides", select: map(h, ^(@fields ++ [:base_version])))

  defp fetch_overrides(name),
    do: Repo.all(from h in "hook_overrides", where: h.name == ^name, select: map(h, ^(@fields ++ [:base_version])))

  defp merge(base, overrides) do
    overrides_by_name = Map.new(overrides, &{&1.name, &1})
    base_names = MapSet.new(base, & &1.name)

    from_base =
      Enum.map(base, fn b ->
        case overrides_by_name[b.name] do
          %{base_version: v} = o when v == b.version ->
            o |> Map.put(:source, :override) |> Map.put(:retired, false) |> Map.put(:version, b.version)

          %{} = o ->
            b |> Map.put(:source, :base) |> Map.put(:retired, true) |> Map.put(:base_version, o.base_version)

          nil ->
            b |> Map.put(:source, :base) |> Map.put(:retired, false) |> Map.put(:base_version, nil)
        end
      end)

    user_only =
      for o <- overrides, not MapSet.member?(base_names, o.name) do
        o |> Map.put(:source, :user) |> Map.put(:retired, false) |> Map.put(:version, nil)
      end

    Enum.sort_by(from_base ++ user_only, & &1.name)
  end

  defp target do
    if Data.base_writable?() do
      %{layer: :base, repo: BaseRepo, table: "hooks", dir: Data.base_hooks_dir()}
    else
      %{layer: :user, repo: Repo, table: "hook_overrides", dir: Data.user_hooks_dir()}
    end
  end

  defp target_path(t, name) do
    if valid_name?(name), do: Path.join(t.dir, name <> ".png")
  end

  defp in_layer?(t, name) do
    table = t.table
    not is_nil(t.repo.one(from h in table, where: h.name == ^name, select: h.name))
  end

  defp base_row(name), do: List.first(fetch_base(name))

  defp read_only?(t, name), do: t.layer == :user and not is_nil(base_row(name)) and not in_layer?(t, name)

  defp restamp(%{layer: :user} = t, name) do
    case base_row(name) do
      %{version: version} ->
        table = t.table
        t.repo.update_all(from(h in table, where: h.name == ^name), set: [base_version: version])

      nil ->
        :ok
    end
  end

  defp restamp(_t, _name), do: :ok

  def override_hook(name) when is_binary(name) do
    t = target()
    base = base_row(name)

    cond do
      t.layer != :user -> {:error, :not_user_mode}
      is_nil(base) -> {:error, :not_found}
      in_layer?(t, name) -> {:error, :already_overridden}
      true ->
        row = base |> Map.drop([:version]) |> Map.put(:base_version, base.version)
        src = Path.join(Data.base_hooks_dir(), name <> ".png")
        dest = target_path(t, name)
        File.mkdir_p!(Path.dirname(dest))
        if File.exists?(src), do: File.cp!(src, dest)
        {1, _} = Repo.insert_all("hook_overrides", [row])
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}
    end
  end

  def reapply_hook(name) when is_binary(name) do
    t = target()

    cond do
      t.layer != :user -> {:error, :not_user_mode}
      not in_layer?(t, name) -> {:error, :not_found}
      true ->
        restamp(t, name)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}
    end
  end

  def bump_version(name) when is_binary(name) do
    t = target()

    if t.layer == :base do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {n, _} = BaseRepo.update_all(from(h in "hooks", where: h.name == ^name), inc: [version: 1], set: [updated_at: now])
      if n > 0, do: {:ok, name}, else: {:error, :not_found}
    else
      {:error, :not_authoring}
    end
  end

  @doc """
  Insert or update a hook. `attrs` must include:
    :name (string), :image (PNG binary or nil), :match_method (string), :confidence (float).
  Optional: :region_x, :region_y, :region_w, :region_h (all four needed for a region), :notes.
  Returns {:ok, name} or {:error, reason}.
  """
  def save_hook(%{name: name} = attrs) when is_binary(name) and name != "" do
    t = target()

    cond do
      is_nil(target_path(t, name)) -> {:error, :invalid_name}
      in_layer?(t, name) -> update_hook(t, attrs)
      read_only?(t, name) -> {:error, :read_only}
      true -> insert_hook(t, attrs)
    end
  end

  def save_hook(_), do: {:error, :name_required}

  @doc "Delete a hook from the database and evict from registry."
  def delete_hook(name) when is_binary(name) do
    t = target()
    table = t.table
    read_only = read_only?(t, name)
    {n, _} = t.repo.delete_all(from h in table, where: h.name == ^name)

    cond do
      n > 0 ->
        File.rm(target_path(t, name))
        :ets.delete(:hook_registry, String.to_atom(name))
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}

      read_only ->
        {:error, :read_only}

      true ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  @doc "Rename a hook in-place; image and region are preserved."
  def rename_hook(old_name, new_name)
      when is_binary(old_name) and is_binary(new_name) and old_name != new_name and new_name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    t = target()
    table = t.table

    with {:ok, new_path} <- (target_path(t, new_name) && {:ok, target_path(t, new_name)}) || {:error, :invalid_name},
         :ok <- if(t.layer == :user and not is_nil(base_row(old_name)), do: {:error, :read_only}, else: :ok),
         :ok <- if(t.layer == :user and not is_nil(base_row(new_name)), do: {:error, :name_taken}, else: :ok),
         {n, _} when n > 0 <-
           t.repo.update_all(
             from(h in table, where: h.name == ^old_name),
             set: [name: new_name, updated_at: now]
           ) do
      File.rename(target_path(t, old_name), new_path)
      :ets.delete(:hook_registry, String.to_atom(old_name))
      HookRegistry.invalidate(String.to_atom(new_name))
      {:ok, new_name}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  @doc "Duplicate a hook with a new name (copies image and region inline)."
  def duplicate_hook(source_name, new_name) when is_binary(source_name) and is_binary(new_name) do
    case get_hook(source_name) do
      nil ->
        {:error, :not_found}

      hook ->
        attrs = %{
          name: new_name,
          image: hook.image,
          region_x: hook.region_x,
          region_y: hook.region_y,
          region_w: hook.region_w,
          region_h: hook.region_h,
          click_x: hook.click_x,
          click_y: hook.click_y,
          click_w: hook.click_w,
          click_h: hook.click_h,
          scan_x: hook.scan_x,
          scan_y: hook.scan_y,
          scan_w: hook.scan_w,
          scan_h: hook.scan_h,
          mask: hook.mask,
          color_h: hook.color_h,
          color_s: hook.color_s,
          color_v: hook.color_v,
          tol_h: hook.tol_h,
          tol_s: hook.tol_s,
          tol_v: hook.tol_v,
          min_cluster_size: hook.min_cluster_size,
          match_method: hook.match_method,
          confidence: hook.confidence,
          notes: hook.notes
        }

        insert_hook(target(), attrs)
    end
  end

  @doc "Replace the template image for a hook and invalidate registry."
  def update_hook_image(name, png_binary) when is_binary(name) and is_binary(png_binary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    t = target()
    table = t.table

    {n, _} =
      t.repo.update_all(
        from(h in table, where: h.name == ^name),
        set: [updated_at: now]
      )

    cond do
      n > 0 ->
        write_image!(t, name, png_binary)
        restamp(t, name)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}

      read_only?(t, name) ->
        {:error, :read_only}

      true ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  @doc "Update just the notes field for a hook."
  def update_notes(name, notes) when is_binary(name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    t = target()
    table = t.table

    {n, _} =
      t.repo.update_all(
        from(h in table, where: h.name == ^name),
        set: [notes: notes, updated_at: now]
      )

    cond do
      n > 0 ->
        restamp(t, name)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}

      read_only?(t, name) ->
        {:error, :read_only}

      true ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  # --- Private ---
  defp bool?(val), do: val in [true, 1, "true", "on"]

  defp write_image!(t, name, png) do
    path = target_path(t, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, png)
  end

  defp insert_hook(t, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    name = attrs[:name] || attrs.name

    row = %{
      name: name,
      region_x: attrs[:region_x],
      region_y: attrs[:region_y],
      region_w: attrs[:region_w],
      region_h: attrs[:region_h],
      click_x: attrs[:click_x],
      click_y: attrs[:click_y],
      click_w: attrs[:click_w],
      click_h: attrs[:click_h],
      scan_x: attrs[:scan_x],
      scan_y: attrs[:scan_y],
      scan_w: attrs[:scan_w],
      scan_h: attrs[:scan_h],
      mask: bool?(attrs[:mask]),
      color_h: attrs[:color_h],
      color_s: attrs[:color_s],
      color_v: attrs[:color_v],
      tol_h: attrs[:tol_h],
      tol_s: attrs[:tol_s],
      tol_v: attrs[:tol_v],
      min_cluster_size: attrs[:min_cluster_size],
      match_method: attrs[:match_method] || attrs.match_method || "gray",
      confidence: attrs[:confidence] || attrs.confidence || 0.85,
      notes: attrs[:notes],
      category: resolve_category(attrs[:category], name),
      inserted_at: now,
      updated_at: now
    }

    row = if t.layer == :user, do: Map.put(row, :base_version, nil), else: row
    table = t.table

    case insert_checked(t, table, name, row) do
      {1, _} ->
        if image = attrs[:image] || attrs.image, do: write_image!(t, name, image)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}

      {:error, _} = error ->
        error

      _ ->
        {:error, :insert_failed}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  defp update_hook(t, attrs) do
    name = attrs[:name] || attrs.name
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    table = t.table

    if is_nil(t.repo.one(from h in table, where: h.name == ^name, select: h.name)) do
      {:error, :not_found}
    else
      rx = attrs[:region_x]
      ry = attrs[:region_y]
      rw = attrs[:region_w]
      rh = attrs[:region_h]

      region_update =
        cond do
          is_integer(rx) and is_integer(ry) and is_integer(rw) and is_integer(rh) ->
            [region_x: rx, region_y: ry, region_w: rw, region_h: rh]

          is_nil(rx) and is_nil(ry) and is_nil(rw) and is_nil(rh) ->
            [region_x: nil, region_y: nil, region_w: nil, region_h: nil]

          true ->
            []
        end

      cx = attrs[:click_x]
      cy = attrs[:click_y]
      cw = attrs[:click_w]
      ch = attrs[:click_h]

      click_update =
        cond do
          is_integer(cx) and is_integer(cy) and is_integer(cw) and is_integer(ch) ->
            [click_x: cx, click_y: cy, click_w: cw, click_h: ch]

          is_nil(cx) and is_nil(cy) and is_nil(cw) and is_nil(ch) ->
            [click_x: nil, click_y: nil, click_w: nil, click_h: nil]

          true ->
            []
        end

      sx = attrs[:scan_x]
      sy = attrs[:scan_y]
      sw = attrs[:scan_w]
      sh = attrs[:scan_h]

      scan_update =
        cond do
          is_integer(sx) and is_integer(sy) and is_integer(sw) and is_integer(sh) ->
            [scan_x: sx, scan_y: sy, scan_w: sw, scan_h: sh]

          is_nil(sx) and is_nil(sy) and is_nil(sw) and is_nil(sh) ->
            [scan_x: nil, scan_y: nil, scan_w: nil, scan_h: nil]

          true ->
            []
        end

      col_h = attrs[:color_h]
      col_s = attrs[:color_s]
      col_v = attrs[:color_v]

      color_update =
        cond do
          is_integer(col_h) and is_integer(col_s) and is_integer(col_v) ->
            [color_h: col_h, color_s: col_s, color_v: col_v]

          is_nil(col_h) and is_nil(col_s) and is_nil(col_v) ->
            [color_h: nil, color_s: nil, color_v: nil]

          true ->
            []
        end

      category_update =
        if attrs[:category] in @categories, do: [category: attrs[:category]], else: []

      updates =
        region_update ++
          click_update ++
          scan_update ++
          color_update ++
          category_update ++
          [
            match_method: attrs[:match_method] || attrs.match_method || "gray",
            confidence: attrs[:confidence] || attrs.confidence || 0.85,
            mask: bool?(attrs[:mask]),
            min_cluster_size: attrs[:min_cluster_size],
            tol_h: attrs[:tol_h],
            tol_s: attrs[:tol_s],
            tol_v: attrs[:tol_v],
            notes: attrs[:notes],
            updated_at: now
          ]

      {n, _} = t.repo.update_all(from(h in table, where: h.name == ^name), set: updates)

      if n > 0 do
        if image = attrs[:image] || attrs.image, do: write_image!(t, name, image)
        restamp(t, name)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}
      else
        {:error, :not_found}
      end
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  defp insert_checked(%{layer: :user} = t, table, name, row) do
    if is_nil(base_row(name)), do: t.repo.insert_all(table, [row]), else: {:error, :name_taken}
  end

  defp insert_checked(t, table, _name, row), do: t.repo.insert_all(table, [row])
end
