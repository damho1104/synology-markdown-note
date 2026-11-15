import * as React from 'react'
import { Slot } from '@radix-ui/react-slot'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '../../lib/utils'

const buttonVariants = cva(
  'inline-flex min-h-11 items-center justify-center gap-2 whitespace-nowrap rounded-xl px-5 text-sm font-semibold transition-colors focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-marine/25 disabled:pointer-events-none disabled:opacity-60',
  { variants: { variant: {
    default: 'bg-ink text-white hover:bg-[#244c6e]',
    outline: 'border border-slate-300 bg-white text-ink hover:bg-mist',
  } }, defaultVariants: { variant: 'default' } },
)

export type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> &
  VariantProps<typeof buttonVariants> & { asChild?: boolean }

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, asChild = false, ...props }, ref) => {
    const Component = asChild ? Slot : 'button'
    return <Component ref={ref} className={cn(buttonVariants({ variant, className }))} {...props} />
  },
)
Button.displayName = 'Button'
