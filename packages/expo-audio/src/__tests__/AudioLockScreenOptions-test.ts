import type { AudioEvents, AudioLockScreenOptions, AudioLockScreenPlaybackInfo } from '..';

type RemoteEventName =
  | 'onRemotePlay'
  | 'onRemotePause'
  | 'onRemoteTogglePlayPause'
  | 'onRemoteSeekForward'
  | 'onRemoteSeekBackward'
  | 'onRemoteSeekTo'
  | 'onRemoteNextTrack'
  | 'onRemotePreviousTrack';

describe('AudioLockScreenOptions', () => {
  it('accepts the iOS next and previous track controls with existing lock screen controls', () => {
    const options = {
      showSeekForward: true,
      showSeekBackward: true,
      showNextTrack: true,
      showPreviousTrack: true,
      isLiveStream: false,
    } satisfies AudioLockScreenOptions;

    expect(options).toEqual({
      showSeekForward: true,
      showSeekBackward: true,
      showNextTrack: true,
      showPreviousTrack: true,
      isLiveStream: false,
    });
  });

  it('types lock screen playback info updates', () => {
    const playbackInfo = {
      currentTime: 12,
      duration: 180,
      isPlaying: true,
      playbackRate: 1.25,
      isLiveStream: false,
    } satisfies AudioLockScreenPlaybackInfo;

    expect(playbackInfo).toEqual({
      currentTime: 12,
      duration: 180,
      isPlaying: true,
      playbackRate: 1.25,
      isLiveStream: false,
    });
  });

  it('types the remote command events emitted from iOS lock screen controls', () => {
    const events: string[] = [];
    const handlers: Pick<AudioEvents, RemoteEventName> = {
      onRemotePlay() {
        events.push('play');
      },
      onRemotePause() {
        events.push('pause');
      },
      onRemoteTogglePlayPause() {
        events.push('toggle');
      },
      onRemoteSeekForward({ interval }) {
        events.push(`forward:${interval}`);
      },
      onRemoteSeekBackward({ interval }) {
        events.push(`backward:${interval}`);
      },
      onRemoteSeekTo({ position }) {
        events.push(`seek:${position}`);
      },
      onRemoteNextTrack() {
        events.push('next');
      },
      onRemotePreviousTrack() {
        events.push('previous');
      },
    };

    handlers.onRemotePlay();
    handlers.onRemotePause();
    handlers.onRemoteTogglePlayPause();
    handlers.onRemoteSeekForward({ interval: 10 });
    handlers.onRemoteSeekBackward({ interval: 10 });
    handlers.onRemoteSeekTo({ position: 42 });
    handlers.onRemoteNextTrack();
    handlers.onRemotePreviousTrack();

    expect(events).toEqual([
      'play',
      'pause',
      'toggle',
      'forward:10',
      'backward:10',
      'seek:42',
      'next',
      'previous',
    ]);
  });
});
