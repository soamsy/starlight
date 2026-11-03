defmodule StarlightBot.Vision.EnemyTargetsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.EnemyTargets

  test "targets 40% across and 75% down the red under each white icon, left to right" do
    whites = [{1291, 191, 18, 18}, {891, 291, 18, 18}]
    reds = [{1250, 250, 100, 60}, {850, 350, 100, 60}]

    assert [
             %EnemyTargets{icon: {900, 300}, point: {890, 395}},
             %EnemyTargets{icon: {1300, 200}, point: {1290, 295}}
           ] = EnemyTargets.from_icons(whites, reds)
  end

  test "merges the red fragments under a white icon, ignoring red above or off to the side" do
    whites = [{891, 291, 18, 18}]
    left = {850, 340, 20, 20}
    right = {880, 380, 60, 40}
    above = {850, 100, 300, 150}
    aside = {1000, 350, 300, 300}

    assert [%EnemyTargets{point: {886, 400}}] = EnemyTargets.from_icons(whites, [left, right, above, aside])
  end

  test "a fragment goes to the white icon it is closest to across" do
    whites = [{891, 291, 18, 18}, {951, 291, 18, 18}]
    reds = [{850, 350, 60, 60}, {945, 350, 60, 60}]

    assert [%EnemyTargets{icon: {900, 300}}, %EnemyTargets{icon: {960, 300}}] = EnemyTargets.from_icons(whites, reds)
    assert [%EnemyTargets{icon: {960, 300}}] = EnemyTargets.from_icons(whites, [{850, 350, 200, 60}])
  end

  test "fragments of one white icon merge into a single icon, and it needs red underneath" do
    whites = [{895, 295, 8, 8}, {891, 291, 18, 18}, {900, 300, 6, 6}]

    assert [%EnemyTargets{icon: {900, 300}}] = EnemyTargets.from_icons(whites, [{850, 350, 100, 60}])
    assert EnemyTargets.from_icons(whites, []) == []
  end

  test "touching fragments merge and the measuring stick is the smallest side, capped at 18px" do
    fragments = [{1150, 456, 14, 10}, {1150, 465, 19, 5}]
    red = [{1130, 521, 38, 32}]

    assert [%EnemyTargets{icon: {1160, 463}}] = EnemyTargets.from_icons(fragments, red)
    assert [] = EnemyTargets.from_icons([{1150, 456, 14, 10}], red)
  end

  test "the target x is capped at 10px left of the icon center, and y is unchanged" do
    whites = [{891, 291, 18, 18}]

    assert [%EnemyTargets{icon: {900, 300}, point: {890, 395}}] = EnemyTargets.from_icons(whites, [{880, 350, 100, 60}])
    assert [%EnemyTargets{point: {860, 395}}] = EnemyTargets.from_icons(whites, [{820, 350, 100, 60}])
  end

  test "staggered markers under a white icon target the same way as red ones" do
    whites = [{891, 291, 18, 18}, {1291, 191, 18, 18}]
    staggered = [{850, 350, 100, 60}]
    red = [{1250, 250, 100, 60}]

    assert [%EnemyTargets{point: {890, 395}}, %EnemyTargets{point: {1290, 295}}] = EnemyTargets.from_icons(whites, staggered ++ red)
  end

  test "a sin icon under a white icon is its body, ahead of stray red" do
    whites = [{891, 291, 18, 18}]
    sin = {874, 350, 53, 23}
    stray = {880, 400, 15, 13}

    assert [%EnemyTargets{icon: {900, 300}, point: {890, 367}}] = EnemyTargets.from_icons(whites, [stray], [sin], [])
    assert [] = EnemyTargets.from_icons(whites, [], [{874, 100, 53, 23}], [])
    assert [_] = EnemyTargets.from_icons(whites, [], [{847, 350, 53, 23}], [])
    assert [] = EnemyTargets.from_icons(whites, [], [{846, 350, 53, 23}], [])
  end

  test "a brown icon close to a red is targetable without a white icon" do
    red = {850, 400, 100, 200}

    assert [%EnemyTargets{icon: {900, 420}, point: {890, 550}}] =
             EnemyTargets.from_icons([], [], [{880, 400, 40, 40}], [red])
  end

  test "white matches larger than 40px in either dimension are ignored" do
    red = [{850, 350, 100, 60}]

    assert [] = EnemyTargets.from_icons([{880, 280, 41, 40}], red)
    assert [] = EnemyTargets.from_icons([{880, 280, 40, 41}], red)
    assert [_] = EnemyTargets.from_icons([{880, 280, 40, 40}], red)
  end

  test "a backup icon cannot claim a red inside the zone of a white icon that found its own red" do
    white = [{891, 291, 18, 18}]
    own = {850, 350, 100, 60}
    other = {880, 350, 100, 60}
    brown = [{920, 360, 40, 40}]

    assert [%EnemyTargets{icon: {900, 300}}] = EnemyTargets.from_icons(white, [own], brown, [other])
  end

  test "a white icon without red underneath leaves its zone open to backup icons" do
    white = [{891, 291, 18, 18}]
    brown = [{1010, 380, 40, 40}]

    assert [%EnemyTargets{icon: {1030, 400}}] = EnemyTargets.from_icons(white, [], brown, [{1000, 400, 100, 200}])
  end

  test "a backup target reserves its red padded by 20px and keeps other backup reds out" do
    near = {850, 400, 100, 200}
    close = {900, 400, 80, 150}
    far = {1100, 400, 100, 200}
    icons = [{880, 380, 40, 40}, {930, 380, 40, 40}, {1120, 380, 40, 40}]

    assert [%EnemyTargets{zone: {830, 380, 140, 240}}, %EnemyTargets{icon: {1140, 400}}] =
             EnemyTargets.from_icons([], [], icons, [near, close, far])
  end

  test "a brown icon far from any red is ignored, and one matching a white icon is not doubled" do
    red = {850, 350, 100, 60}

    assert [] = EnemyTargets.from_icons([], [], [{880, 100, 40, 40}], [red])

    assert [_] =
             EnemyTargets.from_icons([{891, 291, 18, 18}], [red], [{890, 285, 40, 40}], [red])
  end

  test "red centers must sit 2x to 7x the 18px stick below the white center and within 2.5x across" do
    white = [{1190, 490, 20, 20}]
    at = fn cx, cy -> [{cx - 10, cy - 10, 20, 20}] end

    assert [_] = EnemyTargets.from_icons(white, at.(1200, 536))
    assert [_] = EnemyTargets.from_icons(white, at.(1200, 626))
    assert [_] = EnemyTargets.from_icons(white, at.(1155, 580))
    assert [_] = EnemyTargets.from_icons(white, at.(1245, 580))
    assert [] = EnemyTargets.from_icons(white, at.(1200, 535))
    assert [] = EnemyTargets.from_icons(white, at.(1200, 627))
    assert [] = EnemyTargets.from_icons(white, at.(1154, 580))
    assert [] = EnemyTargets.from_icons(white, at.(1246, 580))
  end
end
