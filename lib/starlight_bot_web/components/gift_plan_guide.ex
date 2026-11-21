defmodule StarlightBotWeb.Components.GiftPlanGuide do
  use Phoenix.Component
  import StarlightBotWeb.Components.Icon, only: [icon: 1]

  def gift_plan_guide(assigns) do
    ~H"""
      <section>
        <p>Define a list of gifts the bot should go for in the shop. The general idea is to set up a bunch of gifts you're interested in, set up some refresh conditions, and the bot will [work on getting gifts] -> [refresh if possible] -> [work on getting gifts] until it's out of refreshes.</p>
        <div class="flex flex-col gap-2 text-xs">
          <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none w-fit">
            <img src="/images/ego_gifts/gift_55.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
            <span class="font-medium w-36 truncate">Thrill</span>
            <span class="join">
              <span class="btn btn-xs join-item btn-secondary">+</span>
              <span class="btn btn-xs join-item btn-outline">++</span>
            </span>
            <span class="btn btn-xs btn-secondary">Buy</span>
            <span class="join">
              <span class="btn btn-xs join-item btn-secondary">Fuse</span>
              <span class="btn btn-xs join-item btn-outline"><.icon name="lucide-settings" class="size-4" /></span>
            </span>
          </div>
          <div class="grid grid-cols-[3rem_1fr] items-baseline gap-x-2 gap-y-2">
            <span class="btn btn-xs btn-secondary pointer-events-none">Buy</span>
            <span>Buy on sight. Won't be sold or fused into a gift.</span>
            <span class="join pointer-events-none"><span class="btn btn-xs join-item btn-secondary">+</span><span class="btn btn-xs join-item btn-outline">++</span></span>
            <span>Uptie. Upgrades the gift once you own it, to + or ++.</span>
            <span class="btn btn-xs btn-secondary pointer-events-none">Fuse</span>
            <span>Fuse for this gift, buying ingredients if necessary. Some gifts need specific ingredients, others just need to combine the right tiers.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-2">Sell</h4>
        <div class="flex flex-col gap-2 text-xs">
          <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none w-fit">
            <img src="/images/ego_gifts/gift_419.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
            <span class="font-medium w-36 truncate">Bongy Plush</span>
            <span class="btn btn-xs btn-error">Sell</span>
          </div>
          <div class="grid grid-cols-[3rem_1fr] items-baseline gap-x-2">
            <span class="btn btn-xs btn-error pointer-events-none">Sell</span>
            <span>Sell this gift from your inventory before doing any buys/fusions/upties.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-2">Required, Optional and Goals</h4>
        <p class="mb-2">Each entry has a dropdown on the left that decides how much the stage cares about it.</p>
        <div class="flex flex-col gap-2 text-xs">
          <div class="flex items-center gap-1 flex-wrap">
            <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
              <span class="text-[11px] font-semibold">Required</span>
              <span class="text-[10px] text-base-content/50">all of 1</span>
            </div>
            <div class="rounded-lg border border-sky-500/50 bg-sky-500/15 px-2 py-1 flex items-center gap-1">
              <span class="text-[11px] font-semibold">A:</span>
              <span class="text-[11px]">at least 1 of 2</span>
            </div>
            <span class="text-base-content/60">Stage header: what must be owned to move on</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 pointer-events-none">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/gift_13.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="truncate font-medium flex-1">Glimpse of Flames</span>
              <span class="join">
                <span class="btn btn-xs join-item btn-secondary">Buy</span>
                <span class="btn btn-xs join-item btn-outline">Sell</span>
              </span>
            </div>
            <span><span class="font-semibold">Required.</span> The stage is not done until you own it.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex items-center gap-2 rounded border border-base-content/10 bg-base-300 px-1 py-1 pointer-events-none" style="background-image: radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px), radial-gradient(color-mix(in oklab, var(--color-base-content) 16%, transparent) 0.9px, transparent 1.2px); background-size: 8px 8px; background-position: -2px -2px, 2px 2px; background-clip: padding-box">
              <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px]">Optional<.icon name="lucide-chevron-down" class="size-3" /></span>
              <img src="/images/ego_gifts/gift_104.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
              <span class="truncate font-medium flex-1">Ardent Flower</span>
              <span class="join">
                <span class="btn btn-xs join-item btn-secondary">Buy</span>
                <span class="btn btn-xs join-item btn-outline">Sell</span>
              </span>
            </div>
            <span><span class="font-semibold">Optional.</span> Progress continues with or without this, but simply having it listed as optional makes the bot refuse to sell or fuse with it. Buy on an optional will buy on sight, just like a required buy.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] gap-2">
            <div class="flex flex-col gap-1">
              <div class="flex items-center gap-2 rounded border border-sky-500/50 bg-sky-500/15 px-1 py-1 pointer-events-none">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-sky-700 bg-sky-600 px-1.5 py-0.5 text-[11px] text-white">Goal A<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_313.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Embers</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              <div class="flex items-center gap-2 rounded border border-sky-500/50 bg-sky-500/15 px-1 py-1 pointer-events-none">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-sky-700 bg-sky-600 px-1.5 py-0.5 text-[11px] text-white">Goal A<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_92.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Charred Disk</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
            </div>
            <span class="self-center"><span class="font-semibold">Goal.</span> Entries sharing a letter count as a group, and the stage needs at least N of them (here 1 of 2). Whichever the bot finds first counts, and it stops chasing the rest once N are owned.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Refresh</h4>
        <p>After doing work in the shop, we try to refresh. The first case whose condition is true runs: Refresh, Keyword (refresh to a chosen affinity), or Leave. With no matching case the bot leaves the shop. Cases apply to every stage.</p>
        <div class="mt-2 flex flex-col gap-1 text-xs">
          <div class="rounded border border-base-300 bg-base-200 px-1 py-1 flex items-center gap-2 pointer-events-none">
            <span class="text-base-content/40 select-none px-1">⠿</span>
            <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0">if</span>
            <span class="btn btn-outline btn-xs bg-base-100 h-6 min-h-6 flex-1 justify-start font-normal normal-case"><span class="text-base-content/50">▸</span>on Stage 1</span>
            <span class="text-[11px] font-semibold text-base-content/70">then</span>
            <span class="join">
              <span class="join-item btn btn-xs">Leave</span>
              <span class="join-item btn btn-xs btn-primary">Refresh</span>
              <span class="join-item btn btn-xs">Keyword</span>
            </span>
            <span class="text-[11px] font-semibold text-base-content/70">up to</span>
            <span class="input input-bordered input-xs w-14 items-center text-base-content/50">∞</span>
            <span class="text-[11px] font-semibold text-base-content/70 whitespace-nowrap">cost after &gt;=</span>
            <span class="input input-bordered input-xs w-16 items-center">250</span>
          </div>
          <div class="rounded border border-dashed border-base-300 px-1 py-1 flex items-center gap-2 pointer-events-none">
            <span class="px-1 invisible">⠿</span>
            <span class="text-[11px] font-semibold text-base-content/70 w-12 shrink-0">else</span>
            <span class="text-[11px] text-base-content/60">leave the shop</span>
          </div>
          <span class="text-base-content/60">While the bot is on Stage 1 it refreshes, as many times as it can afford while keeping at least 250 left. Anywhere else no case matches, so it leaves the shop.</span>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Schedules</h4>
        <p>Entry settings can change by floor. Use [Add Schedule] to customize a gift's Buy, Sell, Fuse and goal settings per floor.</p>
        <div class="mt-2 flex flex-col gap-3 text-xs">
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-secondary">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F1-2.</span> Buy it on the first two floors.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px] text-base-content">Optional<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
                <span class="join">
                  <span class="btn btn-xs join-item btn-outline">Buy</span>
                  <span class="btn btn-xs join-item btn-outline">Sell</span>
                </span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F3-4.</span> Buy is off, so the bot stops buying it here but keeps what it has.</span>
          </div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col pointer-events-none">
              <div class="flex items-end gap-0.5"><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F1-2<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary/40 bg-primary/25">F3-4<.icon name="lucide-chevron-down" class="size-3" /></div><div class="flex items-center gap-0.5 rounded-t-lg border border-b-0 px-2 py-0.5 text-[11px] border-primary bg-primary text-primary-content font-semibold">F5+<.icon name="lucide-chevron-down" class="size-3" /></div><div class="rounded-t-lg border border-b-0 border-dashed border-primary/60 px-2 py-0.5 text-[11px] text-primary">+</div></div>
              <div class="p-1 border-2 border-primary rounded-b-lg rounded-tr-lg">
              <div class="flex items-center gap-2 rounded border border-base-300 bg-base-100 px-1 py-1" style="background-image: repeating-linear-gradient(135deg, color-mix(in oklab, var(--color-base-content) 14%, transparent) 0 4px, transparent 4px 10px)">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-base-300 bg-base-100 px-1.5 py-0.5 text-[11px] text-base-content">Abandon<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_81.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="font-medium w-24 truncate">Grand Welcome</span>
                <span class="text-[11px] font-semibold text-base-content/60">Buys refused from here</span>
              </div>
              </div>
            </div>
            <span><span class="font-semibold">F5+.</span> Abandoned from floor 5, so the bot no longer pursues it and it does not count toward the stage. Can be sold or used for fusion fodder.</span>
          </div>
        </div>
      </section>
      <section>
        <h4 class="font-semibold mb-1">Stages</h4>
        <p>The bot finishes everything in the first stage, then moves to the next. Gifts already kept stay kept, and a gift can appear in several stages, with the later stage's settings applying once the earlier one is done. Any-tier or any-affinity entries don't carry over, while optional gifts do.</p>
        <div class="mt-2 flex flex-col gap-1 text-xs">
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col gap-1 rounded-xl border border-dashed border-base-content/30 p-1.5 pointer-events-none">
              <div class="flex items-stretch gap-2 rounded-xl border border-base-300 bg-base-200/60 p-1">
                <span class="self-center px-1 text-sm font-semibold">Stage 1</span>
                <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
                  <span class="text-[11px] font-semibold">Required</span>
                  <span class="text-[10px] text-base-content/50">all of 1</span>
                </div>
              </div>
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 ml-2">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_13.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Glimpse of Flames</span>
                <span class="btn btn-xs btn-secondary">Buy</span>
              </div>
            </div>
            <span>Worked on first. The bot shops and refreshes until its Required entries and goals are owned.</span>
          </div>
          <div class="flex items-center gap-1 pl-2 text-base-content/60"><.icon name="lucide-arrow-down" class="size-3.5" />once Stage 1 is done</div>
          <div class="grid grid-cols-[22rem_1fr] items-center gap-2">
            <div class="flex flex-col gap-1 rounded-xl border border-dashed border-base-content/30 p-1.5 pointer-events-none">
              <div class="flex items-stretch gap-2 rounded-xl border border-base-300 bg-base-200/60 p-1">
                <span class="self-center px-1 text-sm font-semibold">Stage 2</span>
                <div class="rounded-lg border border-base-content/20 bg-base-content/10 px-2 py-1 flex flex-col justify-center">
                  <span class="text-[11px] font-semibold">Required</span>
                  <span class="text-[10px] text-base-content/50">all of 1</span>
                </div>
              </div>
              <div class="flex items-center gap-2 rounded border border-base-content/20 bg-base-content/10 px-1 py-1 ml-2">
                <span class="flex w-24 shrink-0 items-center justify-between rounded border border-neutral bg-neutral px-1.5 py-0.5 text-[11px] text-neutral-content">Required<.icon name="lucide-chevron-down" class="size-3" /></span>
                <img src="/images/ego_gifts/gift_55.webp" class="w-6 h-6 rounded object-cover shrink-0" draggable="false" />
                <span class="truncate font-medium flex-1">Thrill</span>
                <span class="btn btn-xs btn-secondary">Buy</span>
              </div>
            </div>
            <span>Worked on next. Everything kept in Stage 1 stays kept.</span>
          </div>
          <div class="flex gap-2 pointer-events-none">
            <span class="btn btn-xs btn-outline">+ Add stage</span>
            <span class="btn btn-xs btn-outline">+ Keep shopping</span>
          </div>
        </div>
        <p class="mt-1">Stages are useful if you completely want to change priorities once a set of gifts have been acquired, but if you need more granularity (for example, you only want to prioritize 1 more gift after certain conditions are met) it's recommended to use schedules instead.</p>
      </section>
    """
  end
end
