import type { Config } from 'tailwindcss'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: { sans: ['Pretendard', 'Apple SD Gothic Neo', 'Inter', 'sans-serif'] },
      colors: { ink: '#10273f', marine: '#286c91', paper: '#f7f9fa', mist: '#edf4f7' },
      borderRadius: { lg: '0.85rem', xl: '1.15rem', '2xl': '1.5rem' },
    },
  },
  plugins: [],
} satisfies Config
