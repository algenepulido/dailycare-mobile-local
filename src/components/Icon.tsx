import Svg, { Circle, Line, Path, Rect } from 'react-native-svg';

import { color as tokens } from '@/theme/tokens';

export type IconName = 'check' | 'plus' | 'close' | 'send' | 'camera' | 'clipboard' | 'flag' | 'user';

interface IconProps {
  name: IconName;
  size?: number;
  color?: string;
}

/**
 * The reference's icon set, path for path.
 *
 * These carry meaning rather than decoration — a sage check and a red flag are how the
 * checklist says what happened and what didn't, so a text glyph in their place loses
 * the distinction.
 */
export function Icon({ name, size = 18, color = tokens.ink }: IconProps) {
  const common = {
    stroke: color,
    fill: 'none' as const,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  };

  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      {name === 'check' ? <Path d="M5 12.5l4.5 4.5L19 7" strokeWidth={2.6} {...common} /> : null}

      {name === 'plus' ? (
        <>
          <Line x1={12} y1={5} x2={12} y2={19} strokeWidth={2.4} {...common} />
          <Line x1={5} y1={12} x2={19} y2={12} strokeWidth={2.4} {...common} />
        </>
      ) : null}

      {name === 'close' ? (
        <>
          <Line x1={6} y1={6} x2={18} y2={18} strokeWidth={2} {...common} />
          <Line x1={18} y1={6} x2={6} y2={18} strokeWidth={2} {...common} />
        </>
      ) : null}

      {name === 'send' ? (
        <>
          <Path d="M22 2L11 13" strokeWidth={2} {...common} />
          <Path d="M22 2l-7 20-4-9-9-4 20-7z" strokeWidth={2} {...common} />
        </>
      ) : null}

      {name === 'camera' ? (
        <>
          <Path
            d="M3 8a2 2 0 0 1 2-2h2l1.5-2h7L19 6h0a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"
            strokeWidth={2}
            {...common}
          />
          <Circle cx={12} cy={12.5} r={3.5} strokeWidth={2} {...common} />
        </>
      ) : null}

      {name === 'clipboard' ? (
        <>
          <Rect x={5} y={4} width={14} height={17} rx={2} strokeWidth={2} {...common} />
          <Path d="M9 4a3 3 0 0 1 6 0" strokeWidth={2} {...common} />
          <Path d="M8.5 12l2 2 4-4" strokeWidth={2} {...common} />
        </>
      ) : null}

      {name === 'flag' ? (
        <>
          <Path d="M5 21V4" strokeWidth={2} {...common} />
          <Path d="M5 4h11l-2 4 2 4H5" strokeWidth={2} {...common} />
        </>
      ) : null}

      {name === 'user' ? (
        <>
          <Circle cx={12} cy={8} r={4} strokeWidth={2} {...common} />
          <Path d="M5 21v-1a7 7 0 0 1 14 0v1" strokeWidth={2} {...common} />
        </>
      ) : null}
    </Svg>
  );
}
