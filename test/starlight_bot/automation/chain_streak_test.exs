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

      assert choices == [:bottom, :bottom, :bottom, :top, :top, :top, :top]
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

  describe "best_path/2 row steadiness" do
    test "breaks equal streak scores by changing rows fewer times" do
      top = [:wrath, :gloom, :pride, :lust]
      bottom = [:lust, :envy, :sloth, :wrath]

      choices = ChainStreak.best_path(top, bottom)

      assert choices |> Enum.uniq() |> length() == 1
    end

    test "never trades streak score for fewer row changes" do
      top = [:wrath, :lust, :wrath]
      bottom = [:lust, :wrath, :lust]

      choices = ChainStreak.best_path(top, bottom)

      assert colors_for(top, bottom, choices) |> Enum.uniq() |> length() == 1
    end
  end

  describe "best_path/3 with forced columns" do
    test "keeps forced columns on their row even when that breaks the best streak" do
      top = [:wrath, :wrath, :wrath]
      bottom = [:lust, :lust, :lust]

      assert ChainStreak.best_path(top, bottom, %{1 => :bottom}) |> Enum.at(1) == :bottom
    end

    test "still optimizes the free columns around the forced ones" do
      top = [:wrath, :lust, :wrath, :wrath]
      bottom = [:lust, :wrath, :lust, :lust]

      assert ChainStreak.best_path(top, bottom, %{0 => :top}) == [:top, :bottom, :top, :top]
    end

    test "free columns with no streak to gain stay on a pinned row" do
      top = [:wrath, :gloom, :pride]
      bottom = [:lust, :envy, :sloth]

      assert ChainStreak.best_path(top, bottom, %{0 => :bottom}) == [:bottom, :bottom, :bottom]
    end
  end

  describe "best_path/4 with defense skills" do
    test "uses a defense skill when it joins a streak" do
      top = [:wrath, :gloom, :wrath]
      bottom = [:lust, :envy, :sloth]
      defense = [nil, :wrath, nil]

      assert ChainStreak.best_path(top, bottom, %{}, defense) == [:top, :defense, :top]
    end

    test "ignores defense when it gains nothing" do
      top = [:wrath, :lust, :wrath]
      bottom = [:lust, :envy, :sloth]
      defense = [:pride, :gloom, :pride]

      assert ChainStreak.best_path(top, bottom, %{}, defense) == ChainStreak.best_path(top, bottom)
    end

    test "defense that only ties an existing streak is not chosen" do
      top = [:wrath, :wrath]
      bottom = [:lust, :lust]
      defense = [:wrath, :wrath]

      refute :defense in ChainStreak.best_path(top, bottom, %{}, defense)
    end

    test "a pinned column keeps its forced row" do
      top = [:wrath, :gloom, :wrath]
      bottom = [:lust, :envy, :sloth]
      defense = [nil, :wrath, nil]

      assert ChainStreak.best_path(top, bottom, %{1 => :bottom}, defense) |> Enum.at(1) == :bottom
    end

    test "nil defense matches the two-row result" do
      top = [:wrath, :lust, :wrath, :pride]
      bottom = [:lust, :wrath, :lust, :pride]

      assert ChainStreak.best_path(top, bottom, %{}, nil) == ChainStreak.best_path(top, bottom)
    end

    test "a defense that only makes a 2-run is not worth it over two normal attacks" do
      top = [:wrath, :gloom]
      bottom = [:lust, :envy]
      defense = [nil, :wrath]

      refute :defense in ChainStreak.best_path(top, bottom, %{}, defense)
    end

    test "a normal attack of the same sin beats a defense even when defense keeps the path steadier" do
      top = [:gloom, :pride, :wrath]
      bottom = [:wrath, :wrath, :sloth]
      defense = [nil, nil, :wrath]

      assert ChainStreak.best_path(top, bottom, %{}, defense) == [:bottom, :bottom, :top]
    end

    test "max_defenses invalidates paths that use more defenses" do
      top = [:wrath, :gloom, :gloom, :lust]
      bottom = [:lust, :envy, :sloth, :pride]
      defense = [nil, :wrath, :wrath, nil]

      assert ChainStreak.best_path(top, bottom, %{}, defense) == [:top, :defense, :defense, :bottom]
      assert Enum.count(ChainStreak.best_path(top, bottom, %{}, defense, 1), &(&1 == :defense)) <= 1
      refute :defense in ChainStreak.best_path(top, bottom, %{}, defense, 0)
    end

    test "min_run applies to every run and stay prefers the rows already in use" do
      top = [:wrath, :gloom]
      bottom = [:lust, :wrath]

      assert ChainStreak.best_path(top, bottom, %{}, nil, nil, stay: [:top, :top], min_run: 3) == [:top, :top]
      assert ChainStreak.best_path(top, bottom, %{}, nil, nil, stay: [:top, :top]) == [:top, :bottom]
    end

    test "committed_columns lists the columns inside runs of at least min_run" do
      top = [:wrath, :wrath, :wrath, :gloom, :gloom]
      bottom = [:lust, :lust, :lust, :envy, :envy]
      path = [:top, :top, :top, :top, :top]

      assert ChainStreak.committed_columns(path, top, bottom, nil, 3) == MapSet.new([0, 1, 2])
    end

    test "a defense that completes a 3-run is used" do
      top = [:wrath, :wrath, :gloom]
      bottom = [:lust, :envy, :sloth]
      defense = [nil, nil, :wrath]

      assert List.last(ChainStreak.best_path(top, bottom, %{}, defense)) == :defense
    end
  end
end
