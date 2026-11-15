defmodule StarlightBot.BaseRepo.Migrations.GiftPlanSections do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM plan_templates WHERE kind = 'gift_plans' AND data LIKE '%"milestones"%'|)

    for [id, json] <- rows, data = Jason.decode!(json), converted = convert_plan(data), converted != data do
      repo().query!("UPDATE plan_templates SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
    end
  end

  def down, do: :ok

  defp convert_plan(%{"milestones" => sections} = plan) do
    plan
    |> Map.delete("milestones")
    |> Map.drop(["workflows", "floor_schedule"])
    |> Map.put("version", 6)
    |> Map.put("sections", Enum.map(sections, &convert_section/1))
  end

  defp convert_plan(plan), do: plan

  defp convert_section(%{"stage_of" => root} = section) when is_binary(root), do: convert(section)
  defp convert_section(section), do: section |> Map.delete("name") |> convert()

  defp convert(%{"op" => "milestone"} = leaf), do: leaf |> Map.put("op", "stage") |> rename_key("milestone", "stage") |> convert_children()
  defp convert(%{"op" => "goal"} = leaf), do: leaf |> rename_key("milestone", "stage") |> convert_children()
  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_children(map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, rest} -> rest
      {value, rest} -> Map.put(rest, to, value)
    end
  end
end
