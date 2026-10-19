defmodule StarlightBot.Repo.Migrations.FusionRouteDefaults do
  use Ecto.Migration

  def up do
    create table(:fusion_route_defaults, primary_key: false) do
      add :tier, :integer, primary_key: true
      add :routes, :text, null: false
      add :updated_at, :utc_datetime, null: false
    end

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    seeds = %{
      3 => [route([2, 2, 2], 2), route([2, 2, 1], 2), route([3, 2, 1], 2)],
      4 => [
        route([3, 2, 1, 1], 3),
        route([3, 2, 2], 3),
        route([3, 3, 1], 3),
        route([4, 2, 1], nil),
        route([3, 3, 2], 3, %{"3" => [route([2, 2, 2], nil, %{}, %{"2" => 1})]}),
        route([4, 2, 2], 2)
      ]
    }

    Enum.each(seeds, fn {tier, routes} ->
      repo().query!("INSERT INTO fusion_route_defaults (tier, routes, updated_at) VALUES (?, ?, ?)", [tier, Jason.encode!(routes), now])
    end)
  end

  def down do
    drop table(:fusion_route_defaults)
  end

  defp route(combo, buy_up_to, subgoals \\ %{}, leftover \\ %{}) do
    %{"id" => "rt_seed", "combo" => combo, "buy_up_to" => buy_up_to, "leftover" => leftover, "subgoals" => subgoals}
  end
end
