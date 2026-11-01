defmodule StarlightBot.WinProbe do
  import Bitwise

  @describe_kinds ~w(ver sys env rawdev rawdevs rawreg hooks win cursor0)
  @mouse_wm ~w(MOVE LDOWN LUP RDOWN RUP MDOWN MUP WHEEL HWHEEL)
  @vk_a 65
  @vk_escape 27
  @raw_left_down 1

  def source_path, do: Application.app_dir(:starlight_bot, "priv/linux_checks/winprobe.c")
  def exe_path, do: Application.app_dir(:starlight_bot, "priv/linux_checks/winprobe.exe")
  def title, do: "starlight-winprobe"

  def parse(text), do: text |> String.split("\n", trim: true) |> Enum.flat_map(&parse_line/1)

  def finished?(text), do: String.contains?(text, "\ndone ") or String.starts_with?(text, "done ")
  def ready?(text), do: String.contains?(text, "\nready ")

  defp parse_line(line) do
    case String.split(line, " ", parts: 2) do
      [kind, rest] ->
        fields = fields(rest, %{})
        [%{kind: kind, t: num(fields, "t"), f: Map.delete(fields, "t")}]

      _ ->
        []
    end
  end

  defp fields("", acc), do: acc
  defp fields("val=" <> value, acc), do: Map.put(acc, "val", value)

  defp fields(text, acc) do
    {token, rest} =
      case String.split(text, " ", parts: 2) do
        [token, rest] -> {token, rest}
        [token] -> {token, ""}
      end

    case String.split(token, "=", parts: 2) do
      [key, value] -> fields(rest, Map.put(acc, key, value))
      _ -> fields(rest, acc)
    end
  end

  defp num(f, key) do
    case Integer.parse(Map.get(f, key, "")) do
      {n, _} -> n
      :error -> 0
    end
  end

  def report(events, mode, log) do
    by = Enum.group_by(events, & &1.kind)
    describe(events, log)
    stats(by, log)
    findings = findings(by, mode)
    for {status, text} <- findings, do: log.(finding_kind(status), text)
    worst(findings)
  end

  defp finding_kind(:ok), do: :ok
  defp finding_kind(:warn), do: :info
  defp finding_kind(:error), do: :error

  defp worst(findings) do
    statuses = Enum.map(findings, &elem(&1, 0))

    cond do
      :error in statuses -> :error
      :warn in statuses -> :warn
      true -> :ok
    end
  end

  defp describe(events, log) do
    for %{kind: kind, f: f} <- events, kind in @describe_kinds do
      {text, rest} = Map.pop(f, "val")
      pairs = rest |> Enum.sort() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
      log.(:info, "winprobe #{kind}: #{pairs}#{if text, do: " " <> text, else: ""}")
    end

    :ok
  end

  defp stats(by, log) do
    mouse = Map.get(by, "llm", [])
    keys = Map.get(by, "llk", [])
    raw_mouse = Map.get(by, "rawm", [])
    raw_keys = Map.get(by, "rawk", [])
    wm = Map.get(by, "wm", [])

    log.(:info, "winprobe events: low level mouse #{length(mouse)}, low level keyboard #{length(keys)}, raw mouse #{length(raw_mouse)}, raw keyboard #{length(raw_keys)}, window messages #{length(wm)}, polled cursor #{length(Map.get(by, "pcur", []))}, polled keys #{length(Map.get(by, "pkey", []))}")

    moves = Enum.filter(mouse, &(&1.f["msg"] == "MOVE"))
    positions = moves |> Enum.map(&{num(&1.f, "x"), num(&1.f, "y")})
    log.(:info, "winprobe low level mouse: #{count_by(mouse, & &1.f["msg"])}; flags #{count_by(mouse, &num(&1.f, "flags"))}; extra #{count_by(mouse, & &1.f["extra"])}")
    log.(:info, "winprobe low level mouse moves: #{length(moves)} events, #{positions |> Enum.uniq() |> length()} distinct positions, largest jump #{max_jump(positions)}px, interval ms #{spread(intervals(moves))}")
    log.(:info, "winprobe low level mouse hook latency ms (tick minus event time): #{spread(Enum.map(mouse ++ keys, &(num(&1.f, "tick") - num(&1.f, "time"))))}")
    log.(:info, "winprobe low level keyboard: #{count_by(keys, &"#{&1.f["msg"]} vk#{&1.f["vk"]}")}; flags #{count_by(keys, &num(&1.f, "flags"))}; extra #{count_by(keys, & &1.f["extra"])}")

    log.(:info, "winprobe raw mouse: devices #{count_by(raw_mouse, & &1.f["dev"])}; foreground/sink #{count_by(raw_mouse, & &1.f["sink"])}; usFlags #{count_by(raw_mouse, &num(&1.f, "flags"))} (0 relative, 1 absolute, 2 virtual desktop); button flags #{count_by(raw_mouse, &num(&1.f, "bflags"))}; extra #{count_by(raw_mouse, & &1.f["extra"])}")
    relative = Enum.filter(raw_mouse, &(band(num(&1.f, "flags"), 1) == 0))
    absolute = raw_mouse -- relative
    log.(:info, "winprobe raw mouse relative motion: #{length(relative)} events, sum dx #{Enum.sum(Enum.map(relative, &num(&1.f, "dx")))}, sum dy #{Enum.sum(Enum.map(relative, &num(&1.f, "dy")))}, largest step #{relative |> Enum.map(&max(abs(num(&1.f, "dx")), abs(num(&1.f, "dy")))) |> Enum.max(fn -> 0 end)}, interval ms #{spread(intervals(Enum.filter(relative, &(num(&1.f, "dx") != 0 or num(&1.f, "dy") != 0))))}")
    log.(:info, "winprobe raw mouse absolute motion (0..65535 units): #{length(absolute)} events, x range #{range(absolute, "dx")}, y range #{range(absolute, "dy")}, interval ms #{spread(intervals(absolute))}")
    log.(:info, "winprobe raw keyboard: devices #{count_by(raw_keys, & &1.f["dev"])}; foreground/sink #{count_by(raw_keys, & &1.f["sink"])}; keys #{count_by(raw_keys, &"vk#{&1.f["vk"]} flags#{&1.f["flags"]}")}; extra #{count_by(raw_keys, & &1.f["extra"])}")

    log.(:info, "winprobe window messages: #{count_by(wm, &"#{&1.f["msg"]}")}")
    log.(:info, "winprobe window message source (device 1 keyboard, 2 mouse; origin 1 hardware, 2 injected, 4 system, 0 unavailable, -1 api missing): #{count_by(wm, &"device#{&1.f["dev"]}/origin#{&1.f["origin"]}")}; extra #{count_by(wm, & &1.f["extra"])}")
    log.(:info, "winprobe window state on messages: foreground #{count_by(wm, & &1.f["fg"])}, focus #{count_by(wm, & &1.f["focus"])}, capture #{count_by(wm, & &1.f["cap"])} (1 means yes)")

    poll_cursor = Map.get(by, "pcur", []) |> Enum.map(&{num(&1.f, "x"), num(&1.f, "y")})
    log.(:info, "winprobe polled cursor (GetCursorPos): #{length(Enum.uniq(poll_cursor))} distinct positions, largest jump #{max_jump(poll_cursor)}px")
    log.(:info, "winprobe polled keys (GetAsyncKeyState): #{count_by(Map.get(by, "pkey", []), &"vk#{&1.f["vk"]} down#{&1.f["down"]}")}")

    case Map.get(by, "lastinput", []) do
      [first, last | _] ->
        log.(:info, "winprobe GetLastInputInfo: tick #{first.f["input_tick"]} at start, #{last.f["input_tick"]} at end, now #{last.f["now_tick"]}")

      _ ->
        :ok
    end

    case Map.get(by, "done") do
      [%{f: f} | _] -> log.(:info, "winprobe dropped move events: #{f["dropped_moves"]}")
      _ -> log.(:info, "winprobe never wrote its closing line, so the last events may be missing")
    end

    :ok
  end

  defp findings(by, mode) do
    mouse = Map.get(by, "llm", [])
    keys = Map.get(by, "llk", [])
    raw_mouse = Map.get(by, "rawm", [])
    raw_keys = Map.get(by, "rawk", [])
    wm = Map.get(by, "wm", [])
    hardware_handles = by |> Map.get("rawdev", []) |> Enum.map(& &1.f["dev"]) |> MapSet.new()

    if mouse == [] and keys == [] and raw_mouse == [] and raw_keys == [] and Enum.all?(wm, &(&1.f["origin"] == "4")) do
      [{:error, "winprobe saw no input at all; the pointer may not have reached its window, or the compositor delivered nothing to Wine"}]
    else
      List.flatten([
        injected_flags(mouse, keys),
        message_source(wm),
        extra_info(mouse ++ keys ++ raw_mouse ++ raw_keys),
        raw_devices("mouse", raw_mouse, hardware_handles),
        raw_devices("keyboard", raw_keys, hardware_handles),
        raw_motion(raw_mouse),
        channels(by),
        focus(wm),
        last_input(Map.get(by, "lastinput", []), mouse ++ keys),
        if(mode == :injected, do: injected_expectations(by, mouse, keys), else: [])
      ])
    end
  end

  defp injected_flags(mouse, keys) do
    mouse_injected = Enum.count(mouse, &(band(num(&1.f, "flags"), 1) != 0))
    mouse_lower = Enum.count(mouse, &(band(num(&1.f, "flags"), 2) != 0))
    key_injected = Enum.count(keys, &(band(num(&1.f, "flags"), 0x10) != 0))
    key_lower = Enum.count(keys, &(band(num(&1.f, "flags"), 2) != 0))

    if mouse_injected + mouse_lower + key_injected + key_lower == 0 do
      [{:ok, "no low level hook event is flagged injected (#{length(mouse)} mouse, #{length(keys)} keyboard)"}]
    else
      [{:error, "Windows flags input as injected: mouse injected #{mouse_injected}, mouse lower integrity #{mouse_lower}, keyboard injected #{key_injected}, keyboard lower integrity #{key_lower}"}]
    end
  end

  defp message_source(wm) do
    origins = wm |> Enum.reject(&(&1.f["origin"] == "4")) |> Enum.map(& &1.f["origin"])
    injected = Enum.count(origins, &(&1 == "2"))
    hardware = Enum.count(origins, &(&1 == "1"))

    cond do
      injected > 0 -> [{:error, "GetCurrentInputMessageSource says #{injected} window messages are injected"}]
      hardware > 0 -> [{:ok, "GetCurrentInputMessageSource reports hardware for #{hardware} window messages and injected for none"}]
      origins == [] -> [{:warn, "no window messages reached the probe, so message source was not tested"}]
      Enum.all?(origins, &(&1 == "-1")) -> [{:warn, "GetCurrentInputMessageSource is missing, so message origin was not tested"}]
      true -> [{:warn, "GetCurrentInputMessageSource reports origin unavailable for every window message; a game cannot tell from it"}]
    end
  end

  defp extra_info(events) do
    extras = events |> Enum.map(& &1.f["extra"]) |> Enum.reject(&(&1 in [nil, "0"])) |> Enum.uniq()

    case extras do
      [] ->
        [{:ok, "dwExtraInfo and ulExtraInformation are 0 on every hook and raw input event"}]

      extras ->
        touch = Enum.any?(extras, &String.starts_with?(&1, "ff5157"))
        [{:warn, "non-zero extra info on hook or raw events: #{Enum.join(extras, ", ")}#{if touch, do: " (0xFF5157xx is the touch/pen signature)", else: ""}"}]
    end
  end

  defp raw_devices(_label, [], _handles), do: []

  defp raw_devices(label, events, handles) do
    devices = events |> Enum.map(& &1.f["dev"]) |> Enum.uniq()

    cond do
      devices == ["0"] ->
        [{:warn, "raw #{label} hDevice is 0 on every event, which is what Windows reports for SendInput; compare with the real hardware run"}]

      Enum.all?(devices, &MapSet.member?(handles, &1)) ->
        [{:ok, "raw #{label} events come from enumerated devices (handles #{Enum.join(devices, ", ")})"}]

      true ->
        [{:warn, "raw #{label} hDevice #{Enum.join(devices, ", ")} is not in the enumerated device list"}]
    end
  end

  defp raw_motion(raw_mouse) do
    relative = Enum.filter(raw_mouse, &(band(num(&1.f, "flags"), 1) == 0))
    moving = Enum.count(relative, &(num(&1.f, "dx") != 0 or num(&1.f, "dy") != 0))
    absolute = length(raw_mouse) - length(relative)

    cond do
      raw_mouse == [] -> []
      moving == 0 -> [{:warn, "raw mouse motion is absolute only (#{absolute} absolute events, no relative deltas); a game reading relative deltas gets none; compare with the real hardware run on this launcher"}]
      true -> [{:ok, "raw mouse motion includes relative deltas (#{moving} moving relative events, #{absolute} absolute events)"}]
    end
  end

  defp channels(by) do
    mouse = Map.get(by, "llm", [])
    keys = Map.get(by, "llk", [])
    wm = Map.get(by, "wm", [])
    raw_mouse = Map.get(by, "rawm", [])
    raw_keys = Map.get(by, "rawk", [])
    poll = Map.get(by, "pkey", [])

    left = [
      {"hook", Enum.count(mouse, &(&1.f["msg"] == "LDOWN"))},
      {"window message", Enum.count(wm, &(&1.f["msg"] == "LDOWN"))},
      {"raw input", Enum.count(raw_mouse, &(band(num(&1.f, "bflags"), @raw_left_down) != 0))},
      {"async state", Enum.count(poll, &(&1.f["vk"] == "1" and &1.f["down"] == "1"))}
    ]

    key_a = [
      {"hook", Enum.count(keys, &(&1.f["msg"] == "KEYDOWN" and num(&1.f, "vk") == @vk_a))},
      {"window message", Enum.count(wm, &(&1.f["msg"] == "KEYDOWN" and &1.f["wp"] == "41"))},
      {"raw input", Enum.count(raw_keys, &(num(&1.f, "vk") == @vk_a and band(num(&1.f, "flags"), 1) == 0))},
      {"async state", Enum.count(poll, &(&1.f["vk"] == "65" and &1.f["down"] == "1"))}
    ]

    [agreement("left button presses", left), agreement("A key presses", key_a)]
  end

  defp agreement(label, counts) do
    text = Enum.map_join(counts, ", ", fn {name, n} -> "#{name} #{n}" end)
    numbers = Enum.map(counts, &elem(&1, 1))

    cond do
      Enum.sum(numbers) == 0 -> {:ok, "#{label}: none sent or seen"}
      Enum.uniq(numbers) |> length() == 1 -> {:ok, "#{label} agree across every input path: #{text}"}
      true -> {:warn, "#{label} differ between input paths: #{text}"}
    end
  end

  defp focus(wm) do
    input = Enum.filter(wm, &(&1.f["msg"] in (@mouse_wm -- ["MOVE"]) or &1.f["msg"] in ~w(KEYDOWN KEYUP CHAR)))
    foreground = Enum.count(input, &(&1.f["fg"] == "1"))

    cond do
      input == [] -> []
      foreground == length(input) -> [{:ok, "the probe window was foreground for all #{length(input)} button, wheel and key messages"}]
      true -> [{:warn, "the probe window was foreground for only #{foreground} of #{length(input)} button, wheel and key messages"}]
    end
  end

  defp last_input([first, last | _], hooked) when hooked != [] do
    if num(last.f, "input_tick") > num(first.f, "input_tick"),
      do: [{:ok, "GetLastInputInfo advanced, so Windows counted the input as user activity"}],
      else: [{:warn, "GetLastInputInfo did not advance although input arrived, so Windows did not count it as user activity"}]
  end

  defp last_input(_samples, _hooked), do: []

  defp injected_expectations(by, mouse, keys) do
    wm = Map.get(by, "wm", [])
    positions = mouse |> Enum.filter(&(&1.f["msg"] == "MOVE")) |> Enum.map(&{num(&1.f, "x"), num(&1.f, "y")}) |> Enum.uniq()

    [
      expect("left clicks", Enum.count(mouse, &(&1.f["msg"] == "LDOWN")), 2),
      expect("right clicks", Enum.count(mouse, &(&1.f["msg"] == "RDOWN")), 1),
      expect("A key presses", Enum.count(keys, &(&1.f["msg"] == "KEYDOWN" and num(&1.f, "vk") == @vk_a)), 2),
      expect("Escape presses", Enum.count(keys, &(&1.f["msg"] == "KEYDOWN" and num(&1.f, "vk") == @vk_escape)), 1),
      expect_soft("wheel notches", Enum.count(wm, &(&1.f["msg"] == "WHEEL")), 1),
      if(length(positions) >= 20,
        do: {:ok, "the pointer sweep arrived as #{length(positions)} distinct positions, not a teleport"},
        else: {:warn, "the pointer sweep arrived as only #{length(positions)} distinct positions; motion looks like a teleport"}
      )
    ]
  end

  defp expect(label, seen, wanted) when seen >= wanted, do: {:ok, "#{label} delivered: #{seen} (sent #{wanted})"}
  defp expect(label, seen, wanted), do: {:error, "#{label} not delivered: saw #{seen}, sent #{wanted}"}

  defp expect_soft(label, seen, wanted) when seen >= wanted, do: {:ok, "#{label} delivered: #{seen} (sent #{wanted})"}
  defp expect_soft(label, seen, wanted), do: {:warn, "#{label} not delivered: saw #{seen}, sent #{wanted}"}

  defp range([], _key), do: "none"

  defp range(events, key) do
    values = Enum.map(events, &num(&1.f, key))
    "#{Enum.min(values)}..#{Enum.max(values)}"
  end

  defp count_by([], _fun), do: "none"

  defp count_by(events, fun) do
    events |> Enum.frequencies_by(fun) |> Enum.sort_by(fn {k, n} -> {-n, to_string(k)} end) |> Enum.map_join(", ", fn {k, n} -> "#{k} x#{n}" end)
  end

  defp intervals(events), do: events |> Enum.map(& &1.t) |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> (b - a) / 1000 end)

  defp max_jump(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{ax, ay}, {bx, by}] -> :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2) end)
    |> Enum.max(fn -> 0 end)
    |> round()
  end

  defp spread([]), do: "none"

  defp spread(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mean = Enum.sum(sorted) / n
    deviation = :math.sqrt(Enum.sum(Enum.map(sorted, &((&1 - mean) ** 2))) / n)
    "n=#{n} min=#{fmt(hd(sorted))} median=#{fmt(Enum.at(sorted, div(n, 2)))} mean=#{fmt(mean)} max=#{fmt(List.last(sorted))} stddev=#{fmt(deviation)}"
  end

  defp fmt(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
end
