defmodule StarlightBot.GiftPlans.RouteDefaults do
  require Logger
  alias StarlightBot.GiftPlans.Routes
  alias StarlightBot.{BaseRepo, Repo}

  def get(tier) when is_integer(tier) do
    case stored(Repo, "fusion_route_defaults", tier) || stored(BaseRepo, "fusion_route_templates", tier) do
      nil -> Routes.defaults(tier)
      routes -> Routes.copy(routes)
    end
  end

  def all do
    Map.merge(rows(BaseRepo, "fusion_route_templates"), rows(Repo, "fusion_route_defaults"))
  end

  defp rows(repo, table) do
    case repo.query("SELECT tier, routes FROM #{table} ORDER BY tier") do
      {:ok, %{rows: rows}} -> for [tier, json] <- rows, {:ok, routes} <- [Jason.decode(json)], into: %{}, do: {tier, routes}
      {:error, _} -> %{}
    end
  end

  def put(tier, routes) when is_integer(tier) and is_list(routes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Repo.query(
           "INSERT INTO fusion_route_defaults (tier, routes, updated_at) VALUES (?, ?, ?) " <>
             "ON CONFLICT(tier) DO UPDATE SET routes = excluded.routes, updated_at = excluded.updated_at",
           [tier, Jason.encode!(routes), now]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.error("route defaults: couldn't save tier #{tier}: #{inspect(reason)}", module: __MODULE__)
        err
    end
  end

  defp stored(repo, table, tier) do
    case repo.query("SELECT routes FROM #{table} WHERE tier = ?", [tier]) do
      {:ok, %{rows: [[json]]}} ->
        case Jason.decode(json) do
          {:ok, routes} when is_list(routes) -> routes
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
