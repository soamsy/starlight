defmodule StarlightBot.ImageThumbs do
  @static_dir Path.expand("../../priv/static", __DIR__)
  @sizes %{"ego_gifts" => "80x80>", "theme_packs" => "64x>"}

  def path(nil), do: nil

  def path(url) when is_binary(url) do
    case String.split(url, "/", trim: true) do
      ["images", dir, file] when is_map_key(@sizes, dir) -> "/images/#{dir}/thumb/#{file}"
      _ -> url
    end
  end

  def generate(url) do
    ["images", dir, file] = String.split(url, "/", trim: true)
    src = Path.join([@static_dir, "images", dir, file])
    dest = Path.join([@static_dir, "images", dir, "thumb", file])

    cond do
      File.exists?(dest) -> :exists
      not File.exists?(src) -> {:error, :missing_source}
      true -> resize(src, dest, Map.fetch!(@sizes, dir))
    end
  end

  def generate_all do
    for dir <- Map.keys(@sizes),
        file <- File.ls!(Path.join([@static_dir, "images", dir])),
        String.ends_with?(file, ".webp"),
        into: %{} do
      {"/images/#{dir}/#{file}", generate("/images/#{dir}/#{file}")}
    end
  end

  defp resize(src, dest, geometry) do
    File.mkdir_p!(Path.dirname(dest))

    case System.cmd("magick", [src, "-resize", geometry, "-quality", "85", dest], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end
end
