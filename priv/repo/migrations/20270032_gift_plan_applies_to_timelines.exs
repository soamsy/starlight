defmodule StarlightBot.Repo.Migrations.GiftPlanAppliesToTimelines do
  use Ecto.Migration

  @heal_actions ~w(heal revive heal_all)
  @kinds %{
    "all_normal" => ["all_normal"],
    "becomes_hard" => ["becomes_hard"],
    "all_hard" => ["all_hard", "extreme"],
    "extreme" => ["extreme"]
  }

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM gift_plans WHERE data LIKE '%\"applies\"%'")

    for [id, json] <- rows, data = Jason.decode!(json), converted = convert_plan(data), converted != data do
      repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
    end
  end

  def down, do: :ok

  def convert_plan(%{"sections" => sections} = plan) when is_list(sections), do: %{plan | "sections" => Enum.map(sections, &convert_section/1)}
  def convert_plan(plan), do: plan

  defp convert_section(%{"applies" => applies, "entries" => [_ | _] = entries, "id" => section_id} = section) when is_map_key(@kinds, applies) do
    kinds = Map.fetch!(@kinds, applies)
    groups = %{false => "grp_#{section_id}_gifts", true => "grp_#{section_id}_actions"}

    converted =
      Enum.map(entries, fn entry ->
        entry |> convert_entry(kinds) |> Map.put("group", groups[heal?(entry)])
      end)

    %{section | "applies" => "always", "entries" => converted}
  end

  defp convert_section(section), do: section

  defp convert_entry(%{"floors" => floors, "timelines" => [_ | _]} = entry, _kinds) when is_list(floors), do: entry

  defp convert_entry(%{"floors" => floors} = entry, kinds) when is_list(floors) do
    entry
    |> Map.put("floors", Enum.map(floors, &Map.put(&1, "abandoned", true)))
    |> Map.put("timelines", [%{"id" => "tl_" <> Enum.join(kinds, "_"), "kinds" => kinds, "floors" => floors}])
    |> Map.put("scheduled", true)
  end

  defp heal?(%{"subject" => %{"action" => action}}), do: action in @heal_actions
  defp heal?(_entry), do: false
end
