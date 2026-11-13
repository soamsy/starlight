defmodule StarlightBotWeb.Live.PrepareLineupsLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.Navigation.Navigator

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event("prepare_lineups", _params, socket) do
    if idle?(socket), do: Navigator.prepare_lineups()
    {:noreply, socket}
  end

  def handle_event("survey_team_hooks", _params, socket) do
    if idle?(socket), do: Navigator.survey_team_hooks()
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  defp idle?(socket), do: socket.assigns[:run_phase] in [nil, :idle]

  def busy_label(:prepare_lineups), do: "Preparing lineups"
  def busy_label(:team_survey), do: "Surveying team hooks"
  def busy_label(_), do: "Another run is in progress"
end
