defmodule Mix.Tasks.Images.Thumbs do
  @shortdoc "Generate missing UI thumbnails for ego gift and theme pack images"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    results = StarlightBot.ImageThumbs.generate_all()
    counts = results |> Map.values() |> Enum.frequencies_by(fn r -> if is_tuple(r), do: :error, else: r end)
    Mix.shell().info("thumbnails: #{inspect(counts)}")

    for {url, {:error, reason}} <- results, do: Mix.shell().error("#{url}: #{inspect(reason)}")
  end
end
