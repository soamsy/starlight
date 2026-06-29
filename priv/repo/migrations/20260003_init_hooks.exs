defmodule StarlightBot.Repo.Migrations.InitHooks do
  use Ecto.Migration

  def change do
    create table(:hooks, primary_key: false) do
      add :name,         :string,  primary_key: true
      add :image,        :binary
      add :region_x,     :integer
      add :region_y,     :integer
      add :region_w,     :integer
      add :region_h,     :integer
      add :click_x,      :integer
      add :click_y,      :integer
      add :click_w,      :integer
      add :click_h,      :integer
      add :match_method, :string,  null: false, default: "gray"
      add :confidence,   :float,   null: false, default: 0.85
      add :notes,        :string
      timestamps()
    end
  end
end
