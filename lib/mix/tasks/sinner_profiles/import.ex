defmodule Mix.Tasks.SinnerProfiles.Import do
  @shortdoc "Import identities from gll-fun as sinner profiles with placeholder locator hooks"
  @moduledoc """
  Upserts one `sinner_profiles` row per gll-fun identity, keyed by `game_id`.
  Existing profiles only get `name_en` and `image_path` refreshed; their `name` and
  `locator_hook` are kept, and a locator hook is only created when none is set.
  Existing hooks are never modified.

      mix sinner_profiles.import
  """

  use Mix.Task
  import Ecto.Query

  alias StarlightBot.{GllFun, Hooks, Repo, SinnerProfiles}

  @images_dir Path.expand("../../../../priv/static/images/identities", __DIR__)
  @image_base "https://gll-fun.com/images/identities"

  @gll_sinners %{"mersault" => "meursault"}

  @region {60, 972, 45, 40}
  @scan_region {60, 972, 1800, 40}
  @match_method "gray"
  @confidence 0.79

  @placeholder_png Base.decode64!(
                     "iVBORw0KGgoAAAANSUhEUgAAAC0AAAAoCAAAAABPvCz1AAABnElEQVQ4EZXBMWgTURzA4d+/HLEJLQg9LlDQoUMlYzLFbl11U3TRSRqHgg7Xrjro2t6g0MF0EXRRdGvXbjVTshno0EGhcOEKQmlSw1GEe++Sy9094b5PKEIoQihCKEIoQsiySos3/1yMQzKEtPr6bWfB8S8Hv4+6pAizaq1VGy04afeZISRZ7r15Ev4eeCEJQoL1rkFK70XIlDBV+m6Tcf7wiglhovJpmRxnT0bEhNjc7l1yddxrNCFW2yuTa7TZRxNi3hoGxy6aoDXe2BgEr3oogrb1CKMvHoqgWDtNjDrbIRFBqeyvYHS6MSQiKNW2g9Gg5RMRlDsf+Y9nP4kISvVDFSP/uU9EUCr7KxidbgyJCIq108Sosx0SETT3MUZfd1EErf7WxiB43UURYt4aBscumhCr7ZXJNdrsowmxOa9Jrh9b12jCRPnzMjnOng6JCVPz35bICB6MmRASrPd1UrovQ6aEJMu9f4OEq0MvJEGYVWut2mjBSbvPDCGtsX7LWXD8y8Gvox4pQpZVWlw6vxiHZAhFCEUIRQhF/AMQQ2QpXZ2PcgAAAABJRU5ErkJggg=="
                   )

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    File.mkdir_p!(@images_dir)

    api_key =
      case GllFun.fetch_api_key() do
        {:ok, key} -> key
        {:error, reason} -> Mix.raise("Couldn't fetch gll-fun's Supabase key: #{inspect(reason)}")
      end

    {:ok, raw} =
      GllFun.rest("ids", api_key, %{"select" => "gameId,nameEN,sinner,imgUrl,releaseDate", "order" => "gameId.asc"})

    identities = raw |> Enum.map(&parse_identity/1) |> Enum.reject(&is_nil/1)
    image_paths = Map.new(identities, &{&1.game_id, ensure_image(&1)})

    counts =
      Repo.checkout(fn ->
        Enum.reduce(identities, %{inserted: 0, updated: 0, hooks: 0}, fn identity, acc ->
          import_identity(identity, image_paths[identity.game_id], acc)
        end)
      end)

    Mix.shell().info(
      "#{length(identities)} identities: #{counts.inserted} new profile(s), " <>
        "#{counts.updated} refreshed, #{counts.hooks} placeholder hook(s) created"
    )
  end

  defp parse_identity(%{"gameId" => game_id, "nameEN" => name_en, "sinner" => gll_sinner, "imgUrl" => img_url} = raw)
       when is_integer(game_id) and is_binary(name_en) and is_binary(gll_sinner) do
    sinner = Map.get(@gll_sinners, gll_sinner, String.replace(gll_sinner, " ", "_"))

    if sinner in SinnerProfiles.sinners() do
      %{
        game_id: game_id,
        name_en: String.trim(name_en),
        sinner: sinner,
        img_url: img_url,
        released_on: parse_release_date(game_id, raw["releaseDate"])
      }
    else
      Mix.shell().error("#{game_id} #{name_en}: unknown sinner #{inspect(gll_sinner)}, skipping")
      nil
    end
  end

  defp parse_identity(raw) do
    Mix.shell().error("Skipping malformed identity: #{inspect(Map.take(raw, ["gameId", "nameEN", "sinner"]))}")
    nil
  end

  defp parse_release_date(game_id, raw) do
    with str when is_binary(str) <- raw,
         [y, m, d] <- release_date_parts(String.trim(str)),
         {:ok, date} <- Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      Date.to_iso8601(date)
    else
      _ ->
        Mix.shell().error("#{game_id}: unparseable releaseDate #{inspect(raw)}")
        nil
    end
  end

  defp release_date_parts(str) do
    case {Regex.run(~r/\A(\d{4})-(\d{2})-(\d{2})\z/, str, capture: :all_but_first),
          Regex.run(~r/\A(\d{2})[.-](\d{2})[.-](\d{4})\z/, str, capture: :all_but_first)} do
      {[y, m, d], _} -> [y, m, d]
      {nil, [m, d, y]} -> [y, m, d]
      _ -> nil
    end
  end

  defp import_identity(identity, image_path, acc) do
    existing =
      Repo.one(
        from p in "sinner_profiles",
          where: p.game_id == ^identity.game_id,
          select: %{id: p.id, locator_hook: p.locator_hook}
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case existing do
      %{id: id, locator_hook: locator_hook} ->
        {hook, created?} =
          if locator_hook, do: {locator_hook, false}, else: ensure_hook(identity, display_name(identity))

        Repo.update_all(
          from(p in "sinner_profiles", where: p.id == ^id),
          set: [
            name_en: identity.name_en,
            image_path: image_path,
            released_on: identity.released_on,
            locator_hook: hook,
            updated_at: now
          ]
        )

        %{acc | updated: acc.updated + 1, hooks: acc.hooks + if(created?, do: 1, else: 0)}

      nil ->
        name = unique_profile_name(display_name(identity), identity.game_id)
        {hook, created?} = ensure_hook(identity, name)

        Repo.insert_all("sinner_profiles", [
          %{
            name: name,
            sinner: identity.sinner,
            game_id: identity.game_id,
            name_en: identity.name_en,
            image_path: image_path,
            released_on: identity.released_on,
            locator_hook: hook,
            inserted_at: now,
            updated_at: now
          }
        ])

        %{acc | inserted: acc.inserted + 1, hooks: acc.hooks + if(created?, do: 1, else: 0)}
    end
  end

  defp display_name(identity) do
    sinner = identity.sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
    "#{identity.name_en} #{sinner}"
  end

  defp unique_profile_name(name, game_id) do
    if Repo.exists?(from p in "sinner_profiles", where: p.name == ^name),
      do: "#{name} (#{game_id})",
      else: name
  end

  defp ensure_hook(identity, notes) do
    base = "locator_#{identity.sinner}_#{slugify(identity.name_en)}"

    name =
      if Repo.exists?(from p in "sinner_profiles", where: p.locator_hook == ^base),
        do: "#{base}_#{identity.game_id}",
        else: base

    if Hooks.get_hook(name) do
      {name, false}
    else
      {rx, ry, rw, rh} = @region
      {sx, sy, sw, sh} = @scan_region

      {:ok, ^name} =
        Hooks.save_hook(%{
          name: name,
          image: @placeholder_png,
          region_x: rx,
          region_y: ry,
          region_w: rw,
          region_h: rh,
          scan_x: sx,
          scan_y: sy,
          scan_w: sw,
          scan_h: sh,
          match_method: @match_method,
          confidence: @confidence,
          notes: notes
        })

      {name, true}
    end
  end

  defp ensure_image(%{game_id: game_id, img_url: img_url}) do
    dest = Path.join(@images_dir, "#{game_id}.webp")
    path = "/images/identities/#{game_id}.webp"

    cond do
      File.exists?(dest) ->
        path

      not is_binary(img_url) ->
        nil

      true ->
        case GllFun.download_image("#{@image_base}/#{img_url}.1.webp") do
          {:ok, bytes} ->
            File.write!(dest, bytes)
            path

          {:error, reason} ->
            Mix.shell().error("Identity image #{game_id}: #{inspect(reason)}")
            nil
        end
    end
  end

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
