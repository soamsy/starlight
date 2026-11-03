ExUnit.start()

ExUnit.configure(exclude: [:kde])

defmodule StarlightBot.TestDB do
  @repos [StarlightBot.BaseRepo, StarlightBot.Repo, StarlightBot.RunsRepo]

  def repos, do: @repos

  def checkout do
    Enum.each(@repos, fn repo -> :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo) end)
  end
end

for repo <- StarlightBot.TestDB.repos() do
  Ecto.Migrator.run(repo, :up, all: true, log_migrations_sql: false, log: false)
  Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
end
