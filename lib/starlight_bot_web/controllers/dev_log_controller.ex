defmodule StarlightBotWeb.DevLogController do
  use StarlightBotWeb, :controller
  require Logger

  def log(conn, %{"level" => level, "message" => message}) do
    msg = "[JS #{level}] #{message}"

    if level == "error" do
      Logger.error(msg)
    else
      Logger.warning(msg)
    end

    send_resp(conn, 204, "")
  end
end
