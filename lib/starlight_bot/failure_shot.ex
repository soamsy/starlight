defmodule StarlightBot.FailureShot do
  alias StarlightBot.{Ctx, Data}
  alias StarlightBot.Vision.Capture

  def record(label, %Ctx{} = ctx) do
    if Data.authoring?() do
      with {:ok, frame} <- Capture.grab_frame(),
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

  defp path(label) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H-%M-%S")
    Path.join(Data.failure_shots_dir(), "#{stamp}_#{label |> to_string() |> String.replace(~r/[^\w.-]+/, "_")}.png")
  end
end
