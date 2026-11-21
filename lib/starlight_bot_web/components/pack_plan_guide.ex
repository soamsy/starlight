defmodule StarlightBotWeb.Components.PackPlanGuide do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]

  def pack_plan_guide(assigns) do
    ~H"""
      <section>
        <h4 class="font-semibold mb-2">Theme pack priority</h4>
        <div class="grid grid-cols-4 gap-2 text-xs">
          <div class="flex flex-col gap-1 rounded-lg border border-warning/50 bg-warning/15 p-2">
            <span class="font-semibold text-warning"><.icon name="lucide-filled-star" class="size-3" /> Favorite</span>
            <span>1st pick. Take if seen. Refresh otherwise.</span>
            <span class="mt-auto text-base-content/60">Click the star on a floor</span>
          </div>
          <div class="flex flex-col gap-1 rounded-lg border border-success/50 bg-success/15 p-2">
            <span class="font-semibold text-success">Hunt</span>
            <span>2nd pick. Backup once refreshes and search run out. Treated as Favorites if there are no Favorites.</span>
            <span class="mt-auto text-base-content/60">Click a floor</span>
          </div>
          <div class="flex flex-col gap-1 rounded-lg border border-base-300 bg-base-200 p-2">
            <span class="font-semibold">Acceptable</span>
            <span>Fallback after Hunt.</span>
            <span class="mt-auto text-base-content/60">Default</span>
          </div>
          <div class="flex flex-col gap-1 rounded-lg border border-error/50 bg-error/15 p-2">
            <span class="font-semibold text-error">Banned</span>
            <span>Avoid. Take only when every pack shown is banned.</span>
            <span class="mt-auto text-base-content/60">Right click a floor</span>
          </div>
        </div>
        <p class="mt-2">To reorder a floor's list, click its pack, then drag the rows in the dropdown.</p>
        <div class="mt-2 flex items-start gap-2">
          <span class="shrink-0 pt-0.5 text-base-content/60">&rarr;</span>
          <div class="relative w-56 shrink-0">
            <span class="flex items-center gap-1 rounded-full border border-success/60 bg-success/10 pl-0.5 pr-1 py-0.5 text-[10px] shadow-sm ring-2 ring-primary/60">
              <img src="/images/theme_packs/thm_3.webp" class="w-4 h-4 rounded-full object-cover shrink-0" draggable="false" />
              <span class="truncate font-medium flex-1">Flat-broke Gamblers</span>
              <span class="shrink-0 rounded-full bg-base-content/10 px-1 text-[9px] text-base-content/60">+2</span>
              <.icon name="lucide-chevron-down" class="size-3 shrink-0 rotate-180 text-base-content/50" />
            </span>
            <div class="relative mt-2 flex flex-col gap-0.5 rounded-lg border border-base-content/30 bg-base-200 p-1.5 shadow-2xl">
              <span class="absolute -top-[5px] left-5 h-2 w-2 rotate-45 border-l border-t border-base-content/30 bg-base-200"></span>
              <span class="px-1 text-[9px] uppercase tracking-wide text-base-content/50">Hunt</span>
              <div class="flex items-center gap-1 rounded-full border border-success/60 bg-success/30 pl-1 pr-1 py-0.5 text-[10px]" style="opacity: 1">
                <span class="text-base-content/50">⠿</span>
                <img src="/images/theme_packs/thm_3.webp" class="w-4 h-4 rounded-full object-cover shrink-0" draggable="false" />
                <span class="truncate flex-1">Flat-broke Gamblers</span>
                <span class="shrink-0 text-[9px] text-base-content/60">1</span>
                <span class="shrink-0 leading-none text-base-content/50"><.icon name="lucide-x" class="size-3.5" /></span>
              </div>
              <div class="flex items-center gap-1 rounded-full border border-success/60 bg-success/30 pl-1 pr-1 py-0.5 text-[10px]" style="opacity: 0.75">
                <span class="text-base-content/50">⠿</span>
                <img src="/images/theme_packs/thm_12.webp" class="w-4 h-4 rounded-full object-cover shrink-0" draggable="false" />
                <span class="truncate flex-1">The Unchanging</span>
                <span class="shrink-0 text-[9px] text-base-content/60">2</span>
                <span class="shrink-0 leading-none text-base-content/50"><.icon name="lucide-x" class="size-3.5" /></span>
              </div>
              <div class="flex items-center gap-1 rounded-full border border-success/60 bg-success/30 pl-1 pr-1 py-0.5 text-[10px]" style="opacity: 0.55">
                <span class="text-base-content/50">⠿</span>
                <img src="/images/theme_packs/thm_10.webp" class="w-4 h-4 rounded-full object-cover shrink-0" draggable="false" />
                <span class="truncate flex-1">Falling Flowers</span>
                <span class="shrink-0 text-[9px] text-base-content/60">3</span>
                <span class="shrink-0 leading-none text-base-content/50"><.icon name="lucide-x" class="size-3.5" /></span>
              </div>
            </div>
          </div>
          <span class="pt-6 text-base-content/70">Top of the list is picked first. If we're looking for favorites, and we only see one favorite that's technically low in the list, we'll take that.</span>
        </div>
      </section>
      <section>
        <p>When <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] btn-error pointer-events-none">search</span> is on, never resort to backups. Find the top pack once refreshes are exhausted. Costs <span class="inline-flex items-center gap-1 rounded-full bg-base-300 px-1.5 py-0.5 text-[10px] font-medium align-middle"><img src="/images/icons/starlight.webp" alt="Starlight" class="h-3 w-3" />starlight</span> if used.</p>
      </section>
      <section>
        <div class="mt-2 grid grid-cols-6 gap-1 text-xs">
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1">
              <span class="text-[11px] font-semibold text-base-content/70">F1</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] pointer-events-none btn-ghost border-base-300">go hard</span>
            </div>
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1">
              <span class="text-[11px] font-semibold text-base-content/70">F2</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] pointer-events-none btn-ghost border-base-300">go hard</span>
            </div>
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1">
              <span class="text-[11px] font-semibold text-base-content/70">F3</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] pointer-events-none btn-ghost border-base-300">go hard</span>
            </div>
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1 bg-warning/15">
              <span class="text-[11px] font-semibold text-base-content/70">F4</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] pointer-events-none btn-warning">go hard</span>
            </div>
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1 bg-warning/15">
              <span class="text-[11px] font-semibold text-base-content/70">F5</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] pointer-events-none btn-ghost border-base-300">go hard</span>
            </div>
            <div class="flex flex-col items-center gap-1 rounded-t px-1 py-1 bg-warning/15">
              <span class="text-[11px] font-semibold text-base-content/70">F6</span>
              <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] btn-ghost border-base-300">go extreme</span>
            </div>
        </div>
        <div class="mt-2 flex flex-col gap-1">
          <p><span class="font-medium">Hard</span>: <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] btn-warning pointer-events-none">go hard</span> on a floor makes it and everything after hard. Normal and hard have different theme packs, so priorities on one don't affect the other.</p>
          <p><span class="font-medium">Extreme</span>: <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] btn-ghost border-base-300 pointer-events-none">go extreme</span> on F6 continues into F6-15 after the F5 boss. Makes F1 <span class="btn btn-xs h-4 min-h-0 px-1 text-[9px] btn-warning pointer-events-none">go hard</span>.</p>
        </div>
      </section>
    """
  end
end
