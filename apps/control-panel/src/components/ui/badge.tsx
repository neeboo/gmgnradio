import type * as React from "react"
import { cn } from "../../lib/utils"

export function Badge({ className, ...props }: React.ComponentProps<"span">) {
  return (
    <span
      className={cn(
        "inline-flex h-6 items-center rounded-full border border-[#d8d7d1] bg-[#f1f0eb] px-2.5 text-[11px] font-semibold text-[#666a72]",
        className,
      )}
      {...props}
    />
  )
}
