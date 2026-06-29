import Config

if config_env() == :prod do
  config :starlight_bot, movement_profile: :human
end

# Allow overriding DB paths via environment
if db = System.get_env("STARLIGHT_USER_DB") do
  config :starlight_bot, StarlightBot.Repo, database: db
end

if db = System.get_env("STARLIGHT_MASTER_DB") do
  config :starlight_bot, StarlightBot.MasterRepo, database: db
end
