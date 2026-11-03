defmodule StarlightBotWeb.Router do
  use StarlightBotWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StarlightBotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", StarlightBotWeb do
    pipe_through :browser

    live_session :default, on_mount: StarlightBotWeb.Live.PageHook do
      live "/", Live.MirrorDungeonLive
      live "/hooks", Live.HookEditorLive
      live "/screenshots", Live.ScreenshotViewerLive
      live "/battle", Live.BattleInspectorLive
      live "/battle/history", Live.BattleHistoryLive
      live "/events", Live.EventInspectorLive
      live "/dungeon", Live.DungeonInspectorLive
      live "/gift-inspector", Live.GiftInspectorLive
      live "/theme-packs", Live.ThemePackInspectorLive
      live "/transitions", Live.TransitionsLive
      live "/teams", Live.TeamEditorLive
      live "/luxcavation", Live.LuxcavationLive
      live "/mirror-dungeon", Live.MirrorDungeonLive
      live "/shop-runner", Live.ShopRunnerLive
      live "/rewards", Live.RewardsLive
      live "/log", Live.LogLive
      live "/linux-checks", Live.LinuxChecksLive
    end
  end

  scope "/", StarlightBotWeb do
    get "/hooks/:name/thumb.png", HookThumbController, :show
    get "/stream/frame.jpg", GameFrameController, :show
    get "/screenshots/frame/:session_id/:frame_id", ScreenshotFrameController, :show
  end

  if Mix.env() == :dev do
    pipeline :dev_log do
      plug :accepts, ["json"]
    end

    scope "/dev", StarlightBotWeb do
      pipe_through :dev_log
      post "/js-log", DevLogController, :log
    end
  end
end
