defmodule StarlightBot.EgoGifts do
  import Ecto.Query
  alias StarlightBot.Repo

  def affinity_for(gift_id) when is_binary(gift_id) do
    Repo.one(from g in "ego_gifts", where: g.id == ^gift_id, select: g.affinity)
  rescue
    _ -> nil
  end
end
