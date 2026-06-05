import { atom } from 'jotai'

import { Resolution, VideoColor, VideoFrameRate } from '@renderer/types'

type VideoState = 'disconnected' | 'connecting' | 'connected'
type SerialState = 'notSupported' | 'disconnected' | 'connecting' | 'connected'

export const resolutionAtom = atom<Resolution>({
  width: 1920,
  height: 1080
})

export const videoScaleAtom = atom<number>(1.0)

export const videoFrameRateAtom = atom<VideoFrameRate>(60)

export const videoColorAtom = atom<VideoColor>({
  brightness: 1.01,
  contrast: 1.12,
  saturation: 1.09
})

export const videoDeviceIdAtom = atom('')
export const videoStateAtom = atom<VideoState>('disconnected')

export const serialPortAtom = atom('')
export const serialPortStateAtom = atom<SerialState>('disconnected')
export const baudRateAtom = atom(57600)
