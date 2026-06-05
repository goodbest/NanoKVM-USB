import { ReactElement, ReactNode, useEffect, useRef, useState } from 'react'
import { Button, Collapse, message, Modal } from 'antd'
import { useAtomValue } from 'jotai'
import { BugIcon, CopyIcon } from 'lucide-react'

import { IpcEvents } from '@common/ipc-events'
import {
  resolutionAtom,
  serialPortStateAtom,
  videoColorAtom,
  videoFrameRateAtom
} from '@renderer/jotai/device'
import { mouseModeAtom } from '@renderer/jotai/mouse'
import { getRuntimeDiagnostics } from '@renderer/libs/diagnostics/runtime'
import { camera } from '@renderer/libs/media/camera'

type SerialInfo = {
  chipVersion: string
  isConnected: boolean
  numLock: boolean
  capsLock: boolean
  scrollLock: boolean
  updatedAt: string
  error?: string
}

type PlaybackFrameState = {
  frames: number
  callbackFrames: number
  time: number
}

type BrowserSnapshot = {
  collectedAt: string
  requested: Record<string, unknown>
  browser: Record<string, unknown>
  video: Record<string, unknown>
  track: Record<string, unknown>
  playback: Record<string, unknown>
  input: Record<string, unknown>
}

type VideoWithFrameCallback = HTMLVideoElement & {
  requestVideoFrameCallback?: (callback: (now: number, metadata: unknown) => void) => number
  cancelVideoFrameCallback?: (handle: number) => void
}

const jsonIndent = 2

function formatDate(): string {
  return new Date().toISOString()
}

function getTrackSnapshot(track: MediaStreamTrack | undefined): Record<string, unknown> {
  if (!track) {
    return {
      state: 'unavailable'
    }
  }

  let capabilities: Record<string, unknown> | string = 'unavailable'
  try {
    capabilities = track.getCapabilities() as unknown as Record<string, unknown>
  } catch (err) {
    capabilities = err instanceof Error ? err.message : String(err)
  }

  return {
    label: track.label,
    id: track.id,
    kind: track.kind,
    enabled: track.enabled,
    muted: track.muted,
    readyState: track.readyState,
    settings: track.getSettings(),
    constraints: track.getConstraints(),
    capabilities
  }
}

function getPlaybackQuality(video: HTMLVideoElement | null): VideoPlaybackQuality | null {
  if (!video || typeof video.getVideoPlaybackQuality !== 'function') {
    return null
  }

  return video.getVideoPlaybackQuality()
}

function JsonBlock({ value }: { value: unknown }): ReactElement {
  return (
    <pre className="max-h-[220px] overflow-auto rounded bg-neutral-950 p-3 text-xs leading-5 text-neutral-200">
      {JSON.stringify(value, null, jsonIndent)}
    </pre>
  )
}

function hasValue(value: unknown): boolean {
  return (
    value !== undefined &&
    value !== null &&
    value !== '' &&
    value !== 'unavailable' &&
    !(typeof value === 'number' && !Number.isFinite(value))
  )
}

function formatValue(value: unknown): string {
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  return String(value)
}

function formatDimensions(width: unknown, height: unknown): string | undefined {
  const w = Number(width)
  const h = Number(height)
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return
  return `${w}x${h}`
}

function formatTrack(settings: MediaTrackSettings | undefined): string | undefined {
  if (!settings) return
  const dimensions = formatDimensions(settings.width, settings.height)
  const fps = Number(settings.frameRate)
  if (!dimensions && !Number.isFinite(fps)) return
  return `${dimensions || 'Unknown mode'}${Number.isFinite(fps) ? ` @ ${fps} fps` : ''}`
}

function formatDroppedFrames(frames: unknown, ratio: unknown): string | undefined {
  const count = Number(frames)
  if (!Number.isFinite(count)) return
  const droppedRatio = Number(ratio)
  return Number.isFinite(droppedRatio)
    ? `${count} (${(droppedRatio * 100).toFixed(3)}%)`
    : String(count)
}

function formatSerialLatency(average: unknown, max: unknown): string | undefined {
  const averageMs = Number(average)
  const maxMs = Number(max)
  if (!Number.isFinite(averageMs) || !Number.isFinite(maxMs)) return
  return `${averageMs.toFixed(2)} ms avg / ${maxMs.toFixed(2)} ms max`
}

function Field({ label, value }: { label: string; value: unknown }): ReactElement | null {
  if (!hasValue(value)) return null

  return (
    <div className="flex min-h-[24px] items-start justify-between gap-4 text-sm">
      <span className="shrink-0 text-neutral-400">{label}</span>
      <span className="text-right break-all text-neutral-100">{formatValue(value)}</span>
    </div>
  )
}

function Section({ title, children }: { title: string; children: ReactNode }): ReactElement {
  return (
    <section className="space-y-2">
      <div className="text-sm font-semibold text-white">{title}</div>
      <div className="space-y-1 rounded border border-neutral-700 bg-neutral-900/70 p-3">
        {children}
      </div>
    </section>
  )
}

export const Debug = (): ReactElement => {
  const resolution = useAtomValue(resolutionAtom)
  const videoFrameRate = useAtomValue(videoFrameRateAtom)
  const videoColor = useAtomValue(videoColorAtom)
  const serialPortState = useAtomValue(serialPortStateAtom)
  const mouseMode = useAtomValue(mouseModeAtom)
  const [isOpen, setIsOpen] = useState(false)
  const [snapshot, setSnapshot] = useState<BrowserSnapshot | null>(null)
  const [serialInfo, setSerialInfo] = useState<SerialInfo | null>(null)
  const [isCopying, setIsCopying] = useState(false)
  const [messageApi, contextHolder] = message.useMessage()

  const callbackFrameCountRef = useRef(0)
  const lastFrameStateRef = useRef<PlaybackFrameState>({
    frames: 0,
    callbackFrames: 0,
    time: performance.now()
  })

  const trackSettings = snapshot?.track.settings as MediaTrackSettings | undefined
  const runtimeMetrics = snapshot?.input.runtime as
    | ReturnType<typeof getRuntimeDiagnostics>
    | undefined
  const negotiatedTrack = formatTrack(trackSettings)
  const droppedFrames = formatDroppedFrames(
    snapshot?.playback.droppedVideoFrames,
    snapshot?.playback.droppedFrameRatio
  )
  const serialLatency = formatSerialLatency(
    runtimeMetrics?.serial.writeCount ? runtimeMetrics.serial.averageWriteMs : undefined,
    runtimeMetrics?.serial.writeCount ? runtimeMetrics.serial.maxWriteMs : undefined
  )
  const locks = serialInfo
    ? `Num ${serialInfo.numLock ? 'on' : 'off'} / Caps ${
        serialInfo.capsLock ? 'on' : 'off'
      } / Scroll ${serialInfo.scrollLock ? 'on' : 'off'}`
    : undefined

  useEffect(() => {
    if (!isOpen) return

    const video = document.getElementById('video') as VideoWithFrameCallback | null
    if (!video?.requestVideoFrameCallback) return

    let frameCallbackId = 0
    let isActive = true
    const onFrame = (): void => {
      callbackFrameCountRef.current += 1
      if (isActive) {
        frameCallbackId = video.requestVideoFrameCallback?.(onFrame) || 0
      }
    }

    frameCallbackId = video.requestVideoFrameCallback(onFrame)

    return () => {
      isActive = false
      if (frameCallbackId && video.cancelVideoFrameCallback) {
        video.cancelVideoFrameCallback(frameCallbackId)
      }
    }
  }, [isOpen])

  useEffect(() => {
    if (!isOpen) return

    collectSnapshot()
    const timer = window.setInterval(collectSnapshot, 1000)
    return () => window.clearInterval(timer)
    // collectSnapshot reads the same source atoms listed below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, resolution, videoFrameRate, videoColor, mouseMode, serialPortState])

  useEffect(() => {
    if (!isOpen || serialPortState !== 'connected') return

    let isActive = true
    const refresh = async (): Promise<void> => {
      const info = (await window.electron.ipcRenderer.invoke(IpcEvents.GET_DEVICE_INFO)) as Record<
        string,
        unknown
      >

      if (!isActive) return

      setSerialInfo({
        chipVersion: String(info.chipVersion || ''),
        isConnected: Boolean(info.isConnected),
        numLock: Boolean(info.numLock),
        capsLock: Boolean(info.capsLock),
        scrollLock: Boolean(info.scrollLock),
        updatedAt: formatDate(),
        error: info.error ? String(info.error) : undefined
      })
    }

    refresh()
    const timer = window.setInterval(refresh, 2500)
    return () => {
      isActive = false
      window.clearInterval(timer)
    }
  }, [isOpen, serialPortState])

  function collectSnapshot(): void {
    const video = document.getElementById('video') as HTMLVideoElement | null
    const track = camera.getStream()?.getVideoTracks()[0]
    const quality = getPlaybackQuality(video)
    const currentTime = performance.now()
    const currentFrames = quality?.totalVideoFrames || 0
    const frameDelta = currentFrames - lastFrameStateRef.current.frames
    const callbackDelta = callbackFrameCountRef.current - lastFrameStateRef.current.callbackFrames
    const elapsedSeconds = Math.max((currentTime - lastFrameStateRef.current.time) / 1000, 0.001)
    const actualFps = frameDelta > 0 ? frameDelta / elapsedSeconds : 0
    const callbackFps = callbackDelta > 0 ? callbackDelta / elapsedSeconds : 0

    lastFrameStateRef.current = {
      frames: currentFrames,
      callbackFrames: callbackFrameCountRef.current,
      time: currentTime
    }

    setSnapshot({
      collectedAt: formatDate(),
      requested: {
        width: resolution.width,
        height: resolution.height,
        frameRate: videoFrameRate,
        color: videoColor
      },
      browser: {
        userAgent: navigator.userAgent,
        platform: navigator.platform,
        language: navigator.language,
        devicePixelRatio: window.devicePixelRatio,
        screen: {
          width: window.screen.width,
          height: window.screen.height,
          colorDepth: window.screen.colorDepth
        }
      },
      video: {
        elementWidth: video?.clientWidth,
        elementHeight: video?.clientHeight,
        videoWidth: video?.videoWidth,
        videoHeight: video?.videoHeight,
        paused: video?.paused,
        readyState: video?.readyState,
        srcObjectTracks: camera
          .getStream()
          ?.getTracks()
          .map((item) => ({
            kind: item.kind,
            label: item.label,
            readyState: item.readyState
          }))
      },
      track: getTrackSnapshot(track),
      playback: {
        actualFps: Number(actualFps.toFixed(2)),
        callbackFps: Number(callbackFps.toFixed(2)),
        totalVideoFrames: quality?.totalVideoFrames,
        droppedVideoFrames: quality?.droppedVideoFrames,
        droppedFrameRatio:
          quality && quality.totalVideoFrames > 0
            ? Number((quality.droppedVideoFrames / quality.totalVideoFrames).toFixed(4))
            : 0,
        requestVideoFrameCallbackFrames: callbackFrameCountRef.current
      },
      input: {
        mouseMode,
        pointerLockElement: document.pointerLockElement?.id || '',
        serialPortState,
        runtime: getRuntimeDiagnostics()
      }
    })
  }

  function buildExportData(): Record<string, unknown> {
    return {
      schema: 'nanokvm-usb-desktop-runtime/v1',
      collectedAt: formatDate(),
      serialInfo,
      runtime: snapshot
    }
  }

  async function copyDiagnostics(): Promise<void> {
    setIsCopying(true)
    try {
      await navigator.clipboard.writeText(JSON.stringify(buildExportData(), null, jsonIndent))
      messageApi.success('Diagnostics copied')
    } catch (err) {
      messageApi.error(err instanceof Error ? err.message : 'Failed to copy diagnostics')
    } finally {
      setIsCopying(false)
    }
  }

  return (
    <>
      {contextHolder}
      <div
        className="flex h-[28px] cursor-pointer items-center justify-center rounded px-2 text-white hover:bg-neutral-700/70"
        onClick={() => setIsOpen(true)}
      >
        <BugIcon size={18} />
      </div>

      <Modal
        open={isOpen}
        width={840}
        title="Diagnostics"
        footer={null}
        onCancel={() => setIsOpen(false)}
      >
        <div className="space-y-4 bg-neutral-950 text-neutral-100">
          <div className="flex flex-wrap items-center gap-2">
            <Button
              type="primary"
              icon={<CopyIcon size={14} />}
              loading={isCopying}
              onClick={copyDiagnostics}
            >
              Copy diagnostics JSON
            </Button>
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Section title="Video">
              <Field label="Negotiated mode" value={negotiatedTrack} />
              <Field label="Actual fps" value={snapshot?.playback.actualFps} />
              <Field label="Dropped frames" value={droppedFrames} />
              <Field
                label="Display correction"
                value={`${Math.round(videoColor.brightness * 100)} / ${Math.round(
                  videoColor.contrast * 100
                )} / ${Math.round(videoColor.saturation * 100)}`}
              />
            </Section>

            <Section title="Input latency">
              <Field label="Mouse mode" value={mouseMode} />
              <Field
                label="Mouse events / reports"
                value={
                  runtimeMetrics
                    ? `${runtimeMetrics.mouse.eventsPerSecond} / ${runtimeMetrics.mouse.reportsPerSecond} per second`
                    : undefined
                }
              />
              <Field label="Serial state" value={serialPortState} />
              <Field label="Serial write latency" value={serialLatency} />
              <Field
                label="Serial errors"
                value={
                  runtimeMetrics?.serial.errorCount ? runtimeMetrics.serial.errorCount : undefined
                }
              />
            </Section>

            <Section title="Device">
              <Field label="Chip version" value={serialInfo?.chipVersion} />
              <Field label="Target connected" value={serialInfo?.isConnected} />
              <Field label="Keyboard locks" value={locks} />
              <Field label="Error" value={serialInfo?.error} />
            </Section>
          </div>

          <Collapse
            ghost
            items={[
              {
                key: 'track',
                label: 'Advanced track details',
                children: <JsonBlock value={snapshot?.track || { state: 'unavailable' }} />
              }
            ]}
          />
        </div>
      </Modal>
    </>
  )
}
