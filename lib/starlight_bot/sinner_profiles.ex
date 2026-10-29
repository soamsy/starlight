defmodule StarlightBot.SinnerProfiles do
  require Logger
  import Ecto.Query
  alias StarlightBot.Repo

  @sinners ~w(yi_sang faust don_quixote ryoshu meursault hong_lu heathcliff ishmael rodion sinclair outis gregor)

  @placeholder_png Base.decode64!(
                     "iVBORw0KGgoAAAANSUhEUgAAAC0AAAAoCAAAAABPvCz1AAABnElEQVQ4EZXBMWgTURzA4d+/HLEJLQg9LlDQoUMlYzLFbl11U3TRSRqHgg7Xrjro2t6g0MF0EXRRdGvXbjVTshno0EGhcOEKQmlSw1GEe++Sy9094b5PKEIoQihCKEIoQsiySos3/1yMQzKEtPr6bWfB8S8Hv4+6pAizaq1VGy04afeZISRZ7r15Ev4eeCEJQoL1rkFK70XIlDBV+m6Tcf7wiglhovJpmRxnT0bEhNjc7l1yddxrNCFW2yuTa7TZRxNi3hoGxy6aoDXe2BgEr3oogrb1CKMvHoqgWDtNjDrbIRFBqeyvYHS6MSQiKNW2g9Gg5RMRlDsf+Y9nP4kISvVDFSP/uU9EUCr7KxidbgyJCIq108Sosx0SETT3MUZfd1EErf7WxiB43UURYt4aBscumhCr7ZXJNdrsowmxOa9Jrh9b12jCRPnzMjnOng6JCVPz35bICB6MmRASrPd1UrovQ6aEJMu9f4OEq0MvJEGYVWut2mjBSbvPDCGtsX7LWXD8y8Gvox4pQpZVWlw6vxiHZAhFCEUIRQhF/AMQQ2QpXZ2PcgAAAABJRU5ErkJggg=="
                   )

  def sinners, do: @sinners

  def icon(sinner) when sinner in @sinners, do: "/images/sinners/#{sinner}.webp"

  def placeholder_png, do: @placeholder_png

  def label(sinner) when is_binary(sinner), do: sinner |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  def list do
    from(p in "sinner_profiles",
      select: %{
        id: p.id,
        name: p.name,
        sinner: p.sinner,
        locator_hook: p.locator_hook,
        name_en: p.name_en,
        released_on: p.released_on
      }
    )
    |> Repo.all()
    |> Enum.sort_by(& &1.name)
    |> Enum.sort_by(& &1.released_on, :desc)
    |> Enum.sort_by(&sinner_rank(&1.sinner))
  rescue
    _ -> []
  end

  def save(%{name: name} = attrs) when is_binary(name) and name != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    fields = [name: name, sinner: attrs[:sinner], locator_hook: attrs[:locator_hook]]

    case attrs[:id] do
      id when is_integer(id) ->
        {n, _} = Repo.update_all(from(p in "sinner_profiles", where: p.id == ^id), set: fields ++ [updated_at: now])
        if n > 0, do: {:ok, id}, else: {:error, :not_found}

      _ ->
        released_on = attrs[:released_on] || Date.to_iso8601(Date.utc_today())
        row = Map.new(fields ++ [released_on: released_on, inserted_at: now, updated_at: now])

        case Repo.insert_all("sinner_profiles", [row], returning: [:id]) do
          {1, [%{id: id}]} -> {:ok, id}
          _ -> {:error, :insert_failed}
        end
    end
  rescue
    e ->
      Logger.error("SinnerProfiles DB error: #{Exception.message(e)}", module: __MODULE__)
      {:error, Exception.message(e)}
  end

  def save(_attrs), do: {:error, :name_required}

  defp sinner_rank(sinner), do: Enum.find_index(@sinners, &(&1 == sinner)) || length(@sinners)

  def delete(id) when is_integer(id) do
    {n, _} = Repo.delete_all(from p in "sinner_profiles", where: p.id == ^id)
    if n > 0, do: {:ok, id}, else: {:error, :not_found}
  end
end
