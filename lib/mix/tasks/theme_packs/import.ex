defmodule Mix.Tasks.ThemePacks.Import do
  @shortdoc "Import Mirror Dungeon theme pack data/images from gll-fun"
  @moduledoc """
      mix theme_packs.import
  """

  use Mix.Task

  alias StarlightBot.GllFun
  alias StarlightBot.BaseRepo, as: Repo

  @theme_images_dir Path.expand("../../../../priv/static/images/theme_packs", __DIR__)

  @theme_image_base "https://gll-fun.com/images/md-themes"

  @theme_columns ~w(id name_en name_ru description_en description_ru normal_floors hard_floors tip event_ids image_path)a

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    File.mkdir_p!(@theme_images_dir)

    case GllFun.fetch_api_key() do
      {:ok, api_key} -> do_import(api_key)
      {:error, reason} -> Mix.raise("Couldn't fetch gll-fun's Supabase key: #{inspect(reason)}")
    end
  end

  defp do_import(api_key) do
    {:ok, raw_themes} = GllFun.rest("themes", api_key)

    parsed = Enum.map(raw_themes, &parse_theme/1)
    Enum.each(parsed, &ensure_theme_image/1)

    gift_links =
      Repo.checkout(fn ->
        Enum.reduce(parsed, 0, fn theme, acc ->
          upsert_theme_pack(theme)
          acc + replace_theme_pack_gifts(theme.id, theme.gift_ids)
        end)
      end)

    Mix.shell().info("Imported #{length(parsed)} theme pack(s), #{gift_links} gift link(s)")
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
      gift_ids: parse_gift_ids(raw["uniquegifts"])
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

  defp ensure_theme_image(%{id: id}) do
    dest = Path.join(@theme_images_dir, "#{id}.webp")

    unless File.exists?(dest) do
      case GllFun.download_image("#{@theme_image_base}/#{id}.webp") do
        {:ok, bytes} -> File.write!(dest, bytes)
        {:error, reason} -> Mix.shell().error("Theme image #{id}: #{inspect(reason)}")
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
end
