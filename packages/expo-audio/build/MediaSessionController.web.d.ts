import type { AudioMetadata } from './Audio.types';
import type { AudioLockScreenOptions } from './AudioConstants';
import type { AudioLockScreenPlaybackInfo } from './AudioModule.types';
interface MediaSessionPlayer {
    play(): void;
    pause(): void;
    seekTo(seconds: number): Promise<void>;
    emitRemotePlay?(): void;
    emitRemotePause?(): void;
    emitRemoteSeekForward?(interval: number): void;
    emitRemoteSeekBackward?(interval: number): void;
    emitRemoteSeekTo?(position: number): void;
    emitRemoteNextTrack?(): void;
    emitRemotePreviousTrack?(): void;
    readonly playing: boolean;
    readonly currentTime: number;
    readonly duration: number;
    readonly playbackRate: number;
}
declare class MediaSessionController {
    private activePlayer;
    private metadata;
    private options;
    setActivePlayer(player: MediaSessionPlayer, metadata?: AudioMetadata, options?: AudioLockScreenOptions): void;
    updateMetadata(player: MediaSessionPlayer, metadata: AudioMetadata): void;
    clear(player: MediaSessionPlayer): void;
    updatePlaybackState(player: MediaSessionPlayer): void;
    updatePositionState(player: MediaSessionPlayer): void;
    updateMediaSessionPlaybackInfo(player: MediaSessionPlayer, playbackInfo: AudioLockScreenPlaybackInfo): void;
    private _setPositionState;
    private _clearPositionState;
    isActive(player: MediaSessionPlayer): boolean;
    getActiveState(player: MediaSessionPlayer): {
        metadata: AudioMetadata | null;
        options: AudioLockScreenOptions | null;
    } | null;
    private _applyMetadata;
    private _setHandler;
    private _applyActionHandlers;
}
export declare const mediaSessionController: MediaSessionController;
export {};
//# sourceMappingURL=MediaSessionController.web.d.ts.map