import { checkPermission } from '@/libs/media/permission.ts';
import type { VideoFrameRate } from '@/types.ts';

type OpenOptions = {
  id: string;
  width: number;
  height: number;
  audioId?: string;
  frameRate?: VideoFrameRate;
};

class Camera {
  id: string = '';
  width: number = 1920;
  height: number = 1080;
  frameRate: VideoFrameRate = 60;
  audioId: string = '';
  stream: MediaStream | null = null;

  public async open({ id, width, height, audioId, frameRate = this.frameRate }: OpenOptions) {
    if (!id && !this.id) {
      return;
    }

    this.close();

    const video: MediaTrackConstraints & {
      latency?: { ideal: number };
      resizeMode?: string;
    } = {
      deviceId: { exact: id },
      width: { ideal: width },
      height: { ideal: height },
      latency: { ideal: 0 },
      resizeMode: 'none'
    };

    if (frameRate !== 'auto') {
      video.frameRate = { ideal: frameRate };
    }

    const isMicGranted = await checkPermission('microphone');
    const audio =
      isMicGranted && audioId
        ? {
            deviceId: { exact: audioId },
            echoCancellation: false,
            noiseSuppression: false,
            autoGainControl: false,
            sampleRate: 48000,
            latency: 0
          }
        : false;

    this.id = id;
    this.width = width;
    this.height = height;
    this.frameRate = frameRate;
    if (audioId) this.audioId = audioId;

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ video, audio });
    } catch {
      this.stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
    }
  }

  public async updateResolution(width: number, height: number) {
    return this.open({
      id: this.id,
      width,
      height,
      audioId: this.audioId,
      frameRate: this.frameRate
    });
  }

  public async updateFrameRate(frameRate: VideoFrameRate) {
    return this.open({
      id: this.id,
      width: this.width,
      height: this.height,
      audioId: this.audioId,
      frameRate
    });
  }

  public close(): void {
    if (this.stream) {
      this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
    }
  }

  public getStream(): MediaStream | null {
    return this.stream;
  }

  public isOpen(): boolean {
    return this.stream !== null;
  }
}

export const camera = new Camera();
