defmodule StarlightBot.Automation.ChainStreakTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.ChainStreak

  defp streak_score(colors) do
    weight = length(colors) + 1

    colors
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn run -> Integer.pow(weight, length(run)) end)
    |> Enum.sum()
  end

  defp colors_for(top, bottom, choices) do
    [top, bottom, choices]
    |> Enum.zip()
    |> Enum.map(fn {t, b, choice} -> if choice == :top, do: t, else: b end)
  end

  defp brute_force_best_score(top, bottom) do
    top
    |> Enum.zip(bottom)
    |> Enum.reduce([[]], fn {t, b}, partials ->
      for partial <- partials, color <- [t, b], do: [color | partial]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.map(&streak_score/1)
    |> Enum.max()
  end

  describe "best_path/2" do
    test "empty trays" do
      assert ChainStreak.best_path([], []) == []
    end

    test "a single 4-streak beats two 3-streaks, with the leftover 1-streak as tiebreaker" do
      top = [:gloom, :gluttony, :lust, :wrath, :wrath, :wrath, :wrath]
      bottom = [:gloom, :gloom, :gloom, :pride, :envy, :wrath, :gluttony]

      choices = ChainStreak.best_path(top, bottom)

      assert choices == [:top, :bottom, :bottom, :top, :top, :top, :top]
      assert colors_for(top, bottom, choices) == [:gloom, :gloom, :gloom, :wrath, :wrath, :wrath, :wrath]
    end

    test "picks the longer streak when rows disagree" do
      top = [:wrath, :wrath, :wrath, :gloom]
      bottom = [:gloom, :gloom, :gloom, :gloom]

      choices = ChainStreak.best_path(top, bottom)

      assert colors_for(top, bottom, choices) == [:gloom, :gloom, :gloom, :gloom]
    end

    test "matches an exhaustive brute-force search over random trays" do
      sins = [:wrath, :lust, :sloth, :gluttony, :gloom, :pride, :envy]

      for _trial <- 1..200 do
        n = Enum.random(1..8)
        top = for _ <- 1..n, do: Enum.random(sins)
        bottom = for _ <- 1..n, do: Enum.random(sins)

        choices = ChainStreak.best_path(top, bottom)
        dp_score = colors_for(top, bottom, choices) |> streak_score()

        assert dp_score == brute_force_best_score(top, bottom)
      end
    end
  end
end
