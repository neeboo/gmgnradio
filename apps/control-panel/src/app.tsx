import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
} from "@tanstack/react-router"
import { AudioLines, Bot, Mic2, Palette, Radio, Shield } from "lucide-react"
import { AppearancePage } from "./features/presence/appearance-page"

function Shell() {
  return (
    <div className="control-room flex min-h-screen bg-[#f3f2ed] text-[#17191f]">
      <aside className="sticky top-0 flex h-screen w-[226px] shrink-0 flex-col border-r border-[#d8d7d1] bg-[#ebeae4]/80 px-5 py-7">
        <div className="flex items-center gap-3 px-2">
          <div className="grid size-9 place-items-center rounded-full bg-[#1859ff] text-white shadow-[0_7px_18px_rgba(24,89,255,.22)]">
            <Radio className="size-4" />
          </div>
          <div>
            <p className="display-title text-lg leading-none">gmgn radio</p>
            <p className="mt-1 font-mono text-[9px] tracking-[.16em] text-[#888d97]">
              CONTROL ROOM
            </p>
          </div>
        </div>
        <nav className="mt-10 space-y-1" aria-label="设置导航">
          <Nav icon={Palette} label="桌面外观" active />
          <Nav icon={Bot} label="DJ 偏好" />
          <Nav icon={AudioLines} label="播放与音质" />
          <Nav icon={Mic2} label="语音" />
          <Nav icon={Shield} label="隐私" />
        </nav>
        <div className="mt-auto border-t border-[#d2d1cb] px-2 pt-5">
          <div className="flex items-center gap-2 text-[11px] text-[#767b85]">
            <span className="size-1.5 rounded-full bg-[#28a56a]" />
            DJ online
          </div>
          <p className="mt-2 text-[10px] leading-4 text-[#969aa2]">
            原生窗口与管理页保持分离
          </p>
        </div>
      </aside>
      <Outlet />
    </div>
  )
}

function Nav({
  icon: Icon,
  label,
  active = false,
}: {
  icon: typeof Palette
  label: string
  active?: boolean
}) {
  return (
    <div
      className={`flex h-10 items-center gap-3 rounded-xl px-3 text-sm ${
        active ? "bg-white shadow-[0_1px_0_rgba(0,0,0,.04)]" : "text-[#747983]"
      }`}
    >
      <Icon className={active ? "size-4 text-[#1859ff]" : "size-4"} />
      {label}
      {!active && <span className="ml-auto font-mono text-[8px] text-[#a2a6ae]">SOON</span>}
    </div>
  )
}

const rootRoute = createRootRoute({ component: Shell })
const appearanceRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: AppearancePage,
})
export const router = createRouter({ routeTree: rootRoute.addChildren([appearanceRoute]) })

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}
