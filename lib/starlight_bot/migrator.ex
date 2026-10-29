defmodule StarlightBot.Migrator do
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    if Application.get_env(:starlight_bot, :auto_migrate, true), do: run()
    :ignore
  end

  def run do
    repos =
      if StarlightBot.Data.base_writable?(),
        do: [StarlightBot.BaseRepo, StarlightBot.Repo, StarlightBot.RunsRepo],
        else: [StarlightBot.Repo, StarlightBot.RunsRepo]

    for repo <- repos do
      Ecto.Migrator.run(repo, :up, all: true, log: false)
    end

    :ok
  end
end
