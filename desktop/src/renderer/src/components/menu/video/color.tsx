import { ReactElement } from 'react'
import { Button, Popover, Slider } from 'antd'
import { useAtom } from 'jotai'
import { SlidersHorizontalIcon } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { videoColorAtom } from '@renderer/jotai/device'
import * as storage from '@renderer/libs/storage'
import type { VideoColor } from '@renderer/types'

const defaultColor: VideoColor = {
  brightness: 1.01,
  contrast: 1.12,
  saturation: 1.09
}

const rangeExpandPreset: VideoColor = {
  brightness: 1,
  contrast: 1.15,
  saturation: 1.08
}

type ColorControl = {
  key: 'brightness' | 'contrast' | 'saturation'
  label: string
  min: number
  max: number
}

const controls: ColorControl[] = [
  { key: 'brightness', label: 'brightness', min: 0.8, max: 1.25 },
  { key: 'contrast', label: 'contrast', min: 0.8, max: 1.35 },
  { key: 'saturation', label: 'saturation', min: 0.7, max: 1.45 }
]

function formatValue(value: number): string {
  return `${Math.round(value * 100)}%`
}

export const Color = (): ReactElement => {
  const { t } = useTranslation()
  const [videoColor, setVideoColor] = useAtom(videoColorAtom)

  function updateColor(key: ColorControl['key'], value: number): void {
    const next = {
      ...videoColor,
      [key]: Number(value.toFixed(2))
    }

    setVideoColor(next)
    storage.setVideoColor(next)
  }

  function applyColor(color: VideoColor): void {
    setVideoColor(color)
    storage.setVideoColor(color)
  }

  const content = (
    <div className="w-[260px] space-y-3 p-1 text-neutral-100">
      {controls.map((item) => (
        <div key={item.key} className="space-y-1">
          <div className="flex items-center justify-between text-xs">
            <span>{t(`video.colorControls.${item.label}`)}</span>
            <span className="text-neutral-400">{formatValue(videoColor[item.key])}</span>
          </div>
          <Slider
            min={item.min}
            max={item.max}
            step={0.01}
            value={videoColor[item.key]}
            tooltip={{ formatter: (value) => (value ? formatValue(value) : '0%') }}
            onChange={(value) => updateColor(item.key, value)}
          />
        </div>
      ))}

      <div className="flex gap-2 pt-1">
        <Button size="small" className="flex-1" onClick={() => applyColor(defaultColor)}>
          {t('video.colorControls.reset')}
        </Button>
        <Button
          size="small"
          type="primary"
          className="flex-1"
          onClick={() => applyColor(rangeExpandPreset)}
        >
          {t('video.colorControls.rangeExpand')}
        </Button>
      </div>
    </div>
  )

  return (
    <Popover content={content} placement="rightTop" arrow={false} align={{ offset: [13, 0] }}>
      <div className="flex h-[30px] cursor-pointer items-center space-x-2 rounded px-3 text-neutral-300 hover:bg-neutral-700/50">
        <SlidersHorizontalIcon size={16} />
        <span className="text-sm select-none">{t('video.color')}</span>
      </div>
    </Popover>
  )
}
