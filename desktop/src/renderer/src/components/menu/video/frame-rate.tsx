import { ReactElement, useEffect, useState } from 'react'
import { Popover } from 'antd'
import clsx from 'clsx'
import { useAtom } from 'jotai'
import { ActivityIcon } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { videoFrameRateAtom } from '@renderer/jotai/device'
import { camera } from '@renderer/libs/media/camera'
import * as storage from '@renderer/libs/storage'
import type { VideoFrameRate } from '@renderer/types'

const frameRates: VideoFrameRate[] = ['auto', 60, 50, 30, 25]

export const FrameRate = (): ReactElement => {
  const { t } = useTranslation()
  const [videoFrameRate, setVideoFrameRate] = useAtom(videoFrameRateAtom)
  const [isLoading, setIsLoading] = useState(false)

  useEffect(() => {
    const frameRate = storage.getVideoFrameRate()
    if (frameRate) {
      setVideoFrameRate(frameRate)
    }
  }, [setVideoFrameRate])

  async function updateFrameRate(frameRate: VideoFrameRate): Promise<void> {
    if (isLoading || frameRate === videoFrameRate) return

    setIsLoading(true)
    try {
      await camera.updateFrameRate(frameRate)

      const video = document.getElementById('video') as HTMLVideoElement
      if (video) {
        video.srcObject = camera.getStream()
      }

      setVideoFrameRate(frameRate)
      storage.setVideoFrameRate(frameRate)
    } finally {
      setIsLoading(false)
    }
  }

  const content = (
    <>
      {frameRates.map((frameRate) => (
        <div
          key={frameRate}
          className={clsx(
            'flex cursor-pointer items-center space-x-1 rounded px-4 py-1.5 select-none hover:bg-neutral-700/60',
            frameRate === videoFrameRate ? 'text-blue-500' : 'text-white',
            isLoading && 'pointer-events-none opacity-60'
          )}
          onClick={() => updateFrameRate(frameRate)}
        >
          <span className="w-[40px]">{frameRate === 'auto' ? t('video.auto') : frameRate}</span>
          {frameRate !== 'auto' && <span className="text-xs text-neutral-400">fps</span>}
        </div>
      ))}
    </>
  )

  return (
    <Popover content={content} placement="rightTop" arrow={false} align={{ offset: [13, 0] }}>
      <div className="flex h-[30px] cursor-pointer items-center space-x-2 rounded px-3 text-neutral-300 hover:bg-neutral-700/50">
        <ActivityIcon size={16} />
        <span className="text-sm select-none">{t('video.frameRate')}</span>
      </div>
    </Popover>
  )
}
