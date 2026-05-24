import { AudioPlayerWeb } from '../AudioPlayer.web';

describe(AudioPlayerWeb.prototype.updateLockScreenPlaybackInfo, () => {
  it('is available as a no-op on web for cross-platform player compatibility', () => {
    const player = Object.create(AudioPlayerWeb.prototype) as AudioPlayerWeb;

    expect(
      player.updateLockScreenPlaybackInfo({
        currentTime: 5,
        duration: 60,
        isPlaying: true,
        playbackRate: 1,
        isLiveStream: false,
      })
    ).toBeUndefined();
  });
});
