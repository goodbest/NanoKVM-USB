export type Resolution = {
  width: number;
  height: number;
};

export type Rotation = 0 | 90 | 180 | 270;

export type VideoFrameRate = 'auto' | 60 | 50 | 30 | 25;

export type MediaDevice = {
  videoId: string;
  videoName: string;
  audioId?: string;
  audioName?: string;
};
