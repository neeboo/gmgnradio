export type PresenceEngine = "orb" | "live2d"

export interface PresenceManifest {
  id: string
  name: string
  version: string
  engine: PresenceEngine
  entry: string
  thumbnail?: string | null
  author?: string | null
  license?: string | null
}

export interface PresencePackage {
  manifest: PresenceManifest
  installPath: string | null
  thumbnailPath: string | null
  isActive: boolean
  isBuiltIn: boolean
  rendererAvailable: boolean
}

export interface PresenceClient {
  list(): Promise<PresencePackage[]>
  importLocal(): Promise<PresencePackage | null>
  download(url: string): Promise<PresencePackage>
  activate(id: string): Promise<void>
  remove(id: string): Promise<void>
}

type NativeReply = { id: string; result?: unknown; error?: string }
declare global {
  interface Window {
    webkit?: { messageHandlers?: { gmgnRadio?: { postMessage(message: unknown): void } } }
    __gmgnNativeResolve?(reply: NativeReply): void
    __gmgnNativeReject?(reply: NativeReply): void
  }
}

const pending = new Map<
  string,
  { resolve(value: unknown): void; reject(reason: Error): void }
>()
window.__gmgnNativeResolve = ({ id, result }) => {
  pending.get(id)?.resolve(result)
  pending.delete(id)
}
window.__gmgnNativeReject = ({ id, error }) => {
  pending.get(id)?.reject(new Error(error ?? "原生操作失败"))
  pending.delete(id)
}

const previewOrb: PresencePackage = {
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

function invoke<T>(command: string, payload: Record<string, unknown> = {}): Promise<T> {
  const handler = window.webkit?.messageHandlers?.gmgnRadio
  if (!handler) {
    if (command === "presence.list") return Promise.resolve([previewOrb] as T)
    return Promise.reject(new Error("这项操作需要在 gmgn radio 桌面端完成。"))
  }
  const id = crypto.randomUUID()
  return new Promise<T>((resolve, reject) => {
    pending.set(id, { resolve: (value) => resolve(value as T), reject })
    handler.postMessage({ id, command, payload })
  })
}

export const nativePresenceClient: PresenceClient = {
  list: () => invoke("presence.list"),
  importLocal: () => invoke("presence.import"),
  download: (url) => invoke("presence.download", { url }),
  activate: (id) => invoke("presence.activate", { id }),
  remove: (id) => invoke("presence.remove", { id }),
}
