defmodule Mix.Tasks.EgoGifts.Import do
  @shortdoc "Import ego_gifts data + images from the vendored EgoGiftML submodule"
  @moduledoc """
  Copies the `ego_gifts` table from vendor/EgoGiftML's data/gifts.db into the app database,
  excluding `ui_image_path` and `trouble_rating`. Copies each gift's image from
  vendor/EgoGiftML/data/images/ into priv/static/images/ego_gifts/ and rewrites
  `image_path` to the static URL that serves it.

  Add-only and idempotent: gifts whose `id` already exists are left untouched, and an
  image is only copied when its destination file is missing. It selects an explicit
  column list rather than `SELECT *` so that upstream schema additions can't silently
  change our schema.

      mix ego_gifts.import
  """

  use Mix.Task

  @vendor_dir Path.expand("../../../../vendor/EgoGiftML", __DIR__)
  @source_db Path.join(@vendor_dir, "data/gifts.db")
  @source_images_dir Path.join(@vendor_dir, "data/images")
  @dest_images_dir Path.expand("../../../../priv/static/images/ego_gifts", __DIR__)

  @columns ~w(id name sin affinity tier buying_cost selling_cost obtain_method
              description uptie2 uptie3 ingredients original_id sort_id image_path)

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    StarlightBot.Data.require_authoring!()

    unless File.exists?(@source_db) do
      Mix.raise("#{@source_db} not found — run `git submodule update --init` first")
    end

    File.mkdir_p!(@dest_images_dir)

    count =
      StarlightBot.BaseRepo.checkout(fn ->
        Ecto.Adapters.SQL.query!(StarlightBot.BaseRepo, "ATTACH DATABASE ? AS src", [@source_db])

        rows = fetch_source_rows()

        %{rows: id_rows} = Ecto.Adapters.SQL.query!(StarlightBot.BaseRepo, "SELECT id FROM main.ego_gifts", [])
        existing = MapSet.new(id_rows, &hd/1)

        added = Enum.count(rows, fn row -> not MapSet.member?(existing, row |> List.keyfind!("id", 0) |> elem(1)) and insert_row(row) end)

        Ecto.Adapters.SQL.query!(StarlightBot.BaseRepo, "DETACH DATABASE src", [])
        {added, length(rows) - added}
      end)

    {added, existing} = count
    Mix.shell().info("Added #{added} new ego gift(s), left #{existing} existing one(s) untouched")
  end

  defp fetch_source_rows do
    select_list = Enum.join(@columns, ", ")

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        StarlightBot.BaseRepo,
        "SELECT #{select_list} FROM src.ego_gifts",
        []
      )

    Enum.map(rows, &Enum.zip(@columns, &1))
  end

  defp insert_row(row) do
    row = Map.new(row, fn {k, v} -> {k, v} end)
    row = Map.update!(row, "image_path", &copy_image_and_rewrite/1)

    values = Enum.map(@columns, &Map.fetch!(row, &1))
    placeholders = Enum.map_join(@columns, ", ", fn _ -> "?" end)

    %{num_rows: inserted} =
      Ecto.Adapters.SQL.query!(
        StarlightBot.BaseRepo,
        """
        INSERT INTO ego_gifts (#{Enum.join(@columns, ", ")})
        VALUES (#{placeholders})
        ON CONFLICT(id) DO NOTHING
        """,
        values
      )

    inserted > 0
  end

  defp copy_image_and_rewrite(nil), do: nil

  defp copy_image_and_rewrite(source_path) do
    basename = Path.basename(source_path)
    src = Path.join(@source_images_dir, basename)

    dest = Path.join(@dest_images_dir, basename)

    if File.exists?(src) do
      unless File.exists?(dest), do: File.cp!(src, dest)
      "/images/ego_gifts/#{basename}"
    else
      Mix.shell().error("Missing source image, skipping copy: #{src}")
      nil
    end
  end
end
