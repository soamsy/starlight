defmodule StarlightBotWeb.GameFrameController do
  use StarlightBotWeb, :controller

  alias StarlightBot.Native
  alias StarlightBot.Vision.ImageB64

  @width 448
  @height 252
  @quality 70

  def show(conn, _params) do
    title = Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")

    with {:ok, bgr, w, h} <- Native.grab_frame(title),
         mat = Evision.Mat.from_binary(bgr, {:u, 8}, h, w, 3),
         {:ok, jpeg} <- ImageB64.thumb_jpeg(mat, @width, @height, @quality) do
      conn
      |> put_resp_content_type("image/jpeg", nil)
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, jpeg)
    else
      _ -> send_resp(conn, 503, "")
    end
  end
end
