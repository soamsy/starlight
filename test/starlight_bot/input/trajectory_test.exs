defmodule StarlightBot.Input.TrajectoryTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Input.Trajectory

  test "trajectory ends exactly on the target" do
    for _ <- 1..100 do
      waypoints = Trajectory.build({0.0, 0.0}, {500.0, 300.0}, {0.0, 0.0}, 1.0)
      {x, y, _t} = List.last(waypoints)
      assert x == 500.0
      assert y == 300.0
    end
  end

  test "timestamps are strictly increasing" do
    for dist <- [5.0, 60.0, 400.0, 900.0] do
      times = Trajectory.build({100.0, 100.0}, {100.0 + dist, 140.0}, {0.0, 0.0}, 0.7) |> Enum.map(&elem(&1, 2))
      assert times == Enum.sort(Enum.uniq(times))
    end
  end

  test "sub-pixel moves collapse to the target" do
    assert [{10.3, 10.0, +0.0}] = Trajectory.build({10.0, 10.0}, {10.3, 10.0}, {0.0, 0.0}, 1.0)
  end

  test "peak speed stays in a human range" do
    for _ <- 1..50 do
      waypoints = Trajectory.build({0.0, 0.0}, {900.0, 0.0}, {0.0, 0.0}, 0.7)

      peak =
        waypoints
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{x0, y0, t0}, {x1, y1, t1}] -> :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) / (t1 - t0) end)
        |> Enum.max()

      assert peak < 15.0
    end
  end

  test "fixed duration is honoured" do
    {_, _, t} = Trajectory.build({0.0, 0.0}, {200.0, 0.0}, {0.0, 0.0}, {:duration_ms, 300}) |> List.last()
    assert t >= 250.0 and t < 420.0
  end
end
