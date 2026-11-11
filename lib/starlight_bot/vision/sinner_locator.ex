defmodule StarlightBot.Vision.SinnerLocator do
  alias StarlightBot.SinnerProfiles
  alias StarlightBot.Vision.{HookRegistry, Matcher, SkillTray}

  @type found :: %{profile: map, hook: atom, score: float, column: non_neg_integer, columns: [non_neg_integer]}

  @spec locate(term, SkillTray.t(), [map]) :: [found]
  def locate(frame, %SkillTray{} = tray, profiles) do
    loaded = Map.new(HookRegistry.all_names(), &{Atom.to_string(&1), &1})
    by_hook = for profile <- profiles, name <- SinnerProfiles.locator_hooks(profile), hook = loaded[name], into: %{}, do: {hook, profile}

    claims =
      for {hook, {:ok, matches}} <- Matcher.find_all_with_scores_batch(frame, Map.keys(by_hook)),
          {{x, _y, w, _h}, score} <- matches do
        column = SkillTray.column_at(tray, x + w / 2)
        %{profile: Map.fetch!(by_hook, hook), hook: hook, score: score, column: column, columns: SkillTray.owned_columns(tray, column)}
      end

    claims
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce({[], MapSet.new()}, fn claim, {kept, taken} ->
      if Enum.any?(claim.columns, &MapSet.member?(taken, &1)),
        do: {kept, taken},
        else: {[claim | kept], Enum.reduce(claim.columns, taken, &MapSet.put(&2, &1))}
    end)
    |> elem(0)
    |> Enum.sort_by(& &1.column)
  end
end
