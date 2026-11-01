defmodule StarlightBot.Input.WanderTest do
  use ExUnit.Case, async: true
  alias StarlightBot.Input.Wander

  test "area expands the box by the margin and stays inside the inset window" do
    assert {85.0, 185.0, 315.0, 315.0} = Wander.area({100, 200, 200, 100}, {0, 0, 1920, 1080})
    assert {15.0, 15.0, _, _} = Wander.area({0, 0, 50, 50}, {0, 0, 1920, 1080})
    assert {15.0, 15.0, 1905.0, 1065.0} = Wander.area(nil, {0, 0, 1920, 1080})
    assert nil == Wander.area(nil, nil)
  end

  test "path stays inside the area and covers a good part of it" do
    area = {85.0, 185.0, 315.0, 275.0}
    w = Wander.new(area, {200.0, 230.0})

    {_w, points} =
      Enum.reduce(1..2000, {w, []}, fn _, {w, acc} ->
        w = Wander.step(w, 0.012)
        {w, [w.pos | acc]}
      end)

    {x0, y0, x1, y1} = area
    assert Enum.all?(points, fn {x, y} -> x >= x0 and x <= x1 and y >= y0 and y <= y1 end)
    xs = Enum.map(points, &elem(&1, 0))
    assert Enum.max(xs) - Enum.min(xs) > 0.6 * (x1 - x0)
  end

  test "idle sweep keeps 15px from the window edge" do
    area = Wander.area(nil, {100, 50, 1920, 1080})
    w = Wander.new(area, {1000.0, 500.0})
    {_, points} = Enum.reduce(1..3000, {w, []}, fn _, {w, acc} -> w = Wander.step(w, 0.012); {w, [w.pos | acc]} end)
    assert Enum.all?(points, fn {x, y} -> x >= 115 and x <= 2005 and y >= 65 and y <= 1115 end)
  end
end
