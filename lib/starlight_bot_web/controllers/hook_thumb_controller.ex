defmodule StarlightBotWeb.HookThumbController do
  use StarlightBotWeb, :controller

  alias StarlightBot.Hooks

  def show(conn, %{"name" => name}) do
    case Hooks.get_hook_image(name) do
      nil ->
        send_resp(conn, 404, "")

      image ->
        conn
        |> put_resp_content_type("image/png", nil)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, image)
    end
  end
end
