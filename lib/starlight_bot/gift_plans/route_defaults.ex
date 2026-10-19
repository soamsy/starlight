defmodule StarlightBot.GiftPlans.RouteDefaults do
  require Logger
  alias StarlightBot.GiftPlans.Routes
  alias StarlightBot.Repo

  def get(tier) when is_integer(tier) do
    case stored(tier) do
      nil -> Routes.defaults(tier)
      routes -> Routes.copy(routes)
    end
  end

  def all do
    case Repo.query("SELECT tier, routes FROM fusion_route_defaults ORDER BY tier") do
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

  defp stored(tier) do
    case Repo.query("SELECT routes FROM fusion_route_defaults WHERE tier = ?", [tier]) do
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
