defmodule StarlightBot.Navigation.MachineTest do
  use ExUnit.Case, async: false

  import StarlightBot.Navigation.DSL

  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.{Machine, Runner}

  defmodule FakeCapture do
    use GenServer

    def start_link(focused?), do: GenServer.start_link(__MODULE__, focused?, name: StarlightBot.Vision.Capture)

    @impl true
    def init(focused?), do: {:ok, focused?}

    @impl true
    def handle_call(:focused?, _from, focused?), do: {:reply, focused?, focused?}
    def handle_call(:grab_frame, _from, focused?), do: {:reply, {:error, :no_window}, focused?}
    def handle_call(:window_rect, _from, focused?), do: {:reply, nil, focused?}
  end

  defp start_capture(focused? \\ true), do: start_supervised!({FakeCapture, focused?})

  defp record(tag) do
    test = self()

    custom(fn frame, _ctx ->
      send(test, {:ran, tag, frame})
      {:ok, tag}
    end)
  end

  setup do
    start_capture()
    :ok
  end

  test "runs steps in order and threads each step's frame into the next" do
    assert Runner.run_steps([record(:a), sleep(10), record(:b), record(:c)], Ctx.new()) == {:ok, :c}

    assert_received {:ran, :a, nil}
    assert_received {:ran, :b, nil}
    assert_received {:ran, :c, :b}
  end

  test "an error stops the program and is returned" do
    steps = [record(:a), custom(fn _, _ -> {:error, :boom} end), record(:b)]

    assert Runner.run_steps(steps, Ctx.new()) == {:error, :boom}
    assert_received {:ran, :a, nil}
    refute_received {:ran, :b, _}
  end

  test "losing focus aborts before the next step" do
    stop_supervised!(FakeCapture)
    start_capture(false)

    assert Runner.run_steps([record(:a)], Ctx.new()) == {:error, :window_not_focused}
    refute_received {:ran, :a, _}
  end

  test "a pause request aborts before the next step" do
    ctx = Ctx.new(pause_requested?: fn -> true end)

    assert Runner.run_steps([record(:a)], ctx) == {:error, :window_not_focused}
    refute_received {:ran, :a, _}
  end

  test "a waiting branch falls back to its default steps" do
    steps = [branch([{:nothing_matches, [record(:matched)]}, default: [record(:default)]], wait: 150), record(:after)]

    assert Runner.run_steps(steps, Ctx.new()) == {:ok, :after}
    assert_received {:ran, :default, nil}
    assert_received {:ran, :after, :default}
    refute_received {:ran, :matched, _}
  end

  test "await times out with the hook it waited on" do
    assert Runner.run_steps([await(:nothing_matches, timeout: 150)], Ctx.new()) == {:error, {:timeout, :nothing_matches}}
  end

  test "retry_until reruns its steps until the tries run out" do
    steps = [retry_until(:nothing_matches, [record(:try)], tries: 2, every: 30)]

    assert Runner.run_steps(steps, Ctx.new()) == {:error, {:retry_exhausted, :nothing_matches}}
    assert_received {:ran, :try, nil}
    assert_received {:ran, :try, nil}
    refute_received {:ran, :try, _}
  end

  test "custom steps can run nested programs" do
    inner = [record(:inner)]
    nested = custom(fn _, ctx -> Runner.run_steps(inner, ctx) end)

    assert Runner.run_steps([nested, record(:outer)], Ctx.new()) == {:ok, :outer}
    assert_received {:ran, :inner, nil}
    assert_received {:ran, :outer, :inner}
  end

  test "a run survives the machine's code being reloaded twice mid-program" do
    steps = [sleep(400), record(:after_reload)]
    run = Task.async(fn -> Runner.run_steps(steps, Ctx.new()) end)

    Process.sleep(100)

    for _ <- 1..2 do
      :code.purge(Machine)
      {:module, Machine} = :code.load_file(Machine)
    end

    assert Task.await(run) == {:ok, :after_reload}
    assert_received {:ran, :after_reload, nil}
  end
end
