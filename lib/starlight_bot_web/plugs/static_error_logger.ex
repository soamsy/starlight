defmodule StarlightBotWeb.StaticErrorLogger do
  @moduledoc false

  require Logger
  @behaviour Plug

  @static_exts ~w(.js .css .map .png .jpg .svg .ico .woff .woff2)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn conn ->
      if conn.status == 404 and static_path?(conn.request_path) do
        Logger.warning("[404] Static asset not found: #{conn.request_path}")
      end

      conn
    end)
  end

  defp static_path?(path) do
    ext = Path.extname(path)
    ext in @static_exts
  end
end
