defmodule StarlightBot.WinProbeTest do
  use ExUnit.Case, async: true

  alias StarlightBot.WinProbe

  @preamble """
  start t=1 pid=9 duration=60
  rawdev t=2 type=mouse dev=1 id=1 buttons=5 sample_rate=0 hwheel=0 val=\\\\?\\HID#VID_1&PID_2
  lastinput t=3 input_tick=100 now_tick=110
  ready t=4 pid=9
  """

  defp run(body, mode \\ :hardware) do
    parent = self()
    status = WinProbe.report(WinProbe.parse(@preamble <> body <> "lastinput t=900 input_tick=500 now_tick=510\ndone t=901 dropped_moves=0\n"), mode, fn kind, text -> send(parent, {:log, kind, text}) end)
    {status, drain([])}
  end

  defp drain(acc) do
    receive do
      {:log, kind, text} -> drain([{kind, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "parse keeps the rest of the line for val" do
    [event] = WinProbe.parse("rawdev t=5 type=mouse dev=1 val=\\\\?\\HID#VID_1 &PID_2 x=1\n")
    assert event.t == 5
    assert event.f["dev"] == "1"
    assert event.f["val"] == "\\\\?\\HID#VID_1 &PID_2 x=1"
  end

  test "finished? and ready? read the closing and opening lines" do
    assert WinProbe.ready?(@preamble)
    refute WinProbe.finished?(@preamble)
    assert WinProbe.finished?(@preamble <> "done t=9 dropped_moves=0\n")
  end

  test "hardware-looking input passes" do
    body = """
    llm t=10 msg=MOVE x=5 y=5 data=0 flags=0 time=1 tick=1 extra=0
    rawm t=11 dev=1 sink=0 flags=0 bflags=0 bdata=0 rawbtn=0 dx=3 dy=1 extra=0
    wm t=12 msg=MOVE wp=0 x=5 y=5 extra=0 mtime=1 tick=1 dev=2 origin=1 fg=1 focus=1 cap=0
    """

    assert {:ok, logs} = run(body)
    assert Enum.any?(logs, fn {kind, text} -> kind == :ok and text =~ "no low level hook event is flagged injected" end)
  end

  test "an injected flag fails the run" do
    body = """
    llm t=10 msg=LDOWN x=5 y=5 data=0 flags=1 time=1 tick=1 extra=0
    llk t=11 msg=KEYDOWN vk=65 scan=30 flags=16 time=1 tick=1 extra=0
    """

    assert {:error, logs} = run(body)
    assert Enum.any?(logs, fn {kind, text} -> kind == :error and text =~ "mouse injected 1" and text =~ "keyboard injected 1" end)
  end

  test "injected origin from the message source fails the run" do
    body = "wm t=10 msg=LDOWN wp=1 x=5 y=5 extra=0 mtime=1 tick=1 dev=2 origin=2 fg=1 focus=1 cap=0\n"
    assert {:error, _} = run(body)
  end

  test "raw mouse with hDevice 0 and absolute motion only warns" do
    body = "rawm t=10 dev=0 sink=0 flags=1 bflags=0 bdata=0 rawbtn=0 dx=100 dy=100 extra=0\n"
    assert {:warn, logs} = run(body)
    assert Enum.any?(logs, fn {_, text} -> text =~ "hDevice is 0" end)
    assert Enum.any?(logs, fn {_, text} -> text =~ "absolute only" end)
  end

  test "injected mode fails when the sent clicks never arrive" do
    body = "llm t=10 msg=MOVE x=5 y=5 data=0 flags=0 time=1 tick=1 extra=0\n"
    assert {:error, logs} = run(body, :injected)
    assert Enum.any?(logs, fn {kind, text} -> kind == :error and text =~ "left clicks not delivered" end)
  end

  test "no input at all is an error" do
    assert {:error, logs} = run("")
    assert Enum.any?(logs, fn {kind, text} -> kind == :error and text =~ "saw no input at all" end)
  end
end
