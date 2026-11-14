defmodule StarlightBotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :starlight_bot

  @session_options [
    store: :cookie,
    key: "_starlight_key",
    signing_salt: "WZqFv3nL",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug StarlightBotWeb.StaticErrorLogger

  plug Plug.Static,
    at: "/",
    from: Application.compile_env(:starlight_bot, :static_from, :starlight_bot),
    gzip: false,
    only: StarlightBotWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug StarlightBotWeb.Router
end
