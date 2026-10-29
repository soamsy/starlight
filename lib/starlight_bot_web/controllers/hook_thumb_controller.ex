defmodule StarlightBotWeb.HookThumbController do
  use StarlightBotWeb, :controller

  alias StarlightBot.Hooks

  @sources %{"base" => :base, "override" => :override, "user" => :user}

  def show(conn, %{"name" => name} = params) do
    image =
      case Map.fetch(@sources, params["s"]) do
        {:ok, source} -> Hooks.get_hook_image(name, source)
        :error -> Hooks.get_hook_image(name)
      end

    case image do
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
