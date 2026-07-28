import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { AppearancePage } from "./appearance-page"
import type { PresenceClient, PresencePackage } from "./presence-client"

const orb: PresencePackage = {
  manifest: {
    id: "builtin.orb",
    name: "Breathing Orb",
    version: "1.0.0",
    engine: "orb",
    entry: "builtin",
  },
  installPath: null,
  thumbnailPath: null,
  isActive: true,
  isBuiltIn: true,
  rendererAvailable: true,
}

function renderPage(client: PresenceClient) {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <AppearancePage client={client} />
    </QueryClientProvider>,
  )
}

describe("AppearancePage", () => {
  it("shows the current presence", async () => {
    const client = mockClient([orb])
    renderPage(client)
    expect(await screen.findByRole("heading", { name: "Breathing Orb" })).toBeVisible()
    expect(screen.getByText("正在桌面陪伴")).toBeVisible()
    expect(screen.getByRole("button", { name: "导入本地模型" })).toBeVisible()
  })

  it("imports and refreshes the collection", async () => {
    const model: PresencePackage = {
      ...orb,
      manifest: {
        id: "mori.blue",
        name: "Mori",
        version: "1.0.0",
        engine: "live2d",
        entry: "avatar.model3.json",
      },
      isActive: false,
      isBuiltIn: false,
      rendererAvailable: false,
    }
    const list = vi.fn().mockResolvedValueOnce([orb]).mockResolvedValueOnce([orb, model])
    const client = { ...mockClient([orb]), list, importLocal: vi.fn().mockResolvedValue(model) }
    const user = userEvent.setup()
    renderPage(client)
    await screen.findByRole("heading", { name: "Breathing Orb" })
    await user.click(screen.getByRole("button", { name: "导入本地模型" }))
    expect(client.importLocal).toHaveBeenCalledOnce()
    expect(await screen.findByRole("heading", { name: "Mori" })).toBeVisible()
    expect(screen.getByText("渲染器待接入")).toBeVisible()
  })
})

function mockClient(items: PresencePackage[]): PresenceClient {
  return {
    list: vi.fn().mockResolvedValue(items),
    importLocal: vi.fn(),
    download: vi.fn(),
    activate: vi.fn(),
    remove: vi.fn(),
  }
}
