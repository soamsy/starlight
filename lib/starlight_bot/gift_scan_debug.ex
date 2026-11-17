defmodule StarlightBot.GiftScanDebug do
  alias StarlightBot.{AppSettings, Data}
  alias StarlightBot.Vision.Frame

  @max_name_length 150

  def enabled?, do: Data.authoring?() and AppSettings.gift_scan_debug?()

  def record(frame_mat, region, gifts) do
    if enabled?() do
      Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> write(frame_mat, region, gifts) end)
    end

    :ok
  end

  defp write(frame_mat, {rx, ry, rw, rh}, gifts) do
    {fh, fw, _} = Evision.Mat.shape(frame_mat)
    x0 = max(0, round(rx))
    y0 = max(0, round(ry))
    x1 = min(fw, round(rx + rw))
    y1 = min(fh, round(ry + rh))

    if x1 > x0 and y1 > y0 do
      dir = Data.gift_scan_debug_dir()
      File.mkdir_p!(dir)
      crop = Frame.crop(frame_mat, {x0, y0, x1 - x0, y1 - y0})
      Evision.imwrite(Path.join(dir, file_name(gifts)), crop)
    end
  rescue
    _ -> :error
  end

  defp file_name(gifts) do
    now = DateTime.utc_now()
    stamp = Calendar.strftime(now, "%Y-%m-%d_%H-%M-%S-") <> millis(now)

    names =
      gifts
      |> Enum.map(& &1.gift_name)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map_join("+", &slug/1)
      |> String.slice(0, @max_name_length)

    stamp <> "_" <> if(names == "", do: "none", else: names) <> ".png"
  end

  defp slug(name), do: name |> String.replace(~r/[^\p{L}\p{N}]+/u, "-") |> String.trim("-")

  defp millis(now), do: now.microsecond |> elem(0) |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
end
