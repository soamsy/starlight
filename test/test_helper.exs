ExUnit.start()

ExUnit.configure(exclude: [:kde])

Ecto.Migrator.run(
  StarlightBot.Repo,
  Path.join([:code.priv_dir(:starlight_bot), "repo", "migrations"]),
  :up,
  all: true,
  log_migrations_sql: false
)

Ecto.Adapters.SQL.Sandbox.mode(StarlightBot.Repo, :manual)
