defmodule StarlightBotWeb.ScreenshotFrameController do
  use StarlightBotWeb, :controller

  alias StarlightBotWeb.Live.ScreenshotViewerLive

  def show(conn, %{"session_id" => session_id, "frame_id" => frame_id}) do
    with {sid, ""} <- Integer.parse(session_id),
         {id, ".png"} <- Integer.parse(frame_id),
         path = ScreenshotViewerLive.full_path(sid, id),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("image/png", nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
