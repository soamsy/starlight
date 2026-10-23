defmodule StarlightBot.Vision.EnemyTargetsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.EnemyTargets

  test "targets 40% across and halfway down the bottom half of the red under each white icon, left to right" do
    whites = [{1280, 180, 40, 40}, {880, 280, 40, 40}]
    reds = [{1250, 300, 100, 200}, {850, 400, 100, 200}]

    assert [
             %EnemyTargets{icon: {900, 300}, point: {890, 550}},
             %EnemyTargets{icon: {1300, 200}, point: {1290, 450}}
           ] = EnemyTargets.from_icons(whites, reds)
  end

  test "picks the biggest red cluster underneath, ignoring red above or off to the side" do
    whites = [{880, 280, 40, 40}]
    small = {870, 340, 20, 20}
    big = {850, 400, 100, 200}
    above = {850, 100, 300, 150}
    aside = {1000, 400, 300, 300}

    assert [%EnemyTargets{point: {890, 550}}] = EnemyTargets.from_icons(whites, [small, big, above, aside])
  end

  test "detections inside the same white icon count once, and need red underneath" do
    whites = [{895, 300, 10, 10}, {880, 280, 40, 40}, {905, 285, 12, 12}]

    assert [%EnemyTargets{icon: {900, 300}}] = EnemyTargets.from_icons(whites, [{850, 400, 100, 200}])
    assert EnemyTargets.from_icons(whites, []) == []
  end

  test "white icons close together that share one red cluster make one target" do
    whites = [{880, 280, 40, 40}, {940, 280, 40, 40}]

    assert [_] = EnemyTargets.from_icons(whites, [{850, 400, 200, 200}])
    assert [_, _] = EnemyTargets.from_icons(whites, [{850, 400, 60, 200}, {945, 400, 60, 200}])
  end

  test "the target x is capped at 10px left of the icon center, and y is unchanged" do
    whites = [{880, 280, 40, 40}]

    assert [%EnemyTargets{icon: {900, 300}, point: {890, 550}}] = EnemyTargets.from_icons(whites, [{880, 400, 100, 200}])
    assert [%EnemyTargets{point: {860, 550}}] = EnemyTargets.from_icons(whites, [{820, 400, 100, 200}])
  end

  test "staggered markers under a white icon target the same way as red ones" do
    whites = [{880, 280, 40, 40}, {1280, 180, 40, 40}]
    staggered = [{850, 400, 100, 200}]
    red = [{1250, 300, 100, 200}]

    assert [%EnemyTargets{point: {890, 550}}, %EnemyTargets{point: {1290, 450}}] = EnemyTargets.from_icons(whites, staggered ++ red)
  end
end
