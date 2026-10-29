import Config

config :starlight_bot, StarlightBot.Repo, pool_size: 5, busy_timeout: 5000
config :starlight_bot, StarlightBot.BaseRepo, pool_size: 5, busy_timeout: 5000
config :starlight_bot, StarlightBot.RunsRepo, pool_size: 5, busy_timeout: 5000

config :starlight_bot,
  ecto_repos: [StarlightBot.Repo, StarlightBot.BaseRepo, StarlightBot.RunsRepo],
  game_window_title: "LimbusCompany",
  game_window_class: "LimbusCompany",
  ego_gift_ml_dir: Path.expand("~/pkg/EgoGiftML")

config :logger, level: :debug

config :starlight_bot, StarlightBotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: StarlightBotWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: StarlightBot.PubSub,
  live_view: [signing_salt: "starlightlvsalt"]

config :phoenix, :json_library, Jason

config :tailwind,
  version: "4.3.0",
  starlight_bot: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.21.5",
  starlight_bot: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
