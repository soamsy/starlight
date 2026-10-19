defmodule StarlightBotWeb.Live.PageHook do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias StarlightBot.Vision.Capture

  @pages %{
    StarlightBotWeb.Live.HookEditorLive => :hooks,
    StarlightBotWeb.Live.ScreenshotViewerLive => :screenshots,
    StarlightBotWeb.Live.BattleInspectorLive => :battle,
    StarlightBotWeb.Live.DungeonInspectorLive => :dungeon,
    StarlightBotWeb.Live.GiftInspectorLive => :gift_inspector,
    StarlightBotWeb.Live.ThemePackInspectorLive => :theme_packs,
    StarlightBotWeb.Live.EventInspectorLive => :events,
    StarlightBotWeb.Live.TransitionsLive => :transitions,
    StarlightBotWeb.Live.TeamEditorLive => :teams,
    StarlightBotWeb.Live.ThemePackPlanEditorLive => :theme_pack_plans,
    StarlightBotWeb.Live.GiftPlanEditorLive => :gift_plans,
    StarlightBotWeb.Live.BattleStrategyEditorLive => :battle_strategies,
    StarlightBotWeb.Live.LuxcavationLive => :luxcavation,
    StarlightBotWeb.Live.RewardsLive => :rewards,
    StarlightBotWeb.Live.MirrorDungeonLive => :mirror_dungeon,
    StarlightBotWeb.Live.ShopRunnerLive => :shop_runner,
    StarlightBotWeb.Live.LogLive => :log
  }

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:page, Map.get(@pages, socket.view))
      |> assign(:game_window_rect, nil)

    if connected?(socket) and GenServer.whereis(Capture) do
      Capture.subscribe()

      socket =
        socket
        |> assign(:game_window_rect, Capture.window_rect())
        |> attach_hook(:game_window_rect, :handle_info, &handle_window_rect/2)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_window_rect({:window_rect, rect}, socket),
    do: {:halt, assign(socket, :game_window_rect, rect)}

  defp handle_window_rect(_msg, socket), do: {:cont, socket}
end
