defmodule Mix.Tasks.SinnerProfiles.HdHooks do
  @shortdoc "Create placeholder HD locator hooks for shipped sinner profiles that lack them"
  @moduledoc """
  Add-only: for every shipped profile with an uptie or base locator hook, creates the matching
  `<hook>_hd` placeholder hook (when missing) and points the profile's `hd_locator_hook` /
  `hd_base_locator_hook` at it. Profiles that already have the field set are left alone.

      mix sinner_profiles.hd_hooks
  """

  use Mix.Task
  import Ecto.Query

  alias StarlightBot.BaseRepo, as: Repo
  alias StarlightBot.SinnerProfiles

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    StarlightBot.Data.require_authoring!()

    rows =
      Repo.all(
        from p in "sinner_profiles",
          select: %{
            id: p.id,
            locator_hook: p.locator_hook,
            base_locator_hook: p.base_locator_hook,
            hd_locator_hook: p.hd_locator_hook,
            hd_base_locator_hook: p.hd_base_locator_hook
          }
      )

    {profiles, hooks} =
      Enum.reduce(rows, {0, 0}, fn row, {profiles, hooks} ->
        {set, created} = backfill(row)
        {profiles + if(set == [], do: 0, else: 1), hooks + created}
      end)

    Mix.shell().info("#{profiles} profile(s) updated, #{hooks} HD hook(s) created")
  end

  defp backfill(row) do
    pairs = [
      {:hd_locator_hook, row.hd_locator_hook, row.locator_hook},
      {:hd_base_locator_hook, row.hd_base_locator_hook, row.base_locator_hook}
    ]

    {set, created} =
      Enum.reduce(pairs, {[], 0}, fn
        {field, nil, source}, {set, created} when is_binary(source) and source != "" ->
          {name, new?} = SinnerProfiles.ensure_hd_hook(source)
          {[{field, name} | set], created + if(new?, do: 1, else: 0)}

        _, acc ->
          acc
      end)

    if set != [], do: Repo.update_all(from(p in "sinner_profiles", where: p.id == ^row.id), set: set)
    {set, created}
  end
end
