import { useMemo, useState, type FormEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Box, Check, Download, FolderOpen, LoaderCircle, Radio, Trash2 } from "lucide-react"
import { Badge } from "../../components/ui/badge"
import { Button } from "../../components/ui/button"
import { Input } from "../../components/ui/input"
import {
  nativePresenceClient,
  type PresenceClient,
  type PresencePackage,
} from "./presence-client"

const queryKey = ["presence-packages"] as const

export function AppearancePage({
  client = nativePresenceClient,
}: {
  client?: PresenceClient
}) {
  const queryClient = useQueryClient()
  const [downloadURL, setDownloadURL] = useState("")
  const [message, setMessage] = useState<string | null>(null)
  const packages = useQuery({ queryKey, queryFn: () => client.list() })
  const active = useMemo(
    () => packages.data?.find((item) => item.isActive) ?? packages.data?.[0],
    [packages.data],
  )
  const refresh = () => queryClient.invalidateQueries({ queryKey })
  const importModel = useMutation({
    mutationFn: () => client.importLocal(),
    onSuccess: async (result) => {
      if (result) {
        setMessage(`已安装 ${result.manifest.name}`)
        await refresh()
      }
    },
    onError: (error) => setMessage(error.message),
  })
  const downloadModel = useMutation({
    mutationFn: (url: string) => client.download(url),
    onSuccess: async (result) => {
      setMessage(`已安装 ${result.manifest.name}`)
      setDownloadURL("")
      await refresh()
    },
    onError: (error) => setMessage(error.message),
  })
  const activateModel = useMutation({
    mutationFn: (id: string) => client.activate(id),
    onSuccess: refresh,
    onError: (error) => setMessage(error.message),
  })
  const removeModel = useMutation({
    mutationFn: (id: string) => client.remove(id),
    onSuccess: refresh,
    onError: (error) => setMessage(error.message),
  })

  function submitDownload(event: FormEvent) {
    event.preventDefault()
    if (downloadURL.trim()) downloadModel.mutate(downloadURL.trim())
  }

  return (
    <main className="min-w-0 flex-1 overflow-y-auto px-10 py-8">
      <header className="mb-7 flex items-end justify-between">
        <div>
          <p className="eyebrow">DESKTOP PRESENCE</p>
          <h1 className="display-title mt-2 text-[38px] leading-none">桌面外观</h1>
          <p className="mt-3 max-w-xl text-sm leading-6 text-[#6e737e]">
            DJ 留在桌面上的样子。模型资源保存在本机，不读取对话和音乐记录。
          </p>
        </div>
        <Badge className="mb-1 border-[#b7cafc] bg-[#edf3ff] text-[#1859ff]">
          macOS native
        </Badge>
      </header>

      <section className="hero-panel relative grid min-h-[264px] overflow-hidden rounded-[28px] border border-[#d9d8d2] bg-[#fbfbf8] grid-cols-[1fr_290px]">
        <div className="relative z-10 flex flex-col justify-between p-8">
          <div>
            <div className="mb-4 flex items-center gap-2 text-xs font-semibold tracking-[.08em] text-[#1859ff]">
              <span className="size-2 rounded-full bg-[#1859ff] shadow-[0_0_0_5px_rgba(24,89,255,.11)]" />
              正在桌面陪伴
            </div>
            {active ? (
              <>
                <h2 className="display-title text-4xl">{active.manifest.name}</h2>
                <p className="mt-2 text-sm text-[#737884]">
                  {active.manifest.engine === "orb"
                    ? "原生 Metal · 白色基底 / 蓝色流纹"
                    : `Live2D · ${active.manifest.author ?? "未知作者"}`}
                </p>
              </>
            ) : (
              <LoaderCircle className="size-5 animate-spin text-[#1859ff]" />
            )}
          </div>
          <p className="max-w-sm text-xs leading-5 text-[#858a94]">
            Live2D 接入后，会复用同一组聆听、思考、说话和播放状态。
          </p>
        </div>
        <div className="orb-stage relative min-h-[240px]">
          <div className="presence-orb" aria-label="白底蓝纹呼吸球预览">
            <div className="presence-orb__texture" />
            <div className="presence-orb__shine" />
          </div>
          <span className="absolute bottom-5 right-6 font-mono text-[10px] tracking-[.16em] text-[#9096a3]">
            LIVE / IDLE
          </span>
        </div>
      </section>

      <section className="mt-9">
        <div className="mb-4 flex items-center justify-between">
          <div>
            <h2 className="text-base font-semibold">已安装</h2>
            <p className="mt-1 text-xs text-[#868b95]">{packages.data?.length ?? 0} 个桌面外观</p>
          </div>
          <Button
            variant="outline"
            onClick={() => importModel.mutate()}
            disabled={importModel.isPending}
            aria-label="导入本地模型"
          >
            {importModel.isPending
              ? <LoaderCircle className="size-4 animate-spin" />
              : <FolderOpen className="size-4" />}
            导入本地模型
          </Button>
        </div>
        <div className="grid gap-3">
          {packages.data?.map((item) => (
            <PresenceRow
              key={item.manifest.id}
              item={item}
              onActivate={() => activateModel.mutate(item.manifest.id)}
              onRemove={() => removeModel.mutate(item.manifest.id)}
            />
          ))}
        </div>
      </section>

      <section className="mt-9 border-t border-[#deddd7] pt-7">
        <div className="grid grid-cols-[1fr_1.35fr] gap-5">
          <div>
            <p className="eyebrow">REMOTE PACKAGE</p>
            <h2 className="mt-2 text-base font-semibold">从链接安装</h2>
            <p className="mt-2 max-w-xs text-xs leading-5 text-[#858a94]">
              支持 HTTPS 地址的 .zip 或 .gmgnpet，下载后执行本地校验。
            </p>
          </div>
          <form onSubmit={submitDownload} className="flex items-start gap-2">
            <Input
              aria-label="模型下载地址"
              type="url"
              placeholder="https://example.com/mori.gmgnpet"
              value={downloadURL}
              onChange={(event) => setDownloadURL(event.target.value)}
              className="flex-1"
            />
            <Button type="submit" disabled={!downloadURL.trim() || downloadModel.isPending}>
              <Download className="size-4" />
              安装
            </Button>
          </form>
        </div>
        {message && <p role="status" className="mt-4 text-xs text-[#5e6470]">{message}</p>}
      </section>
    </main>
  )
}

function PresenceRow({
  item,
  onActivate,
  onRemove,
}: {
  item: PresencePackage
  onActivate(): void
  onRemove(): void
}) {
  return (
    <article className="flex min-h-[92px] items-center gap-4 rounded-[20px] border border-[#deddd7] bg-white/55 px-4 py-3 hover:bg-white">
      <div className="grid size-16 shrink-0 place-items-center rounded-2xl border border-[#d9dce8] bg-[#f3f6ff]">
        {item.manifest.engine === "orb"
          ? <div className="mini-orb" />
          : <Box className="size-6 text-[#1859ff]" strokeWidth={1.5} />}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          {item.isActive ? (
            <span className="text-[15px] font-semibold">{item.manifest.name}</span>
          ) : (
            <h3 className="text-[15px] font-semibold">{item.manifest.name}</h3>
          )}
          {item.isActive && (
            <Badge className="border-[#b7cafc] bg-[#edf3ff] text-[#1859ff]">
              <Check className="mr-1 size-3" /> 使用中
            </Badge>
          )}
          {!item.rendererAvailable && <Badge>渲染器待接入</Badge>}
        </div>
        <p className="mt-1.5 text-xs text-[#848995]">
          {item.isBuiltIn ? "gmgn radio 内置 · 随声音状态呼吸" : `v${item.manifest.version}`}
        </p>
      </div>
      {!item.isBuiltIn && (
        <Button variant="ghost" size="icon" aria-label={`删除 ${item.manifest.name}`} onClick={onRemove}>
          <Trash2 className="size-4" />
        </Button>
      )}
      {!item.isActive && (
        <Button
          variant="outline"
          size="sm"
          disabled={!item.rendererAvailable}
          onClick={onActivate}
        >
          使用
        </Button>
      )}
      {item.isBuiltIn && <Radio className="size-4 text-[#a2a6ae]" />}
    </article>
  )
}
