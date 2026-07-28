import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "../../lib/utils"

const variants = cva(
  "inline-flex items-center justify-center gap-2 rounded-full text-sm font-semibold transition-colors outline-none focus-visible:ring-2 focus-visible:ring-[#1859ff]/30 disabled:pointer-events-none disabled:opacity-45",
  {
    variants: {
      variant: {
        default: "bg-[#1859ff] text-white shadow-[0_8px_24px_rgba(24,89,255,.18)] hover:bg-[#0c49dc]",
        outline: "border border-[#d1d0c9] bg-white/75 text-[#17191f] hover:border-[#9eabd2] hover:bg-white",
        ghost: "text-[#5b606b] hover:bg-black/[.045]",
      },
      size: { default: "h-10 px-5", sm: "h-8 px-3 text-xs", icon: "size-9" },
    },
    defaultVariants: { variant: "default", size: "default" },
  },
)

type Props = React.ButtonHTMLAttributes<HTMLButtonElement> &
  VariantProps<typeof variants> & { asChild?: boolean }

export function Button({ className, variant, size, asChild, ...props }: Props) {
  const Comp = asChild ? Slot : "button"
  return <Comp className={cn(variants({ variant, size, className }))} {...props} />
}
