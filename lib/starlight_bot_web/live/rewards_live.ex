defmodule StarlightBotWeb.Live.RewardsLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Automation.Scripts
  alias StarlightBot.Automation.Scripts.ClaimRewards
  alias StarlightBot.Navigation.Navigator

  @countdown_secs 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Navigator.subscribe()
    nav = Navigator.status()

    {:ok,
     socket
     |> assign(:phase, nav.phase)
     |> assign(:reward_type, "cabinet_reward")
     |> assign(:action, "claim")
     |> assign(:weekly_bonus, true)
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("select_reward_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :reward_type, type)}
  end

  @impl true
  def handle_event("run", %{"action" => action} = params, socket) do
    Code.ensure_loaded(ClaimRewards)
    config = %{action: String.to_existing_atom(action), weekly_bonus?: Map.get(params, "weekly_bonus") == "true"}
    {:noreply, start_countdown(socket, {:claim_rewards, config})}
  end

  @impl true
  def handle_event("run_script", %{"script" => script}, socket) do
    {:noreply, start_countdown(socket, {:run_script, String.to_existing_atom(script)})}
  end

  @impl true
  def handle_event("update_form", %{"action" => action} = params, socket) do
    {:noreply,
     socket
     |> assign(:action, action)
     |> assign(:weekly_bonus, Map.get(params, "weekly_bonus") == "true")}
  end

  @impl true
  def handle_event("cancel_pending", _, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("cancel", _, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1, pending_action: action}} = socket) do
    run_pending_action(action)
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply, socket |> assign(:phase, nav.phase)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:claim_rewards, config}), do: Navigator.claim_rewards(config)
  defp run_pending_action({:run_script, name}), do: Navigator.run_script(name)

  def pending_action_label({:claim_rewards, %{action: action}}), do: "rewards: #{action}"

  def pending_action_label({:run_script, name}) do
    case Scripts.find(name) do
      %{label: label} -> label
      nil -> "#{name}"
    end
  end

  def phase_label(:idle), do: nil
  def phase_label(:localizing), do: "Localizing…"
  def phase_label(:running), do: "Running…"
  def phase_label(:paused), do: "Paused"

end
