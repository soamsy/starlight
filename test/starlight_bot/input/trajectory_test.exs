defmodule StarlightBot.Input.TrajectoryTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Input.Trajectory

  test "trajectory reaches target" do
    waypoints = Trajectory.build({0.0, 0.0}, {500.0, 300.0}, {0.0, 0.0}, 1.0)
    assert waypoints != []

    {x, y, _t} = List.last(waypoints)
    assert_in_delta x, 500.0, 20.0
    assert_in_delta y, 300.0, 20.0
  end

  test "bezier at t=0 is start" do
    {x, y} = Trajectory.bezier_point({10.0, 20.0}, {200.0, 300.0}, [{50.0, 100.0}], 0.0)
    assert_in_delta x, 10.0, 0.001
    assert_in_delta y, 20.0, 0.001
  end

  test "bezier at t=1 is end" do
    {x, y} = Trajectory.bezier_point({10.0, 20.0}, {200.0, 300.0}, [{50.0, 100.0}], 1.0)
    assert_in_delta x, 200.0, 0.001
    assert_in_delta y, 300.0, 0.001
  end
end
