defmodule StarlightBot.Repo.Migrations.SinnerKeyedSelectors do
  use Ecto.Migration

  def up do
    %{rows: profile_rows} = repo().query!("SELECT id, sinner FROM sinner_profiles")
    sinner_of = Map.new(profile_rows, fn [id, sinner] -> {id, sinner} end)
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{} = data} <- Jason.decode(json || "") do
        {upgraded, used_ids} = rekey(data, sinner_of, [])

        profiles =
          used_ids
          |> Enum.reverse()
          |> Enum.reduce(Map.get(data, "profiles", %{}), fn profile_id, acc ->
            case sinner_of[profile_id] do
              nil -> acc
              sinner -> Map.put_new(acc, sinner, profile_id)
            end
          end)

        upgraded = Map.put(upgraded, "profiles", profiles)

        if upgraded != data do
          repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
        end
      end
    end)
  end

  def down, do: :ok

  defp rekey(%{} = map, sinner_of, used) do
    Enum.reduce(map, {%{}, used}, fn
      {"profile_ids", ids}, {acc, used} when is_list(ids) ->
        ids = Enum.filter(ids, &is_integer/1)
        sinners = ids |> Enum.map(&sinner_of[&1]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        {Map.put(acc, "sinners", sinners), Enum.reverse(ids) ++ used}

      {"profile_id", profile_id}, {acc, used} ->
        {Map.put(acc, "sinner", sinner_of[profile_id]), if(is_integer(profile_id), do: [profile_id | used], else: used)}

      {key, value}, {acc, used} ->
        {value, used} = rekey(value, sinner_of, used)
        {Map.put(acc, key, value), used}
    end)
  end

  defp rekey(list, sinner_of, used) when is_list(list) do
    {items, used} = Enum.map_reduce(list, used, &rekey(&1, sinner_of, &2))
    {items, used}
  end

  defp rekey(value, _sinner_of, used), do: {value, used}
end
