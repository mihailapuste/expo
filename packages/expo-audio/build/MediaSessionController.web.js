const SKIP_SECONDS = 10;
class MediaSessionController {
    activePlayer = null;
    metadata = null;
    options = null;
    setActivePlayer(player, metadata, options) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer && this.activePlayer !== player) {
            this.clear(this.activePlayer);
        }
        this.activePlayer = player;
        this.metadata = metadata ?? null;
        this.options = options ?? null;
        this._applyMetadata();
        this._applyActionHandlers();
        this.updatePlaybackState(player);
        this.updatePositionState(player);
    }
    updateMetadata(player, metadata) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer !== player)
            return;
        this.metadata = metadata;
        this._applyMetadata();
    }
    clear(player) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer !== player)
            return;
        this.activePlayer = null;
        this.metadata = null;
        this.options = null;
        navigator.mediaSession.metadata = null;
        navigator.mediaSession.playbackState = 'none';
        const actions = [
            'play',
            'pause',
            'seekto',
            'seekforward',
            'seekbackward',
            'previoustrack',
            'nexttrack',
        ];
        for (const action of actions) {
            this._setHandler(action, null);
        }
        try {
            navigator.mediaSession.setPositionState();
        }
        catch { }
    }
    updatePlaybackState(player) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer !== player)
            return;
        navigator.mediaSession.playbackState = player.playing ? 'playing' : 'paused';
    }
    updatePositionState(player) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer !== player)
            return;
        this._setPositionState(player.currentTime, player.duration, player.playbackRate);
    }
    updateMediaSessionPlaybackInfo(player, playbackInfo) {
        if (!navigator.mediaSession)
            return;
        if (this.activePlayer !== player)
            return;
        navigator.mediaSession.playbackState = playbackInfo.isPlaying ? 'playing' : 'paused';
        if (playbackInfo.isLiveStream === true) {
            this._clearPositionState();
            return;
        }
        const didSetPositionState = this._setPositionState(playbackInfo.currentTime, playbackInfo.duration, playbackInfo.playbackRate);
        if (!didSetPositionState) {
            this._clearPositionState();
        }
    }
    _setPositionState(currentTime, duration, playbackRate) {
        if (!Number.isFinite(duration) || duration <= 0) {
            return false;
        }
        const position = Number.isFinite(currentTime)
            ? Math.min(Math.max(currentTime, 0), duration)
            : 0;
        const safePlaybackRate = Number.isFinite(playbackRate) && playbackRate > 0 ? playbackRate : 1;
        try {
            navigator.mediaSession.setPositionState({
                duration,
                playbackRate: safePlaybackRate,
                position,
            });
            return true;
        }
        catch { }
        return false;
    }
    _clearPositionState() {
        try {
            navigator.mediaSession.setPositionState();
        }
        catch { }
    }
    isActive(player) {
        return this.activePlayer === player;
    }
    getActiveState(player) {
        if (this.activePlayer !== player)
            return null;
        return { metadata: this.metadata, options: this.options };
    }
    _applyMetadata() {
        if (!this.metadata) {
            navigator.mediaSession.metadata = null;
            return;
        }
        const { title, artist, albumTitle, artworkUrl } = this.metadata;
        const artwork = artworkUrl ? [{ src: artworkUrl }] : [];
        navigator.mediaSession.metadata = new MediaMetadata({
            title: title ?? '',
            artist: artist ?? '',
            album: albumTitle ?? '',
            artwork,
        });
    }
    _setHandler(action, handler) {
        try {
            navigator.mediaSession.setActionHandler(action, handler);
        }
        catch { }
    }
    _applyActionHandlers() {
        const player = this.activePlayer;
        if (!player)
            return;
        this._setHandler('play', () => {
            player.emitRemotePlay?.();
            player.play();
        });
        this._setHandler('pause', () => {
            player.emitRemotePause?.();
            player.pause();
        });
        this._setHandler('seekto', (details) => {
            if (details.seekTime != null) {
                player.emitRemoteSeekTo?.(details.seekTime);
                player.seekTo(details.seekTime);
                this.updatePositionState(player);
            }
        });
        const seekForward = (details) => {
            const skipTime = details.seekOffset ?? SKIP_SECONDS;
            const newTime = Math.min(player.currentTime + skipTime, player.duration || 0);
            player.emitRemoteSeekForward?.(skipTime);
            player.seekTo(newTime);
            this.updatePositionState(player);
        };
        const seekBackward = (details) => {
            const skipTime = details.seekOffset ?? SKIP_SECONDS;
            const newTime = Math.max(player.currentTime - skipTime, 0);
            player.emitRemoteSeekBackward?.(skipTime);
            player.seekTo(newTime);
            this.updatePositionState(player);
        };
        if (this.options?.showSeekForward === true) {
            this._setHandler('seekforward', seekForward);
        }
        else {
            this._setHandler('seekforward', null);
        }
        if (this.options?.showNextTrack === true) {
            this._setHandler('nexttrack', () => {
                player.emitRemoteNextTrack?.();
            });
        }
        else {
            this._setHandler('nexttrack', null);
        }
        if (this.options?.showSeekBackward === true) {
            this._setHandler('seekbackward', seekBackward);
        }
        else {
            this._setHandler('seekbackward', null);
        }
        if (this.options?.showPreviousTrack === true) {
            this._setHandler('previoustrack', () => {
                player.emitRemotePreviousTrack?.();
            });
        }
        else {
            this._setHandler('previoustrack', null);
        }
    }
}
export const mediaSessionController = new MediaSessionController();
//# sourceMappingURL=MediaSessionController.web.js.map