import { ReactElement, useEffect, useState } from 'react'
import { Result, Spin } from 'antd'
import clsx from 'clsx'
import { useAtomValue, useSetAtom } from 'jotai'
import { useTranslation } from 'react-i18next'
import { useMediaQuery } from 'react-responsive'

import { IpcEvents } from '@common/ipc-events'
import { Device } from '@renderer/components/device'
import { Keyboard } from '@renderer/components/keyboard'
import { Menu } from '@renderer/components/menu'
import { Mouse } from '@renderer/components/mouse'
import { VirtualKeyboard } from '@renderer/components/virtual-keyboard'
import {
  resolutionAtom,
  serialPortStateAtom,
  videoColorAtom,
  videoFrameRateAtom,
  videoScaleAtom,
  videoStateAtom
} from '@renderer/jotai/device'
import { isKeyboardEnableAtom } from '@renderer/jotai/keyboard'
import { mouseModeAtom, mouseStyleAtom } from '@renderer/jotai/mouse'
import { camera } from '@renderer/libs/media/camera'
import { requestCameraPermission } from '@renderer/libs/media/permission'
import { getVideoColor, getVideoFrameRate, getVideoResolution } from '@renderer/libs/storage'

type State = 'loading' | 'success' | 'failed'

const App = (): ReactElement => {
  const { t } = useTranslation()
  const isBigScreen = useMediaQuery({ minWidth: 850 })

  const videoScale = useAtomValue(videoScaleAtom)
  const videoColor = useAtomValue(videoColorAtom)
  const videoState = useAtomValue(videoStateAtom)
  const serialPortState = useAtomValue(serialPortStateAtom)
  const mouseMode = useAtomValue(mouseModeAtom)
  const mouseStyle = useAtomValue(mouseStyleAtom)
  const isKeyboardEnable = useAtomValue(isKeyboardEnableAtom)
  const setResolution = useSetAtom(resolutionAtom)
  const setVideoColor = useSetAtom(videoColorAtom)
  const setVideoFrameRate = useSetAtom(videoFrameRateAtom)

  const [state, setState] = useState<State>('loading')
  const colorFilter = [
    `brightness(${videoColor.brightness})`,
    `contrast(${videoColor.contrast})`,
    `saturate(${videoColor.saturation})`
  ].join(' ')

  useEffect(() => {
    const resolution = getVideoResolution()
    if (resolution) {
      setResolution(resolution)
    }
    const frameRate = getVideoFrameRate()
    if (frameRate) {
      setVideoFrameRate(frameRate)
    }
    const color = getVideoColor()
    if (color) {
      setVideoColor(color)
    }

    async function requestMediaPermissions(): Promise<void> {
      try {
        const granted = await requestCameraPermission(resolution)
        setState(granted ? 'success' : 'failed')
      } catch (err) {
        if (
          err instanceof Error &&
          ['NotAllowedError', 'PermissionDeniedError'].includes(err.name)
        ) {
          setState('failed')
        } else {
          setState('success')
        }
      }
    }

    requestMediaPermissions()

    return (): void => {
      camera.close()
      window.electron.ipcRenderer.invoke(IpcEvents.CLOSE_SERIAL_PORT)
    }
  }, [setResolution, setVideoColor, setVideoFrameRate])

  if (state === 'loading') {
    return <Spin size="large" spinning={true} tip={t('camera.tip')} fullscreen />
  }

  if (state === 'failed') {
    return (
      <Result
        status="info"
        title={t('camera.denied')}
        extra={[
          <h2 key="desc" className="text-xl text-white">
            {t('camera.authorize')}
          </h2>
        ]}
      />
    )
  }

  return (
    <>
      <Device />

      {videoState === 'connected' && serialPortState === 'connected' && (
        <>
          <Menu />
          <Mouse />
          {isKeyboardEnable && <Keyboard />}
        </>
      )}

      <video
        id="video"
        className={clsx(
          'block max-h-full min-h-[480px] max-w-full min-w-[640px] origin-center object-scale-down select-none',
          videoState === 'connected' ? 'opacity-100' : 'opacity-0',
          mouseMode === 'relative' ? 'cursor-none' : mouseStyle
        )}
        style={{
          filter: colorFilter,
          transform: `scale(${videoScale})`
        }}
        autoPlay
        playsInline
      />

      <VirtualKeyboard isBigScreen={isBigScreen} />
    </>
  )
}

export default App
