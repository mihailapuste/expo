/**
 * @jest-environment jsdom
 */

import { mediaSessionController } from '../MediaSessionController.web';

type TestPlayer = Parameters<typeof mediaSessionController.setActivePlayer>[0];

type MockMediaSession = {
  metadata: MediaMetadata | null;
  playbackState: MediaSessionPlaybackState;
  setActionHandler: jest.Mock;
  setPositionState: jest.Mock;
};

function createPlayer(overrides: Partial<TestPlayer> = {}): TestPlayer {
  return {
    play: jest.fn(),
    pause: jest.fn(),
    seekTo: jest.fn().mockResolvedValue(undefined),
    playing: false,
    currentTime: 5,
    duration: 60,
    playbackRate: 1,
    ...overrides,
  };
}

function mockMediaSession(): MockMediaSession {
  const mediaSession: MockMediaSession = {
    metadata: null,
    playbackState: 'none',
    setActionHandler: jest.fn(),
    setPositionState: jest.fn(),
  };

  Object.defineProperty(navigator, 'mediaSession', {
    configurable: true,
    value: mediaSession,
  });

  return mediaSession;
}

function clearMediaSessionMock() {
  Object.defineProperty(navigator, 'mediaSession', {
    configurable: true,
    value: undefined,
  });
}

describe('MediaSessionController', () => {
  let activePlayer: TestPlayer | null = null;

  afterEach(() => {
    if (activePlayer) {
      mediaSessionController.clear(activePlayer);
      activePlayer = null;
    }
    clearMediaSessionMock();
  });

  it('maps playback info to browser Media Session playback and position state', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer);
    mediaSession.setPositionState.mockClear();

    mediaSessionController.updateMediaSessionPlaybackInfo(activePlayer, {
      currentTime: 75,
      duration: 60,
      isPlaying: true,
      playbackRate: 0,
    });

    expect(mediaSession.playbackState).toBe('playing');
    expect(mediaSession.setPositionState).toHaveBeenCalledWith({
      duration: 60,
      playbackRate: 1,
      position: 60,
    });
  });

  it('clears browser Media Session position state for live streams', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer);
    mediaSession.setPositionState.mockClear();

    mediaSessionController.updateMediaSessionPlaybackInfo(activePlayer, {
      currentTime: 20,
      duration: Number.POSITIVE_INFINITY,
      isPlaying: true,
      playbackRate: 1,
      isLiveStream: true,
    });

    expect(mediaSession.playbackState).toBe('playing');
    expect(mediaSession.setPositionState).toHaveBeenCalledWith();
  });

  it('clears stale browser Media Session position state for invalid explicit playback info', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer);
    mediaSession.setPositionState.mockClear();

    mediaSessionController.updateMediaSessionPlaybackInfo(activePlayer, {
      currentTime: 0,
      duration: 0,
      isPlaying: false,
      playbackRate: 1,
    });

    expect(mediaSession.playbackState).toBe('paused');
    expect(mediaSession.setPositionState).toHaveBeenCalledWith();
  });

  it('does not let inactive players update browser Media Session playback info', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    const inactivePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer);
    mediaSession.playbackState = 'none';
    mediaSession.setPositionState.mockClear();

    mediaSessionController.updateMediaSessionPlaybackInfo(inactivePlayer, {
      currentTime: 30,
      duration: 60,
      isPlaying: true,
      playbackRate: 1,
    });

    expect(mediaSession.playbackState).toBe('none');
    expect(mediaSession.setPositionState).not.toHaveBeenCalled();
  });

  it('does not throw when browser Media Session is unavailable', () => {
    const player = createPlayer();

    expect(() => {
      mediaSessionController.updateMediaSessionPlaybackInfo(player, {
        currentTime: 30,
        duration: 60,
        isPlaying: true,
        playbackRate: 1,
      });
    }).not.toThrow();
  });
});
