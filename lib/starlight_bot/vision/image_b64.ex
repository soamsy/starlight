defmodule StarlightBot.Vision.ImageB64 do
  def jpeg(mat) do
    case Evision.imencode(".jpg", mat) do
      bin when is_binary(bin) -> Base.encode64(bin)
      _ -> nil
    end
  end

  def thumb(mat, w, h) do
    mat |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_AREA()) |> jpeg()
  end

  def thumb_jpeg(mat, w, h, quality) do
    thumb = Evision.resize(mat, {w, h}, interpolation: Evision.Constant.cv_INTER_AREA())

    case Evision.imencode(".jpg", thumb, params: [Evision.Constant.cv_IMWRITE_JPEG_QUALITY(), quality]) do
      bin when is_binary(bin) -> {:ok, bin}
      _ -> :error
    end
  end
end
