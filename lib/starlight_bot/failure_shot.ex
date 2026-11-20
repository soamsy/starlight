defmodule StarlightBot.FailureShot do
  alias StarlightBot.{Ctx, Data}
  alias StarlightBot.Vision.Capture

  @retention_days 7
  @max_label_length 80

  def record(label, %Ctx{} = ctx, frame \\ nil) do
    if Data.authoring?() do
      with {:ok, frame} <- frame_or_grab(frame),
           path = path(label),
           :ok <- File.mkdir_p(Path.dirname(path)),
           true <- Evision.imwrite(path, frame.mat) do
        Ctx.log(ctx, :info, "failure screenshot saved: #{path}")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def prune do
    cutoff = System.os_time(:second) - @retention_days * 24 * 60 * 60

    Data.failure_shots_dir()
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.filter(&older_than?(&1, cutoff))
    |> Enum.each(&File.rm/1)
  end

  defp frame_or_grab(nil), do: Capture.grab_frame()
  defp frame_or_grab(frame), do: {:ok, frame}

  defp older_than?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < cutoff
      {:error, _} -> false
    end
  end

  defp path(label) do
    stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d_%H-%M-%S")

    name =
      label
      |> to_string()
      |> String.replace(~r/[^\w.-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_label_length)

    Path.join(Data.failure_shots_dir(), "#{stamp}_#{name}.png")
  end
end
