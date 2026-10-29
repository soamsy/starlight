defmodule StarlightBot.Repo.Migrations.SlotRanges do
  use Ecto.Migration

  @selector_keys ~w(who sinners slots chosen)

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{} = data} <- Jason.decode(json || "") do
        upgraded = walk(data)

        if upgraded != data do
          repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
        end
      end
    end)
  end

  def down, do: :ok

  defp walk(%{"type" => type, "skill" => %{}} = holder) when type in ~w(dodge ego target), do: holder(holder)
  defp walk(%{} = map), do: Map.new(map, fn {key, value} -> {key, walk(value)} end)
  defp walk(list) when is_list(list), do: Enum.map(list, &walk/1)
  defp walk(value), do: value

  defp holder(holder) do
    {cap, holder} = Map.pop(holder, "cap")
    {rest, holder} = Map.pop(holder, "rest")
    holder = Map.update!(holder, "skill", &skill(&1, cap)) |> selector()
    if is_map(rest), do: Map.put(holder, "rest", rest(rest, Map.take(holder, @selector_keys))), else: holder
  end

  defp rest(rest, selector) do
    rest |> Map.put_new("skill", %{"pick" => "all"}) |> Map.merge(selector, fn _key, own, _inherited -> own end) |> holder()
  end

  defp selector(%{"skill" => %{"pick" => "first_with", "match" => match, "n" => n}} = holder) do
    holder
    |> Map.put("who", "chosen")
    |> Map.put("chosen", %{"join" => "and", "conditions" => [%{"kind" => "has", "values" => [match]}]})
    |> Map.put("skill", %{"pick" => "first", "start" => 1, "end" => n})
  end

  defp selector(holder), do: holder

  defp skill(%{"pick" => "all"}, cap) when is_integer(cap), do: %{"pick" => "first", "start" => 1, "end" => cap}
  defp skill(%{"pick" => pick, "n" => n}, _cap) when pick in ~w(exact up_to), do: %{"pick" => "first", "start" => n, "end" => n}
  defp skill(%{"pick" => "none"}, _cap), do: %{"pick" => "first", "start" => 1, "end" => 1}
  defp skill(skill, _cap), do: skill
end
