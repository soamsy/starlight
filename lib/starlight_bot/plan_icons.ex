defmodule StarlightBot.PlanIcons do
  alias StarlightBot.{BattlePlans, EgoGifts, GiftPlans, SinnerProfiles, ThemePacks}

  @limit 3

  def context(:gift_plans), do: Map.new(EgoGifts.list_gifts(), &{&1.name, &1.image_path})
  def context(:pack_plans), do: Map.new(ThemePacks.list_theme_packs(), &{&1.id, &1.image_path})
  def context(:battle_plans), do: nil

  def icons(:battle_plans, data, _context) do
    first = data |> BattlePlans.lineups() |> List.first() || %{}

    (first["sinners"] || [])
    |> Enum.filter(&(&1 in SinnerProfiles.sinners()))
    |> Enum.take(@limit)
    |> Enum.map(&SinnerProfiles.icon/1)
  end

  def icons(:gift_plans, data, images) do
    (data["milestones"] || [])
    |> Enum.flat_map(&(&1["entries"] || []))
    |> Enum.map(&GiftPlans.subject_gift/1)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(images[&1]))
    |> Enum.take(@limit)
  end

  def icons(:pack_plans, data, images) do
    data |> hunted_ids() |> Enum.flat_map(&List.wrap(images[&1])) |> Enum.take(@limit)
  end

  defp hunted_ids(%{"packs" => packs} = data) when is_map(packs) do
    hunted = for {id, modes} <- packs, is_map(modes), Enum.any?(modes, fn {_mode, floors} -> is_map(floors) and Enum.any?(floors, fn {_floor, status} -> status in ~w(hunt favorite) end) end), do: id
    Enum.filter(Enum.uniq(ordered_ids(data)), &(&1 in hunted)) ++ Enum.sort(hunted -- ordered_ids(data))
  end

  defp hunted_ids(_data), do: []

  defp ordered_ids(data) do
    for mode <- ~w(normal hard),
        {_floor, ids} <- Enum.sort_by(Map.get(data["order"] || %{}, mode, %{}), fn {floor, _ids} -> String.to_integer(floor) end),
        id <- List.wrap(ids),
        do: id
  end
end
