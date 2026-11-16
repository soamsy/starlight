defmodule StarlightBot.GiftStarterPacks do
  require Logger
  alias StarlightBot.{BaseRepo, Data, GiftPlans, Repo}

  @affinities ~w(any bleed blunt burn charge pierce poise rupture sinking slash tremor)

  def affinities, do: @affinities

  def list do
    rows(BaseRepo, :base) ++ rows(Repo, :user)
  end

  def get(ref) when is_binary(ref) do
    with {source, id} <- parse_ref(ref),
         {repo, _table} <- repo_for(source),
         {:ok, %{rows: [[name, affinity, json]]}} <- repo.query("SELECT name, affinity, data FROM gift_starter_packs WHERE id = ?", [id]),
         {:ok, data} <- Jason.decode(json) do
      pack(source, id, name, affinity, data)
    else
      _ -> nil
    end
  end

  def get(_ref), do: nil

  def default_name do
    taken = MapSet.new(list(), & &1.name)
    Enum.find(["New starter pack" | Enum.map(2..999, &"New starter pack #{&1}")], &(not MapSet.member?(taken, &1)))
  end

  def blank_data do
    section = GiftPlans.new_section()
    %{"version" => GiftPlans.version(), "sections" => [section]}
  end

  def create(name, affinity \\ "any") do
    name = clean_name(name)
    {source, repo} = target()

    cond do
      name == "" -> {:error, :blank_name}
      affinity not in @affinities -> {:error, :bad_affinity}
      name_taken?(name, nil) -> {:error, :name_taken}
      true -> insert(repo, source, name, affinity, blank_data())
    end
  end

  def save(ref, attrs) when is_binary(ref) and is_map(attrs) do
    with %{editable: true, source: source, id: id} = current <- get(ref),
         name = clean_name(Map.get(attrs, :name, current.name)),
         affinity = Map.get(attrs, :affinity, current.affinity),
         data = Map.get(attrs, :data, current.data),
         :ok <- validate(name, affinity, ref) do
      {repo, _table} = repo_for(source)

      case repo.query("UPDATE gift_starter_packs SET name = ?, affinity = ?, data = ?, updated_at = ? WHERE id = ?", [name, affinity, Jason.encode!(data), now(), id]) do
        {:ok, %{num_rows: 1}} -> {:ok, ref}
        {:error, reason} = err ->
          Logger.error("gift starter packs: couldn't save #{ref}: #{inspect(reason)}", module: __MODULE__)
          err
      end
    else
      %{editable: false} -> {:error, :read_only}
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  def delete(ref) when is_binary(ref) do
    with %{editable: true, source: source, id: id} <- get(ref),
         {repo, _table} = repo_for(source),
         {:ok, %{num_rows: 1}} <- repo.query("DELETE FROM gift_starter_packs WHERE id = ?", [id]) do
      :ok
    else
      _ -> {:error, :not_deletable}
    end
  end

  def grouped(packs, plan_affinity) do
    packs
    |> Enum.group_by(& &1.affinity)
    |> Enum.sort_by(fn {affinity, _packs} -> {affinity_rank(affinity, plan_affinity), affinity} end)
  end

  defp affinity_rank("any", _plan_affinity), do: 1
  defp affinity_rank(affinity, affinity), do: 0
  defp affinity_rank(_affinity, _plan_affinity), do: 2

  defp validate(name, affinity, ref) do
    cond do
      name == "" -> {:error, :blank_name}
      affinity not in @affinities -> {:error, :bad_affinity}
      name_taken?(name, ref) -> {:error, :name_taken}
      true -> :ok
    end
  end

  defp name_taken?(name, except_ref), do: Enum.any?(list(), &(&1.name == name and &1.ref != except_ref))

  defp clean_name(name), do: name |> to_string() |> String.trim()

  defp insert(repo, source, name, affinity, data) do
    stamp = now()

    case repo.query("INSERT INTO gift_starter_packs (name, affinity, data, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?) RETURNING id", [name, affinity, Jason.encode!(data), stamp, stamp]) do
      {:ok, %{rows: [[id]]}} ->
        {:ok, ref(source, id)}

      {:error, reason} = err ->
        Logger.error("gift starter packs: couldn't create #{name}: #{inspect(reason)}", module: __MODULE__)
        err
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp target do
    if Data.base_writable?(), do: {:base, BaseRepo}, else: {:user, Repo}
  end

  defp repo_for(:base), do: {BaseRepo, "gift_starter_packs"}
  defp repo_for(:user), do: {Repo, "gift_starter_packs"}

  defp rows(repo, source) do
    case repo.query("SELECT id, name, affinity, data FROM gift_starter_packs ORDER BY name COLLATE NOCASE", []) do
      {:ok, %{rows: rows}} ->
        for [id, name, affinity, json] <- rows, {:ok, data} <- [Jason.decode(json)], do: pack(source, id, name, affinity, data)

      {:error, _} ->
        []
    end
  end

  defp pack(source, id, name, affinity, data) do
    %{
      ref: ref(source, id),
      id: id,
      source: source,
      name: name,
      affinity: affinity,
      editable: source == :user or Data.base_writable?(),
      data: GiftPlans.normalize(data)
    }
  end

  def section(%{data: %{"sections" => [section | _]}}), do: section
  def section(_pack), do: nil

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
