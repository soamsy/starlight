defmodule StarlightBot.Plans do
  require Logger
  import Ecto.Query
  alias StarlightBot.Repo

  @tables ~w(gift_plans battle_plans pack_plans)a

  @doc "List all rows in `table`, `data` JSON-decoded, ordered by name."
  def list(table) when table in @tables do
    Repo.all(from r in Atom.to_string(table), order_by: [asc: r.name], select: %{id: r.id, name: r.name, data: r.data})
    |> Enum.map(&decode/1)
  rescue
    _ -> []
  end

  @doc "Get a single row by id. Returns nil if not found."
  def get(table, id) when table in @tables and is_integer(id) do
    Repo.one(from r in Atom.to_string(table), where: r.id == ^id, select: %{id: r.id, name: r.name, data: r.data})
    |> decode()
  rescue
    _ -> nil
  end

  @doc """
  Insert or update a row. `attrs` must include `:name` (string) and `:data`
  (map, JSON-encoded before writing). If `attrs[:id]` is present and exists,
  updates in place; otherwise inserts a new row. Returns `{:ok, id}` or
  `{:error, reason}`.
  """
  def save(table, %{name: name, data: data} = attrs) when table in @tables and is_binary(name) and name != "" do
    table_str = Atom.to_string(table)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    json = Jason.encode!(data)

    case attrs[:id] do
      id when is_integer(id) ->
        {n, _} =
          Repo.update_all(from(r in table_str, where: r.id == ^id), set: [name: name, data: json, updated_at: now])

        if n > 0, do: {:ok, id}, else: {:error, :not_found}

      _ ->
        row = %{name: name, data: json, inserted_at: now, updated_at: now}

        case Repo.insert_all(table_str, [row], returning: [:id]) do
          {1, [%{id: id}]} -> {:ok, id}
          _ -> {:error, :insert_failed}
        end
    end
  rescue
    e ->
      Logger.error("Plans DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def save(_table, _attrs), do: {:error, :name_and_data_required}

  @doc "Delete a row by id."
  def delete(table, id) when table in @tables and is_integer(id) do
    {n, _} = Repo.delete_all(from r in Atom.to_string(table), where: r.id == ^id)
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  rescue
    e ->
      Logger.error("Plans DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  defp decode(nil), do: nil

  defp decode(%{data: nil} = row), do: %{row | data: nil}

  defp decode(%{data: json} = row) do
    case Jason.decode(json) do
      {:ok, data} -> %{row | data: data}
      {:error, _} -> %{row | data: nil}
    end
  end
end
