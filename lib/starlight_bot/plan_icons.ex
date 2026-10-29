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
    hunted = for {id, modes} <- packs, is_map(modes), Enum.any?(modes, &match?({_mode, %{"priority" => "hunt"}}, &1)), do: id
    order = List.wrap(get_in(data, ["hunt_order", "normal"])) ++ List.wrap(get_in(data, ["hunt_order", "hard"]))
    Enum.filter(Enum.uniq(order), &(&1 in hunted)) ++ Enum.sort(hunted -- order)
  end

  defp hunted_ids(_data), do: []
end
