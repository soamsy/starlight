import Config

# Allows tests to skip touching KDE and a real mouse+keyboard
config :starlight_bot, start_hardware?: false

config :starlight_bot, :bot_log_dir, nil

config :starlight_bot, :hook_image_dir, "/tmp/starlight_test_hooks"

config :starlight_bot, :auto_migrate, false

config :starlight_bot, :data_paths, %{
  mode: :authoring,
  mode_source: :test,
  root: "/tmp/starlight_test",
  base: "/tmp/starlight_test_base.db",
  seed: "/tmp/starlight_test_seed.db",
  user: "/tmp/starlight_test_user.db",
  runs: "/tmp/starlight_test_runs.db",
  user_hooks_dir: "/tmp/starlight_test_user_hooks",
  base_hooks_dir: "/tmp/starlight_test_hooks"
}

for repo <- [StarlightBot.Repo, StarlightBot.BaseRepo, StarlightBot.RunsRepo] do
  config :starlight_bot, repo, pool: Ecto.Adapters.SQL.Sandbox, pool_size: 5
end

config :starlight_bot, StarlightBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testSecretKeyThatIsAtLeast64BytesLongForTestingPurposesOnlyXXXXXXX",
  server: false

config :logger, level: :warning
