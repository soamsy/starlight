defmodule StarlightBot.ThemePacks do
  import Ecto.Query
  alias StarlightBot.BaseRepo, as: Repo
  alias StarlightBot.Data

  @unplannable_ids ["thm_117"]
  @hidden_ids ["thm_116"]

  def plannable?(pack), do: pack.id not in @unplannable_ids and pack.id not in @hidden_ids

  def list_plannable_theme_packs do
    Enum.filter(list_theme_packs(), &plannable?/1)
  end

  def list_pickable_theme_packs do
    Enum.reject(list_theme_packs(), &(&1.id in @unplannable_ids))
  end

  def list_theme_packs do
    Repo.all(
      from t in "theme_packs",
        order_by: [asc: t.name_en],
        select: %{
          id: t.id,
          name_en: t.name_en,
          name_ru: t.name_ru,
          description_en: t.description_en,
          node_count: t.node_count,
          normal_floors: t.normal_floors,
          hard_floors: t.hard_floors,
          tip: t.tip,
          event_ids: t.event_ids,
          image_path: t.image_path,
          hook_name: t.hook_name,
          search_hook_name: t.search_hook_name,
          possible_bosses: t.possible_bosses
        }
    )
    |> Enum.map(&Map.update!(&1, :possible_bosses, fn json -> decode_bosses(json) end))
  rescue
    _ -> []
  end

  def names_by_gift_id do
    from(g in "theme_pack_gifts",
      join: t in "theme_packs",
      on: t.id == g.theme_pack_id,
      order_by: [asc: t.name_en],
      select: {g.gift_id, t.name_en}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  rescue
    _ -> %{}
  end

  def gifts_by_pack_id do
    from(l in "theme_pack_gifts",
      join: g in "ego_gifts",
      on: g.id == l.gift_id,
      order_by: [asc: g.tier, asc: g.name],
      select: {l.theme_pack_id, %{id: g.id, name: g.name, tier: g.tier, image_path: g.image_path}}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  rescue
    _ -> %{}
  end

  def set_search_hook(id, hook_name) do
    if Data.base_writable?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.update_all(from(t in "theme_packs", where: t.id == ^id), set: [search_hook_name: hook_name, updated_at: now])
    else
      {:error, :read_only}
    end
  end

  @base_nodes 4

  def floating_nodes(%{node_count: count}) when is_integer(count), do: max(count - @base_nodes, 0)
  def floating_nodes(_pack), do: 0

  def parse_node_count(nil), do: nil

  def parse_node_count(description) do
    case Regex.run(~r/Len(?:gth|ght):\s*(\d+)\s*nodes/i, description) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  def parse_bosses(nil), do: []

  def parse_bosses(raw) do
    for [_, id, ru, en] <- Regex.scan(~r/([^,\[\]]+)\[([^\]|]*)\|([^\]]*)\]/, raw) do
      %{"id" => String.trim(id), "name_ru" => String.trim(ru), "name_en" => String.trim(en)}
    end
  end

  def decode_bosses(nil), do: []

  def decode_bosses(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def fix_description(nil), do: nil
  def fix_description(description), do: String.replace(description, "Lenght", "Length")

  @doc "Decode a normal_floors/hard_floors JSON string column into a list of floor integers."
  def decode_floors(nil), do: []

  def decode_floors(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
