defmodule StarlightBot.Repo.Migrations.SinnerProfileReleasedOn do
  use Ecto.Migration

  def change do
    alter table(:sinner_profiles) do
      add :released_on, :date
    end
  end
end
