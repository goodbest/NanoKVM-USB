export type Resolution = {
  width: number
  height: number
}

export type VideoFrameRate = 'auto' | 60 | 50 | 30 | 25

export type VideoColor = {
  brightness: number
  contrast: number
  saturation: number
}

export type MediaDevice = {
  videoId: string
  videoName: string
  audioId?: string
  audioName?: string
}
