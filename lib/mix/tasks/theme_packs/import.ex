defmodule Mix.Tasks.ThemePacks.Import do
  @shortdoc "Add new Mirror Dungeon theme packs from gll-fun"
  @moduledoc """
  Theme packs already in `theme_packs` are left alone except for their possible
  bosses, which are refreshed. Only new packs get their poster image downloaded and
  their gift links inserted.

      mix theme_packs.import
  """

  use Mix.Task

  alias StarlightBot.GllFun
  alias StarlightBot.BaseRepo, as: Repo

  @theme_images_dir Path.expand("../../../../priv/static/images/theme_packs", __DIR__)

  @enemy_images_dir Path.expand("../../../../priv/static/images/enemies", __DIR__)

  @theme_image_base "https://gll-fun.com/images/md-themes"
  @enemy_image_base "https://gll-fun.com/images/enemies"

  @theme_columns ~w(id name_en name_ru description_en description_ru normal_floors hard_floors tip event_ids image_path node_count possible_bosses)a

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    StarlightBot.Data.require_authoring!()

    File.mkdir_p!(@theme_images_dir)
    File.mkdir_p!(@enemy_images_dir)

    case GllFun.fetch_api_key() do
      {:ok, api_key} -> do_import(api_key)
      {:error, reason} -> Mix.raise("Couldn't fetch gll-fun's Supabase key: #{inspect(reason)}")
    end
  end

  defp do_import(api_key) do
    {:ok, raw_themes} = GllFun.rest("themes", api_key)

    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, "SELECT id FROM theme_packs", [])
    existing = MapSet.new(rows, &hd/1)
    themes = Enum.map(raw_themes, &parse_theme/1)
    parsed = Enum.reject(themes, &MapSet.member?(existing, &1.id))
    boss_updates = themes |> Enum.filter(&MapSet.member?(existing, &1.id)) |> Enum.map(&update_possible_bosses/1) |> Enum.sum()
    Enum.each(parsed, &ensure_theme_image/1)

    themes
    |> Enum.flat_map(&Jason.decode!(&1.possible_bosses))
    |> Enum.uniq_by(& &1["id"])
    |> Enum.each(&ensure_boss_image/1)

    gift_links =
      Repo.checkout(fn ->
        Enum.reduce(parsed, 0, fn theme, acc ->
          insert_theme_pack(theme)
          acc + add_theme_pack_gifts(theme.id, theme.gift_ids)
        end)
      end)

    Mix.shell().info(
      "Added #{length(parsed)} new theme pack(s) and #{gift_links} gift link(s), " <>
        "refreshed bosses on #{boss_updates} existing pack(s), left the rest of #{MapSet.size(existing)} existing pack(s) untouched"
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
      description_en: StarlightBot.ThemePacks.fix_description(desc_en),
      node_count: StarlightBot.ThemePacks.parse_node_count(desc_en),
      description_ru: desc_ru,
      normal_floors: Jason.encode!(parse_floor_range(normal_raw)),
      hard_floors: Jason.encode!(parse_floor_range(hard_raw)),
      tip: raw["tip"],
      event_ids: raw["events"],
      image_path: "/images/theme_packs/#{id}.webp",
      gift_ids: parse_gift_ids(raw["uniquegifts"]),
      possible_bosses: raw["possiblebosses"] |> StarlightBot.ThemePacks.parse_bosses() |> Jason.encode!()
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

  defp ensure_theme_image(%{id: id}), do: ensure_download(Path.join(@theme_images_dir, "#{id}.webp"), "#{@theme_image_base}/#{id}.webp")

  defp ensure_boss_image(%{"id" => id}) do
    dest = Path.join(@enemy_images_dir, "#{id}.webp")
    {first, rest} = String.split_at(id, 1)
    decapitalized = String.downcase(first) <> rest

    unless File.exists?(dest) do
      with {:error, _} <- GllFun.download_image("#{@enemy_image_base}/#{id}.webp"),
           {:error, reason} <- GllFun.download_image("#{@enemy_image_base}/#{decapitalized}.webp") do
        Mix.shell().error("Image #{Path.basename(dest)}: #{inspect(reason)}")
      else
        {:ok, bytes} -> File.write!(dest, bytes)
      end
    end
  end

  defp ensure_download(dest, url) do
    unless File.exists?(dest) do
      case GllFun.download_image(url) do
        {:ok, bytes} -> File.write!(dest, bytes)
        {:error, reason} -> Mix.shell().error("Image #{Path.basename(dest)}: #{inspect(reason)}")
      end
    end
  end

  defp insert_theme_pack(theme) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    col_names = Enum.map(@theme_columns, &Atom.to_string/1)
    values = Enum.map(@theme_columns, &Map.fetch!(theme, &1)) ++ [now, now]
    placeholders = Enum.map_join(@theme_columns, ", ", fn _ -> "?" end)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO theme_packs (#{Enum.join(col_names, ", ")}, inserted_at, updated_at)
      VALUES (#{placeholders}, ?, ?)
      ON CONFLICT(id) DO NOTHING
      """,
      values
    )
  end

  defp update_possible_bosses(theme) do
    %{num_rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE theme_packs SET possible_bosses = ? WHERE id = ? AND possible_bosses IS NOT ?",
        [theme.possible_bosses, theme.id, theme.possible_bosses]
      )

    rows
  end

  defp add_theme_pack_gifts(theme_id, gift_ids) do
    Enum.each(gift_ids, fn gift_id ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT OR IGNORE INTO theme_pack_gifts (theme_pack_id, gift_id) VALUES (?, ?)",
        [theme_id, gift_id]
      )
    end)

    length(gift_ids)
  end
end
