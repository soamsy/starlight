defmodule StarlightBot.RunsRepo do
  use Ecto.Repo,
    otp_app: :starlight_bot,
    adapter: Ecto.Adapters.SQLite3

  def init(_type, config), do: {:ok, StarlightBot.Data.repo_config(:runs, config)}
end
