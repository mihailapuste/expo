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
    emitRemotePlay: jest.fn(),
    emitRemotePause: jest.fn(),
    emitRemoteSeekForward: jest.fn(),
    emitRemoteSeekBackward: jest.fn(),
    emitRemoteSeekTo: jest.fn(),
    emitRemoteNextTrack: jest.fn(),
    emitRemotePreviousTrack: jest.fn(),
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

function getActionHandler(
  mediaSession: MockMediaSession,
  action: MediaSessionAction
): MediaSessionActionHandler | null {
  for (let index = mediaSession.setActionHandler.mock.calls.length - 1; index >= 0; index--) {
    const [registeredAction, handler] = mediaSession.setActionHandler.mock.calls[index];
    if (registeredAction === action) {
      return handler;
    }
  }
  return null;
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

  it('routes browser Media Session play and pause commands through player remote events', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer);

    getActionHandler(mediaSession, 'play')?.({});
    getActionHandler(mediaSession, 'pause')?.({});

    expect(activePlayer.emitRemotePlay).toHaveBeenCalledTimes(1);
    expect(activePlayer.play).toHaveBeenCalledTimes(1);
    expect(activePlayer.emitRemotePause).toHaveBeenCalledTimes(1);
    expect(activePlayer.pause).toHaveBeenCalledTimes(1);
  });

  it('routes browser Media Session seek commands through player remote events', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer({ currentTime: 20, duration: 60 });
    mediaSessionController.setActivePlayer(activePlayer, undefined, {
      showSeekForward: true,
      showSeekBackward: true,
    });

    getActionHandler(mediaSession, 'seekforward')?.({ seekOffset: 15 });
    getActionHandler(mediaSession, 'seekbackward')?.({ seekOffset: 5 });
    getActionHandler(mediaSession, 'seekto')?.({ seekTime: 30 });

    expect(activePlayer.emitRemoteSeekForward).toHaveBeenCalledWith(15);
    expect(activePlayer.emitRemoteSeekBackward).toHaveBeenCalledWith(5);
    expect(activePlayer.emitRemoteSeekTo).toHaveBeenCalledWith(30);
    expect(activePlayer.seekTo).toHaveBeenCalledWith(35);
    expect(activePlayer.seekTo).toHaveBeenCalledWith(15);
    expect(activePlayer.seekTo).toHaveBeenCalledWith(30);
  });

  it('routes browser Media Session next and previous commands through track remote events', () => {
    const mediaSession = mockMediaSession();
    activePlayer = createPlayer();
    mediaSessionController.setActivePlayer(activePlayer, undefined, {
      showNextTrack: true,
      showPreviousTrack: true,
    });

    getActionHandler(mediaSession, 'nexttrack')?.({});
    getActionHandler(mediaSession, 'previoustrack')?.({});

    expect(activePlayer.emitRemoteNextTrack).toHaveBeenCalledTimes(1);
    expect(activePlayer.emitRemotePreviousTrack).toHaveBeenCalledTimes(1);
    expect(activePlayer.seekTo).not.toHaveBeenCalled();
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
