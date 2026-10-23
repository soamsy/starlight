defmodule StarlightBot.Navigation.MachineTest do
  use ExUnit.Case, async: false

  import StarlightBot.Navigation.DSL

  alias StarlightBot.{Ctx, FakeWorld}
  alias StarlightBot.Navigation.{Machine, Runner}

  @moduletag :capture_log

  @hooks [:fw_popup, :fw_button, :fw_done, :fw_hidden]

  def record(test, tag, frame, _ctx) do
    send(test, {:ran, tag, frame})
    {:ok, tag}
  end

  def boom(_frame, _ctx), do: {:error, :boom}

  def nested(steps, _frame, ctx), do: Runner.run_steps(steps, ctx)

  def more_steps(steps, _frame, _ctx), do: {:steps, steps}

  def request_pause(pause_flag, _frame, _ctx) do
    :atomics.put(pause_flag, 1, 1)
    {:ok, nil}
  end

  defp record(tag), do: call(__MODULE__, :record, [self(), tag])

  defp run(steps, ctx \\ Ctx.new()), do: Runner.run_steps(steps, ctx)

  setup context do
    FakeWorld.start!(hooks: @hooks, visible: Map.get(context, :visible, []), focused?: Map.get(context, :focused?, true))
    :ok
  end

  describe "sequencing" do
    test "runs steps in order and threads each step's frame into the next" do
      assert run([record(:a), sleep(10), record(:b), record(:c)]) == {:ok, :c}

      assert_received {:ran, :a, nil}
      assert_received {:ran, :b, nil}
      assert_received {:ran, :c, :b}
    end

    test "an error stops the program and is returned" do
      assert run([record(:a), call(__MODULE__, :boom), record(:b)]) == {:error, :boom}
      assert_received {:ran, :a, nil}
      refute_received {:ran, :b, _}
    end

    test "a call can return more steps to run next" do
      assert run([call(__MODULE__, :more_steps, [[record(:pushed)]]), record(:after)]) == {:ok, :after}
      assert_received {:ran, :pushed, nil}
      assert_received {:ran, :after, :pushed}
    end

    test "calls can run nested programs" do
      assert run([call(__MODULE__, :nested, [[record(:inner)]]), record(:outer)]) == {:ok, :outer}
      assert_received {:ran, :inner, nil}
      assert_received {:ran, :outer, :inner}
    end

    test "fail stops with its reason and log does not touch the game" do
      assert run([log(:info, "hello"), fail(:nope), record(:never)]) == {:error, :nope}
      refute_received {:ran, :never, _}
      assert FakeWorld.inputs() == []
    end
  end

  describe "guards" do
    @tag focused?: false
    test "losing focus aborts before the next step" do
      assert run([record(:a)]) == {:error, :window_not_focused}
      refute_received {:ran, :a, _}
    end

    test "a pause request aborts before the next step" do
      pause_flag = :atomics.new(1, [])
      :atomics.put(pause_flag, 1, 1)

      assert run([record(:a)], Ctx.new(pause_flag: pause_flag)) == {:error, :window_not_focused}
      refute_received {:ran, :a, _}
    end
  end

  describe "waiting on the screen" do
    @tag visible: [:fw_popup]
    test "a branch takes the clause whose hook is on screen" do
      assert run([branch([{:fw_hidden, [record(:hidden)]}, {:fw_popup, [record(:popup)]}])]) == {:ok, :popup}
    end

    test "a waiting branch falls back to its default steps" do
      steps = [branch([{:fw_hidden, [record(:matched)]}, default: [record(:default)]], wait: 150), record(:after)]

      assert run(steps) == {:ok, :after}
      assert_received {:ran, :default, _}
      refute_received {:ran, :matched, _}
    end

    test "await matches once the hook shows up" do
      FakeWorld.react({:key, :enter}, show: [:fw_done], after: 150)

      assert {:ok, %StarlightBot.Vision.Frame{}} = run([key(:enter), await(:fw_done, timeout: 2_000)])
    end

    test "await times out with the hook it waited on" do
      assert run([await(:fw_hidden, timeout: 150)]) == {:error, {:timeout, :fw_hidden}}
    end

    test "retry_until clicks until the hook appears" do
      FakeWorld.react({:click, :fw_button}, show: [:fw_done])
      FakeWorld.show(:fw_button)

      assert {:ok, _} = run([retry_until(:fw_done, [click(:fw_button)], every: 100, tries: 3)])
      assert FakeWorld.inputs() == [{:click, :fw_button}]
    end

    test "retry_until reruns its steps until the tries run out" do
      assert run([retry_until(:fw_hidden, [key(:enter)], tries: 2, every: 30)]) == {:error, {:retry_exhausted, :fw_hidden}}
      assert FakeWorld.inputs() == [{:key, :enter}, {:key, :enter}]
    end

    @tag visible: [:fw_popup]
    test "hold waits for a hook to stay put, and runs its else steps when it never does" do
      FakeWorld.react({:key, :enter}, hide: [:fw_popup], after: 100)

      assert {:ok, _} = run([key(:enter), hold(not_hook(:fw_popup), 150, within: 1_000, else: [fail(:never_left)])])
      assert run([hold(:fw_popup, 100, within: 300, else: [fail(:never_steady)])]) == {:error, :never_steady}
    end
  end

  describe "confirm_enter" do
    @tag visible: [:fw_popup]
    test "presses enter once when the popup goes away" do
      FakeWorld.react({:key, :enter}, hide: [:fw_popup])

      assert {:ok, _} = run(confirm_enter(:fw_popup))
      assert FakeWorld.inputs() == [{:key, :enter}]
    end

    @tag visible: [:fw_popup]
    test "gives up after five presses when the popup stays" do
      assert run(confirm_enter(:fw_popup)) == {:error, {:retry_exhausted, :fw_popup}}
      assert FakeWorld.inputs() == List.duplicate({:key, :enter}, 5)
    end
  end

  describe "attempt and ensure" do
    test "attempt runs its fallback only when the steps fail" do
      assert run([attempt([fail(:first)], else: [record(:fallback)])]) == {:ok, :fallback}
      assert run([attempt([record(:fine)], else: [record(:unused)]), record(:after)]) == {:ok, :after}
      refute_received {:ran, :unused, _}
    end

    test "ensure runs its cleanup on success and failure, and keeps the original error" do
      assert {:ok, _} = run([ensure([mouse_down()], [mouse_up()])])
      assert run([ensure([mouse_down(), await(:fw_hidden, timeout: 100)], [mouse_up()])]) == {:error, {:timeout, :fw_hidden}}
      assert FakeWorld.inputs() == [{:mouse, :down}, {:mouse, :up}, {:mouse, :down}, {:mouse, :up}]
    end

    test "ensure cleanup still runs when a pause stops the steps" do
      pause_flag = :atomics.new(1, [])
      steps = [ensure([mouse_down(), call(__MODULE__, :request_pause, [pause_flag]), key(:enter)], [mouse_up()])]

      assert run(steps, Ctx.new(pause_flag: pause_flag)) == {:error, :window_not_focused}
      assert FakeWorld.inputs() == [{:mouse, :down}, {:mouse, :up}]
    end
  end

  test "a run survives the machine's code being reloaded twice mid-program" do
    steps = [sleep(400), record(:after_reload)]
    run = Task.async(fn -> run(steps) end)

    Process.sleep(100)

    for _ <- 1..2 do
      :code.purge(Machine)
      {:module, Machine} = :code.load_file(Machine)
    end

    assert Task.await(run) == {:ok, :after_reload}
    assert_received {:ran, :after_reload, nil}
  end
end
