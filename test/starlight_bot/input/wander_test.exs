defmodule StarlightBot.Input.WanderTest do
  use ExUnit.Case, async: true
  alias StarlightBot.Input.Wander

  defp run(area, start, ticks, opts \\ []) do
    w = Wander.new(area, start, opts)

    {_w, points} =
      Enum.reduce(1..ticks, {w, []}, fn _, {w, acc} ->
        w = Wander.step(w, 0.012)
        {w, [w.pos | acc]}
      end)

    Enum.reverse(points)
  end

  test "area expands the box by the margin and stays inside the inset window" do
    assert {85.0, 185.0, 315.0, 315.0} = Wander.area({100, 200, 200, 100}, {0, 0, 1920, 1080})
    assert {15.0, 15.0, _, _} = Wander.area({0, 0, 50, 50}, {0, 0, 1920, 1080})
    assert {100, 200, 300, 300} = Wander.area({100, 200, 200, 100}, {0, 0, 1920, 1080}, 0)
    assert {15.0, 15.0, 1905.0, 1065.0} = Wander.area(nil, {0, 0, 1920, 1080})
    assert nil == Wander.area(nil, nil)
  end

  defp speeds(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{ax, ay}, {bx, by}] -> :math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 0.012 end)
  end

  test "path stays inside the area" do
    area = {85.0, 185.0, 315.0, 275.0}
    points = run(area, {200.0, 230.0}, 3000)
    {x0, y0, x1, y1} = area
    assert Enum.all?(points, fn {x, y} -> x >= x0 and x <= x1 and y >= y0 and y <= y1 end)
  end

  test "moves in tiny sweeps with occasional fast lunges" do
    zone = Wander.zone({0, 0, 1920, 1080}, {0.7, 0.65}, {0.4, 0.4})
    sp = speeds(Enum.take(run(zone, {1300.0, 700.0}, 400), 400))
    assert Enum.max(sp) > 500.0
    sorted = Enum.sort(sp)
    assert Enum.at(sorted, div(length(sorted), 2)) < 250.0
  end

  test "stops after the active window except for twitches" do
    zone = Wander.zone({0, 0, 1920, 1080}, {0.7, 0.65}, {0.4, 0.4})
    points = run(zone, {1300.0, 700.0}, 2000)
    late = Enum.drop(points, 600)
    xs = Enum.map(late, &elem(&1, 0))
    ys = Enum.map(late, &elem(&1, 1))
    assert Enum.max(xs) - Enum.min(xs) < 40.0
    assert Enum.max(ys) - Enum.min(ys) < 40.0
    assert Enum.count(speeds(late), &(&1 > 20.0)) < 0.4 * length(late)
  end

  test "held wander stays within a few pixels" do
    points = run({400.0, 400.0, 500.0, 460.0}, {450.0, 430.0}, 1500, held: true)
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    assert Enum.max(xs) - Enum.min(xs) < 16.0
    assert Enum.max(ys) - Enum.min(ys) < 16.0
    assert Enum.max(speeds(points)) < 400.0
  end

  test "path is not a straight line" do
    points = run({15.0, 15.0, 400.0, 300.0}, {200.0, 150.0}, 300)

    headings =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{ax, ay}, {bx, by}] -> :math.atan2(by - ay, bx - ax) end)

    assert Enum.max(headings) - Enum.min(headings) > 1.0
  end

  test "zone stays 15px inside the window and centers on the rest point where it fits" do
    window = {100, 50, 1920, 1080}
    {x0, y0, x1, y1} = Wander.zone(window, {0.9, 0.9}, {0.4, 0.4})
    assert x0 >= 115 and x1 <= 2005 and y0 >= 65 and y1 <= 1115
    assert_in_delta x1 - x0, 0.4 * 1890, 1.0
  end

  test "idle path keeps 15px from the window edge" do
    window = {100, 50, 1920, 1080}
    zone = Wander.zone(window, {0.9, 0.9}, {0.4, 0.4})
    points = run(zone, {1500.0, 900.0}, 3000)
    assert Enum.all?(points, fn {x, y} -> x >= 115 and x <= 2005 and y >= 65 and y <= 1115 end)
  end
end
