defmodule StarlightBot.EgoGifts do
  import Ecto.Query
  alias StarlightBot.Repo

  def buying_cost_for(gift_id) when is_binary(gift_id) do
    Repo.one(from g in "ego_gifts", where: g.id == ^gift_id, select: g.buying_cost)
  rescue
    _ -> nil
  end

  @doc "List all E.G.O gifts, for pickers. Sorted by name."
  def list_gifts do
    Repo.all(
      from g in "ego_gifts",
        order_by: [asc: g.name],
        select: %{
          id: g.id,
          name: g.name,
          sin: g.sin,
          affinity: g.affinity,
          tier: g.tier,
          buying_cost: g.buying_cost,
          selling_cost: g.selling_cost,
          obtain_method: g.obtain_method,
          description: g.description,
          uptie2: g.uptie2,
          uptie3: g.uptie3,
          ingredients: g.ingredients,
          sort_id: g.sort_id,
          image_path: g.image_path
        }
    )
  rescue
    _ -> []
  end
end
