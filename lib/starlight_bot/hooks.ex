defmodule StarlightBot.Hooks do

  require Logger
  import Ecto.Query
  alias StarlightBot.Repo
  alias StarlightBot.Vision.HookRegistry

  def image_path(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9_]+\z/, name) do
      Path.join(Application.fetch_env!(:starlight_bot, :hook_image_dir), name <> ".png")
    end
  end

  @doc "List all hooks (metadata only, no image binary) ordered by name."
  def list_hooks do
    Repo.all(
      from h in "hooks",
        order_by: [asc: h.name],
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
          feature_channel: h.feature_channel,
          confidence: h.confidence,
          notes: h.notes,
          inserted_at: h.inserted_at
        }
    )
  rescue
    _ -> []
  end

  @doc "Map of hook name => updated_at for hooks that have a template image, used to version thumbnail URLs."
  def hook_thumbnails do
    Repo.all(from h in "hooks", select: {h.name, h.updated_at})
    |> Enum.filter(fn {name, _} -> File.exists?(image_path(name)) end)
    |> Map.new()
  rescue
    _ -> %{}
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

  @doc "Get a single hook by name, including image binary. Returns nil if not found."
  def get_hook(name) when is_binary(name) do
    Repo.one(
      from h in "hooks",
        where: h.name == ^name,
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
          feature_channel: h.feature_channel,
          confidence: h.confidence,
          notes: h.notes
        }
    )
    |> case do
      nil -> nil
      hook -> Map.put(hook, :image, get_hook_image(name))
    end
  rescue
    _ -> nil
  end

  @doc """
  Insert or update a hook. `attrs` must include:
    :name (string), :image (PNG binary or nil), :match_method (string), :confidence (float).
  Optional: :region_x, :region_y, :region_w, :region_h (all four needed for a region), :notes.
  Returns {:ok, name} or {:error, reason}.
  """
  def save_hook(%{name: name} = attrs) when is_binary(name) and name != "" do
    exists = Repo.one(from h in "hooks", where: h.name == ^name, select: h.name)

    cond do
      is_nil(image_path(name)) -> {:error, :invalid_name}
      exists -> update_hook(attrs)
      true -> insert_hook(attrs)
    end
  end

  def save_hook(_), do: {:error, :name_required}

  @doc "Delete a hook from the database and evict from registry."
  def delete_hook(name) when is_binary(name) do
    {n, _} = Repo.delete_all(from h in "hooks", where: h.name == ^name)

    if n > 0 do
      File.rm(image_path(name))
      :ets.delete(:hook_registry, String.to_atom(name))
      {:ok, name}
    else
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

    with new_path when is_binary(new_path) <- image_path(new_name) || {:error, :invalid_name},
         {n, _} when n > 0 <-
           Repo.update_all(
             from(h in "hooks", where: h.name == ^old_name),
             set: [name: new_name, updated_at: now]
           ) do
      File.rename(image_path(old_name), new_path)
      :ets.delete(:hook_registry, String.to_atom(old_name))
      HookRegistry.invalidate(String.to_atom(new_name))
      {:ok, new_name}
    else
      {:error, :invalid_name} = error -> error
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
          min_cluster_size: hook.min_cluster_size,
          match_method: hook.match_method,
          feature_channel: hook.feature_channel,
          confidence: hook.confidence,
          notes: hook.notes
        }

        insert_hook(attrs)
    end
  end

  @doc "Replace the template image for a hook and invalidate registry."
  def update_hook_image(name, png_binary) when is_binary(name) and is_binary(png_binary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(
        from(h in "hooks", where: h.name == ^name),
        set: [updated_at: now]
      )

    if n > 0 do
      write_image!(name, png_binary)
      HookRegistry.invalidate(String.to_atom(name))
      {:ok, name}
    else
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

    {n, _} =
      Repo.update_all(
        from(h in "hooks", where: h.name == ^name),
        set: [notes: notes, updated_at: now]
      )

    if n > 0, do: {:ok, name}, else: {:error, :not_found}
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  # --- Private ---
  defp bool?(val), do: val in [true, 1, "true", "on"]

  defp feature_channel_value(v) when v in [nil, "", "gray"], do: nil
  defp feature_channel_value(v), do: v

  defp write_image!(name, png) do
    path = image_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, png)
  end

  defp insert_hook(attrs) do
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
      min_cluster_size: attrs[:min_cluster_size],
      match_method: attrs[:match_method] || attrs.match_method || "gray",
      feature_channel: feature_channel_value(attrs[:feature_channel]),
      confidence: attrs[:confidence] || attrs.confidence || 0.85,
      notes: attrs[:notes],
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all("hooks", [row]) do
      {1, _} ->
        if image = attrs[:image] || attrs.image, do: write_image!(name, image)
        HookRegistry.invalidate(String.to_atom(name))
        {:ok, name}

      _ ->
        {:error, :insert_failed}
    end
  rescue
    e ->
      Logger.error("Hooks DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  defp update_hook(attrs) do
    name = attrs[:name] || attrs.name
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if is_nil(Repo.one(from h in "hooks", where: h.name == ^name, select: h.name)) do
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

      updates =
        region_update ++
          click_update ++
          scan_update ++
          color_update ++
          [
            match_method: attrs[:match_method] || attrs.match_method || "gray",
            feature_channel: feature_channel_value(attrs[:feature_channel]),
            confidence: attrs[:confidence] || attrs.confidence || 0.85,
            mask: bool?(attrs[:mask]),
            min_cluster_size: attrs[:min_cluster_size],
            notes: attrs[:notes],
            updated_at: now
          ]

      {n, _} = Repo.update_all(from(h in "hooks", where: h.name == ^name), set: updates)

      if n > 0 do
        if image = attrs[:image] || attrs.image, do: write_image!(name, image)
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
end
