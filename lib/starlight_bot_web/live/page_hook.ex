defmodule StarlightBotWeb.Live.PageHook do
  import Phoenix.Component, only: [assign: 3]

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
    StarlightBotWeb.Live.LuxcavationLive => :luxcavation,
    StarlightBotWeb.Live.RewardsLive => :rewards,
    StarlightBotWeb.Live.MirrorDungeonLive => :mirror_dungeon
  }

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :page, Map.get(@pages, socket.view))}
  end
end
