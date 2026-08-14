defmodule Mix.Tasks.ThemePacks.Import do
  @shortdoc "Import Mirror Dungeon theme pack + boss data/images from gll-fun"
  @moduledoc """
      mix theme_packs.import
  """

  use Mix.Task

  alias StarlightBot.GllFun
  alias StarlightBot.Repo

  @theme_images_dir Path.expand("../../../../priv/static/images/theme_packs", __DIR__)
  @boss_images_dir Path.expand("../../../../priv/static/images/bosses", __DIR__)

  @theme_image_base "https://gll-fun.com/images/md-themes"
  @boss_image_base "https://gll-fun.com/images/enemies"

  @boss_re ~r/([^,\[]+)\[([^|]+)\|([^\]]+)\]/

  @theme_columns ~w(id name_en name_ru description_en description_ru normal_floors hard_floors tip event_ids image_path)a

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    File.mkdir_p!(@theme_images_dir)
    File.mkdir_p!(@boss_images_dir)

    case GllFun.fetch_api_key() do
      {:ok, api_key} -> do_import(api_key)
      {:error, reason} -> Mix.raise("Couldn't fetch gll-fun's Supabase key: #{inspect(reason)}")
    end
  end

  defp do_import(api_key) do
    {:ok, raw_themes} = GllFun.rest("themes", api_key)

    parsed = Enum.map(raw_themes, &parse_theme/1)
    Enum.each(parsed, &ensure_theme_image/1)

    all_bosses = parsed |> Enum.flat_map(& &1.bosses) |> Enum.uniq_by(& &1.slug)
    boss_image_paths = Map.new(all_bosses, fn b -> {b.slug, ensure_boss_image(b.slug)} end)

    {gift_links, boss_links} =
      Repo.checkout(fn ->
        Enum.each(all_bosses, fn b ->
          upsert_boss(b.slug, b.name_en, b.name_ru, boss_image_paths[b.slug])
        end)

        Enum.reduce(parsed, {0, 0}, fn theme, {g_acc, b_acc} ->
          upsert_theme_pack(theme)
          g = replace_theme_pack_gifts(theme.id, theme.gift_ids)
          b = replace_theme_pack_bosses(theme.id, Enum.map(theme.bosses, & &1.slug))
          {g_acc + g, b_acc + b}
        end)
      end)

    Mix.shell().info(
      "Imported #{length(parsed)} theme pack(s), #{gift_links} gift link(s), " <>
        "#{length(all_bosses)} boss(es), #{boss_links} boss link(s)"
    )
  end

  defp parse_theme(raw) do
    id = raw["id"]
    {name_ru, name_en} = split_pipe(raw["name"])
    {desc_ru, desc_en} = split_pipe(raw["description"])
    {normal_raw, hard_raw} = split_pipe(raw["complexity"])

    %{
      id: id,
      name_en: name_en || name_ru,
      name_ru: name_ru,
      description_en: desc_en,
      description_ru: desc_ru,
      normal_floors: Jason.encode!(parse_floor_range(normal_raw)),
      hard_floors: Jason.encode!(parse_floor_range(hard_raw)),
      tip: raw["tip"],
      event_ids: raw["events"],
      image_path: "/images/theme_packs/#{id}.webp",
      gift_ids: parse_gift_ids(raw["uniquegifts"]),
      bosses: parse_bosses(raw["possiblebosses"])
    }
  end

  defp split_pipe(nil), do: {nil, nil}

  defp split_pipe(str) do
    case String.split(str, "|", parts: 2) do
      [a, b] -> {String.trim(a), String.trim(b)}
      [a] -> {String.trim(a), nil}
    end
  end

  defp parse_floor_range(nil), do: []
  defp parse_floor_range(""), do: []

  defp parse_floor_range(str) do
    case String.split(String.trim(str), "-") do
      [single] ->
        case Integer.parse(single) do
          {n, ""} -> [n]
          _ -> []
        end

      [a, b] ->
        with {lo, ""} <- Integer.parse(a), {hi, ""} <- Integer.parse(b) do
          Enum.to_list(lo..hi)
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp parse_gift_ids(nil), do: []

  defp parse_gift_ids(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_bosses(nil), do: []

  defp parse_bosses(str) do
    @boss_re
    |> Regex.scan(str)
    |> Enum.map(fn [_, slug, ru, en] ->
      %{slug: String.trim(slug), name_ru: String.trim(ru), name_en: String.trim(en)}
    end)
    |> Enum.uniq_by(& &1.slug)
  end

  defp ensure_theme_image(%{id: id}) do
    dest = Path.join(@theme_images_dir, "#{id}.webp")

    unless File.exists?(dest) do
      case GllFun.download_image("#{@theme_image_base}/#{id}.webp") do
        {:ok, bytes} -> File.write!(dest, bytes)
        {:error, reason} -> Mix.shell().error("Theme image #{id}: #{inspect(reason)}")
      end
    end
  end

  defp ensure_boss_image(slug) do
    dest = Path.join(@boss_images_dir, "#{slug}.webp")
    path = "/images/bosses/#{slug}.webp"

    if File.exists?(dest) do
      path
    else
      case GllFun.download_image("#{@boss_image_base}/#{slug}.webp") do
        {:ok, bytes} ->
          File.write!(dest, bytes)
          path

        {:error, reason} ->
          Mix.shell().error("Boss image #{slug}: #{inspect(reason)}")
          nil
      end
    end
  end

  defp upsert_theme_pack(theme) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    col_names = Enum.map(@theme_columns, &Atom.to_string/1)
    values = Enum.map(@theme_columns, &Map.fetch!(theme, &1)) ++ [now, now]
    placeholders = Enum.map_join(@theme_columns, ", ", fn _ -> "?" end)
    update_set = col_names -- ["id"] |> Enum.map_join(", ", fn c -> "#{c} = excluded.#{c}" end)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO theme_packs (#{Enum.join(col_names, ", ")}, inserted_at, updated_at)
      VALUES (#{placeholders}, ?, ?)
      ON CONFLICT(id) DO UPDATE SET #{update_set}, updated_at = excluded.updated_at
      """,
      values
    )
  end

  defp upsert_boss(slug, name_en, name_ru, image_path) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO bosses (slug, name_en, name_ru, image_path)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(slug) DO UPDATE SET
        name_en = excluded.name_en,
        name_ru = excluded.name_ru,
        image_path = COALESCE(excluded.image_path, bosses.image_path)
      """,
      [slug, name_en, name_ru, image_path]
    )
  end

  defp replace_theme_pack_gifts(theme_id, gift_ids) do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM theme_pack_gifts WHERE theme_pack_id = ?", [theme_id])

    Enum.each(gift_ids, fn gift_id ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO theme_pack_gifts (theme_pack_id, gift_id) VALUES (?, ?)",
        [theme_id, gift_id]
      )
    end)

    length(gift_ids)
  end

  defp replace_theme_pack_bosses(theme_id, slugs) do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM theme_pack_bosses WHERE theme_pack_id = ?", [theme_id])

    Enum.each(slugs, fn slug ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO theme_pack_bosses (theme_pack_id, boss_slug) VALUES (?, ?)",
        [theme_id, slug]
      )
    end)

    length(slugs)
  end
end
