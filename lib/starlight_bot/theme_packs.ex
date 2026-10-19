defmodule StarlightBot.ThemePacks do
  import Ecto.Query
  alias StarlightBot.Repo

  def list_theme_packs do
    Repo.all(
      from t in "theme_packs",
        order_by: [asc: t.name_en],
        select: %{
          id: t.id,
          name_en: t.name_en,
          name_ru: t.name_ru,
          description_en: t.description_en,
          normal_floors: t.normal_floors,
          hard_floors: t.hard_floors,
          tip: t.tip,
          event_ids: t.event_ids,
          image_path: t.image_path,
          hook_name: t.hook_name,
          search_hook_name: t.search_hook_name
        }
    )
  rescue
    _ -> []
  end

  def set_search_hook(id, hook_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(t in "theme_packs", where: t.id == ^id), set: [search_hook_name: hook_name, updated_at: now])
  end

  @doc "Decode a normal_floors/hard_floors JSON string column into a list of floor integers."
  def decode_floors(nil), do: []

  def decode_floors(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
