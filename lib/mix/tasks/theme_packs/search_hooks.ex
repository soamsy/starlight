defmodule Mix.Tasks.ThemePacks.SearchHooks do
  @shortdoc "Insert placeholder sleevesearch_<slug> hooks for the theme pack search popup"

  use Mix.Task
  import Ecto.Query

  alias StarlightBot.Hooks
  alias StarlightBot.BaseRepo, as: Repo

  @browser_hook "theme_pack_search_browser"
  @region_size 40
  @match_method "gray"
  @confidence 0.8

  @placeholder_png Base.decode64!(
                     "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAAAAACpleexAAABmElEQVQ4EY3BMWgTYQCG4fcrR2xCC0JDAgUdOlQyJlPs1lU3RRedpHEo6HDtqoOu7Q0KHWwXQRdFN1271UzJZqBDB4VCQgpCaVLDUcx/d2ku6f1yzyNSEimJlERKIiUxzcnMX/9zOvCZJCaVV28W5grts87v/QZxIq5UW84T6R7uthgTY457Z5aYv988nxFxyXlTYUrzmU9EjGS+5rni5P45IRHJfVgkwfGjPgERmtm+TaK6e4EhQqWdLIn66y0MEfJWsDhwMUSg8iqPRfdFkyER2HiA1SePIWE4W1Ws6ps+IIzc3hJWR2s9QBjF3QJWnVobEMat9/zHk5+AMIrvili1n7YBYeT2lrA6WusBwnC2qljVN31ABNyHWH3eZkgEyq/zWHRfNhgSIW8FiwMXQ4RKO1kS9ddbGCI041VJ9GPjAkNEsh8XSXD8uEdAjMx+WeCK7r0BIXHJeVtmSuO5T0SMOe7da8Scf/d8RkRcqbacJ9I93G0xJiZVVm8U5grts86v/SZxYpqTmV84OR34TBIpiZRESiKlf7UuZCkeFLmwAAAAAElFTkSuQmCC"
                   )

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Hooks.get_hook(@browser_hook) do
      %{scan_x: nil, region_x: x, region_y: y, region_w: w, region_h: h} when is_integer(x) ->
        populate({x, y, w, h})

      %{scan_x: x, scan_y: y, scan_w: w, scan_h: h} when is_integer(x) ->
        populate({x, y, w, h})

      _ ->
        Mix.raise("#{@browser_hook} hook is missing or has no region")
    end
  end

  defp populate(browser_rect) do
    themes =
      Repo.all(
        from t in "theme_packs",
          order_by: [asc: t.id],
          select: %{id: t.id, name_en: t.name_en, search_hook_name: t.search_hook_name}
      )

    {_used, inserted, mapped} =
      Enum.reduce(themes, {MapSet.new(), 0, 0}, fn theme, {used, inserted, mapped} ->
        hook_name = unique_slug(theme.name_en, theme.id, used)

        inserted =
          case ensure_hook(hook_name, theme.name_en, browser_rect) do
            :inserted -> inserted + 1
            :exists -> inserted
            {:error, reason} ->
              Mix.shell().error("#{theme.id}: #{reason}")
              inserted
          end

        mapped = if map_if_unset(theme, hook_name), do: mapped + 1, else: mapped
        {MapSet.put(used, hook_name), inserted, mapped}
      end)

    Mix.shell().info("Inserted #{inserted} hook(s), mapped #{mapped} theme pack(s)")
  end

  defp ensure_hook(hook_name, notes, {bx, by, bw, bh}) do
    if Hooks.get_hook(hook_name) do
      :exists
    else
      case Hooks.save_hook(%{
             name: hook_name,
             image: @placeholder_png,
             region_x: bx,
             region_y: by,
             region_w: @region_size,
             region_h: @region_size,
             scan_x: bx,
             scan_y: by,
             scan_w: bw,
             scan_h: bh,
             match_method: @match_method,
             confidence: @confidence,
             notes: "Theme pack search popup: #{notes}"
           }) do
        {:ok, _} -> :inserted
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp map_if_unset(%{search_hook_name: nil, id: id}, hook_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(
        from(t in "theme_packs", where: t.id == ^id and is_nil(t.search_hook_name)),
        set: [search_hook_name: hook_name, updated_at: now]
      )

    n > 0
  end

  defp map_if_unset(_theme, _hook_name), do: false

  defp unique_slug(name_en, id, used) do
    base = "sleevesearch_#{slugify(name_en || id)}"
    if MapSet.member?(used, base), do: "#{base}_#{slugify(id)}", else: base
  end

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
