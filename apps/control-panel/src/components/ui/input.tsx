import type * as React from "react"
import { cn } from "../../lib/utils"

export function Input({ className, ...props }: React.ComponentProps<"input">) {
  return (
    <input
      className={cn(
        "h-10 min-w-0 rounded-full border border-[#d1d0c9] bg-white/80 px-4 text-sm outline-none placeholder:text-[#999b9e] focus:border-[#1859ff]/55 focus:ring-2 focus:ring-[#1859ff]/10",
        className,
      )}
      {...props}
    />
  )
}
