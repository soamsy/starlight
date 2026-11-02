defmodule StarlightBot.GiftPlans.FusionRouteTemplates do
  require Logger
  alias StarlightBot.GiftPlans.Routes
  alias StarlightBot.{BaseRepo, Data, Repo}

  @tiers 1..4

  def tiers, do: Enum.to_list(@tiers)

  def list(tier) when tier in @tiers do
    base = rows(BaseRepo, "fusion_route_templates", :base, tier)
    user = rows(Repo, "fusion_route_user_templates", :user, tier)
    Enum.map(base, &Map.put(&1, :deletable, Data.base_writable?())) ++ Enum.map(user, &Map.put(&1, :deletable, true))
  end

  def list(_tier), do: []

  def all, do: Map.new(@tiers, &{&1, list(&1)})

  def get(ref) when is_binary(ref) do
    with {source, id} <- parse_ref(ref),
         {repo, table} <- repo_for(source),
         {:ok, %{rows: [[tier, name, json]]}} <- repo.query("SELECT tier, name, routes FROM #{table} WHERE id = ?", [id]),
         {:ok, routes} <- Jason.decode(json) do
      %{ref: ref, source: source, tier: tier, name: name, routes: routes}
    else
      _ -> nil
    end
  end

  def initial(tier) do
    case list(tier) do
      [first | _] -> Routes.copy(first.routes)
      [] -> Routes.defaults(tier)
    end
  end

  def create(tier, name, routes) when is_list(routes) do
    name = name |> to_string() |> String.trim()
    {source, repo, table} = target()

    cond do
      tier not in @tiers -> {:error, :tier_not_fusable}
      name == "" -> {:error, :blank_name}
      Enum.any?(list(tier), &(&1.name == name)) -> {:error, :name_taken}
      true -> insert(repo, table, source, tier, name, routes)
    end
  end

  def delete(ref) when is_binary(ref) do
    with {source, id} <- parse_ref(ref),
         true <- source == :user or Data.base_writable?(),
         {repo, table} <- repo_for(source),
         {:ok, %{num_rows: 1}} <- repo.query("DELETE FROM #{table} WHERE id = ?", [id]) do
      :ok
    else
      _ -> {:error, :not_deletable}
    end
  end

  defp insert(repo, table, source, tier, name, routes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case repo.query(
           "INSERT INTO #{table} (tier, name, routes, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?) RETURNING id",
           [tier, name, Jason.encode!(routes), now, now]
         ) do
      {:ok, %{rows: [[id]]}} ->
        {:ok, ref(source, id)}

      {:error, reason} = err ->
        Logger.error("fusion route templates: couldn't save tier #{tier} template: #{inspect(reason)}", module: __MODULE__)
        err
    end
  end

  defp target do
    if Data.base_writable?(),
      do: {:base, BaseRepo, "fusion_route_templates"},
      else: {:user, Repo, "fusion_route_user_templates"}
  end

  defp repo_for(:base), do: {BaseRepo, "fusion_route_templates"}
  defp repo_for(:user), do: {Repo, "fusion_route_user_templates"}

  defp rows(repo, table, source, tier) do
    case repo.query("SELECT id, name, routes FROM #{table} WHERE tier = ? ORDER BY id", [tier]) do
      {:ok, %{rows: rows}} ->
        for [id, name, json] <- rows, {:ok, routes} when is_list(routes) <- [Jason.decode(json)] do
          %{ref: ref(source, id), source: source, tier: tier, name: name, routes: routes}
        end

      {:error, _} ->
        []
    end
  end

  defp ref(:base, id), do: "b:#{id}"
  defp ref(:user, id), do: "u:#{id}"

  defp parse_ref("b:" <> id), do: parse_id(:base, id)
  defp parse_ref("u:" <> id), do: parse_id(:user, id)
  defp parse_ref(_ref), do: nil

  defp parse_id(source, id) do
    case Integer.parse(id) do
      {n, ""} -> {source, n}
      _ -> nil
    end
  end
end
