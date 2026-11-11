defmodule StarlightBot.Automation.ActiveSkillsWatch do
  use Agent

  @topic "active_skills"

  def start_link(_opts), do: Agent.start_link(fn -> %{enabled?: false, latest: nil} end, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def unsubscribe, do: Phoenix.PubSub.unsubscribe(StarlightBot.PubSub, @topic)

  def state, do: Agent.get(__MODULE__, & &1)

  def set_enabled(enabled?) do
    Agent.update(__MODULE__, fn state -> %{state | enabled?: enabled?, latest: if(enabled?, do: state.latest)} end)
  end

  def record(frame, tray, detail) do
    at = DateTime.utc_now()
    reading = {frame, tray, detail, at}

    recorded? =
      Agent.get_and_update(__MODULE__, fn
        %{enabled?: true} = state -> {true, %{state | latest: reading}}
        state -> {false, state}
      end)

    if recorded?, do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:active_skills_read, frame, tray, detail, at})
    :ok
  end
end
