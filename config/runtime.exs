import Config

# Allow overriding the DB path via environment
if db = System.get_env("STARLIGHT_DB") do
  config :starlight_bot, StarlightBot.Repo, database: db
end
