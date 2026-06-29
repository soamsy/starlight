defmodule StarlightBot.Repo do
  use Ecto.Repo,
    otp_app: :starlight_bot,
    adapter: Ecto.Adapters.SQLite3
end
