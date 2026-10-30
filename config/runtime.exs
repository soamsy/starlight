import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT") || "4000")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :starlight_bot, StarlightBotWeb.Endpoint,
    server: true,
    url: [host: "127.0.0.1", port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: ["//127.0.0.1"],
    secret_key_base: secret_key_base
end
