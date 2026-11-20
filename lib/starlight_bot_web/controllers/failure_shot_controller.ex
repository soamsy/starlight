defmodule StarlightBotWeb.FailureShotController do
  use StarlightBotWeb, :controller

  alias StarlightBot.Data

  def show(conn, %{"name" => name}) do
    path = Path.join(Data.failure_shots_dir(), Path.basename(name))

    if Path.extname(path) == ".png" and File.regular?(path) do
      conn
      |> put_resp_content_type("image/png", nil)
      |> send_file(200, path)
    else
      send_resp(conn, 404, "")
    end
  end
end
