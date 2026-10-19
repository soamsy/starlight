defmodule StarlightBot.Navigation.RunClock do
  defstruct elapsed_ms: 0, running_since: nil

  def start(clock \\ %__MODULE__{}, now), do: %{clock | running_since: clock.running_since || now}

  def stop(%__MODULE__{running_since: nil} = clock, _now), do: clock
  def stop(%__MODULE__{} = clock, now), do: %{clock | elapsed_ms: clock.elapsed_ms + now - clock.running_since, running_since: nil}

  def elapsed_ms(%__MODULE__{running_since: nil} = clock, _now), do: clock.elapsed_ms
  def elapsed_ms(%__MODULE__{} = clock, now), do: clock.elapsed_ms + now - clock.running_since

  def running?(%__MODULE__{running_since: since}), do: since != nil
end
