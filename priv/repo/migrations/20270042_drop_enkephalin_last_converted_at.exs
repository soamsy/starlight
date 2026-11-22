defmodule StarlightBot.Repo.Migrations.DropEnkephalinLastConvertedAt do
  use Ecto.Migration

  def up do
    execute "DELETE FROM app_settings WHERE key = 'enkephalin_last_converted_at'"
  end

  def down, do: :ok
end
