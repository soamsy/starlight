defmodule Mix.Tasks.ThemePacks.Hooks do
  @shortdoc "Generate detection hooks from imported theme pack poster images"
  @moduledoc """
  For each row in `theme_packs`, ensure a `sleeve_<slug>` hook exists.
  Upsert to hooks table appropriately on run.

      mix theme_packs.hooks
  """

  use Mix.Task
  import Ecto.Query

  alias StarlightBot.Hooks
  alias StarlightBot.Repo

  @region {800, 670, 320, 50}
  @scan_region {180, 440, 1600, 70}
  @match_method "sift"

  @black_pixel_png Base.decode64!(
                      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"
                    )

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    themes =
      Repo.all(
        from t in "theme_packs",
          select: %{id: t.id, name_en: t.name_en}
      )

    {_used, count} =
      Enum.reduce(themes, {MapSet.new(), 0}, fn theme, {used, count} ->
        case generate_hook(theme, used) do
          {:ok, hook_name} ->
            update_theme_pack_hook(theme.id, hook_name)
            {MapSet.put(used, hook_name), count + 1}

          {:error, reason} ->
            Mix.shell().error("#{theme.id}: #{reason}")
            {used, count}
        end
      end)

    Mix.shell().info("Generated/updated #{count} hook(s)")
  end

  defp generate_hook(theme, used) do
    hook_name = unique_slug(theme.name_en, theme.id, used)

    if Hooks.get_hook(hook_name) do
      {:ok, update_metadata_only(hook_name, theme.name_en)}
    else
      insert_new_hook(theme, hook_name)
    end
  end

  defp insert_new_hook(theme, hook_name) do
    save_new_hook(hook_name, @black_pixel_png, theme.name_en)
  end

  defp save_new_hook(hook_name, png, notes) do
    {rx, ry, rw, rh} = @region
    {sx, sy, sw, sh} = @scan_region

    case Hooks.save_hook(%{
           name: hook_name,
           image: png,
           region_x: rx,
           region_y: ry,
           region_w: rw,
           region_h: rh,
           scan_x: sx,
           scan_y: sy,
           scan_w: sw,
           scan_h: sh,
           match_method: @match_method,
           confidence: 0.85,
           notes: notes
         }) do
      {:ok, name} -> {:ok, name}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp update_metadata_only(hook_name, notes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(h in "hooks", where: h.name == ^hook_name),
      set: [notes: notes, match_method: @match_method, confidence: 0.65, updated_at: now]
    )

    StarlightBot.Vision.HookRegistry.invalidate(String.to_atom(hook_name))
    hook_name
  end

  defp update_theme_pack_hook(theme_id, hook_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(t in "theme_packs", where: t.id == ^theme_id),
      set: [hook_name: hook_name, updated_at: now]
    )
  end

  defp unique_slug(name_en, id, used) do
    base = "sleeve_#{slugify(name_en || id)}"
    if MapSet.member?(used, base), do: "#{base}_#{slugify(id)}", else: base
  end

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
