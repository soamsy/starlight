import Config

# Allows tests to skip touching KDE and a real mouse+keyboard
config :starlight_bot, start_hardware?: false

config :starlight_bot, StarlightBot.Repo,
  database: Path.expand("/tmp/starlight_test.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :starlight_bot, StarlightBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testSecretKeyThatIsAtLeast64BytesLongForTestingPurposesOnlyXXXXXXX",
  server: false

config :logger, level: :warning
