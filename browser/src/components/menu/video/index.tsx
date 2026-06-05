import { Popover } from 'antd';
import { MonitorIcon } from 'lucide-react';

import { Device } from './device.tsx';
import { FrameRate } from './frame-rate.tsx';
import { Resolution } from './resolution.tsx';
import { Rotation } from './rotation.tsx';
import { Scale } from './scale.tsx';

export const Video = () => {
  const content = (
    <div className="flex flex-col space-y-0.5">
      <Resolution />
      <FrameRate />
      <Rotation />
      <Scale />
      <Device />
    </div>
  );

  return (
    <Popover content={content} placement="bottomLeft" trigger="click" arrow={false}>
      <div className="flex h-[28px] w-[28px] cursor-pointer items-center justify-center rounded text-neutral-300 hover:bg-neutral-700/70 hover:text-white">
        <MonitorIcon size={18} />
      </div>
    </Popover>
  );
};
