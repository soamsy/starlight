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
          hook_name: t.hook_name
        }
    )
  rescue
    _ -> []
  end
end
