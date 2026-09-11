import Config

if config_env() == :prod do
  config :starlight_bot, movement_profile: :human
end

# Allow overriding the DB path via environment
if db = System.get_env("STARLIGHT_DB") do
  config :starlight_bot, StarlightBot.Repo, database: db
end
