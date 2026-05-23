import MediaPlayer
import AVFoundation
import ExpoModulesCore

class MediaController {
  static let shared = MediaController()

  private var activePlayer: AudioPlayer?
  private var remoteCommandCenter = MPRemoteCommandCenter.shared()
  private var nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

  private var nextTrackTarget: Any?
  private var previousTrackTarget: Any?

  private var currentArtworkUrl: URL?
  private var cachedArtwork: MPMediaItemArtwork?
  private var artworkLoadToken: UUID?
  private var currentArtworkItemIdentifier: ObjectIdentifier?
  private var isLiveStream = false

  func setActivePlayer(_ player: AudioPlayer?, options: LockScreenOptions? = nil) {
    performOnMain {
      self.setActivePlayerOnMain(player, options: options)
    }
  }

  func updateNowPlayingInfo(for player: AudioPlayer) {
    performOnMain {
      self.updateNowPlayingInfoOnMain(for: player)
    }
  }

  func updateNowPlayingPlaybackInfo(for player: AudioPlayer, playbackInfo: LockScreenPlaybackInfo) {
    performOnMain {
      self.updateNowPlayingPlaybackInfoOnMain(for: player, playbackInfo: playbackInfo)
    }
  }

  private func setActivePlayerOnMain(_ player: AudioPlayer?, options: LockScreenOptions? = nil) {
    if let previous = activePlayer, previous.id != player?.id {
      previous.isActiveForLockScreen = false
      resetArtworkState()
      currentArtworkItemIdentifier = nil
    }

    activePlayer = player
    player?.isActiveForLockScreen = true
    isLiveStream = options?.isLiveStream ?? player?.isLive ?? false

    if let player {
      enableRemoteCommands(options: options)
      updateNowPlayingInfoOnMain(for: player)
    } else {
      disableRemoteCommands()
      clearNowPlayingInfoOnMain()
    }
  }

  private func updateNowPlayingInfoOnMain(for player: AudioPlayer) {
    guard player.id == activePlayer?.id else {
      return
    }

    let nextArtworkItemIdentifier = player.ref.currentItem.map { ObjectIdentifier($0) }
    if currentArtworkItemIdentifier != nextArtworkItemIdentifier {
      resetArtworkState()
      currentArtworkItemIdentifier = nextArtworkItemIdentifier
    }

    var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()

    applyPlaybackInfo(&nowPlayingInfo, for: player)

    if let userMetadata = player.metadata {
      applyUserMetadata(&nowPlayingInfo, from: userMetadata)
      applyArtwork(&nowPlayingInfo, from: userMetadata, for: player, currentItemIdentifier: nextArtworkItemIdentifier)
    } else {
      resetArtworkState()
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
      applyAssetMetadata(&nowPlayingInfo, for: player)
    }

    nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
  }

  private func applyPlaybackInfo(_ info: inout [String: Any], for player: AudioPlayer) {
    applyPlaybackInfo(
      &info,
      currentTime: player.currentTime,
      duration: player.duration,
      isPlaying: player.isPlaying,
      playbackRate: Double(player.ref.rate),
      isLiveStream: isLiveStream
    )
  }

  private func updateNowPlayingPlaybackInfoOnMain(for player: AudioPlayer, playbackInfo: LockScreenPlaybackInfo) {
    guard player.id == activePlayer?.id else {
      return
    }

    isLiveStream = playbackInfo.isLiveStream

    var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
    applyPlaybackInfo(
      &nowPlayingInfo,
      currentTime: playbackInfo.currentTime,
      duration: playbackInfo.duration,
      isPlaying: playbackInfo.isPlaying,
      playbackRate: playbackInfo.playbackRate,
      isLiveStream: playbackInfo.isLiveStream
    )
    nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
  }

  private func applyPlaybackInfo(
    _ info: inout [String: Any],
    currentTime: Double,
    duration: Double,
    isPlaying: Bool,
    playbackRate: Double,
    isLiveStream: Bool
  ) {
    if isLiveStream {
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
      info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
    } else {
      info.removeValue(forKey: MPNowPlayingInfoPropertyIsLiveStream)

      let safeDuration = duration.isFinite ? max(duration, 0) : 0
      let safeElapsedTime = currentTime.isFinite ? max(currentTime, 0) : 0

      info[MPMediaItemPropertyPlaybackDuration] = safeDuration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(safeElapsedTime, safeDuration)
    }
    let safePlaybackRate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? safePlaybackRate : 0
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = safePlaybackRate
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
  }

  private func applyUserMetadata(_ info: inout [String: Any], from metadata: Metadata) {
    if let title = metadata.title {
      info[MPMediaItemPropertyTitle] = title
    }
    if let artist = metadata.artist {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let album = metadata.albumTitle {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
  }

  private func applyAssetMetadata(_ info: inout [String: Any], for player: AudioPlayer) {
    guard let currentItem = player.ref.currentItem,
      let asset = currentItem.asset as? AVURLAsset else {
      return
    }

    for item in asset.commonMetadata {
      switch item.commonKey {
      case .commonKeyTitle:
        if let title = item.stringValue {
          info[MPMediaItemPropertyTitle] = title
        }
      case .commonKeyArtist:
        if let artist = item.stringValue {
          info[MPMediaItemPropertyArtist] = artist
        }
      case .commonKeyAlbumName:
        if let album = item.stringValue {
          info[MPMediaItemPropertyAlbumTitle] = album
        }
      case .commonKeyArtwork:
        if let imageData = item.dataValue,
          let image = UIImage(data: imageData) {
          info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
      default:
        break
      }
    }
  }

  private func applyArtwork(
    _ info: inout [String: Any],
    from metadata: Metadata,
    for player: AudioPlayer,
    currentItemIdentifier: ObjectIdentifier?
  ) {
    guard let artworkUrl = metadata.artworkUrl else {
      resetArtworkState()
      info.removeValue(forKey: MPMediaItemPropertyArtwork)
      return
    }

    if currentArtworkUrl != artworkUrl {
      currentArtworkUrl = artworkUrl
      cachedArtwork = nil
      artworkLoadToken = nil
    }

    if let cachedArtwork {
      info[MPMediaItemPropertyArtwork] = cachedArtwork
      return
    }

    guard artworkLoadToken == nil else {
      return
    }

    let loadToken = UUID()
    artworkLoadToken = loadToken

    loadArtworkFromURL(url: artworkUrl) { [weak self] artwork in
      guard let self, self.artworkLoadToken == loadToken else {
        return
      }

      self.artworkLoadToken = nil

      guard self.activePlayer?.id == player.id,
            self.currentArtworkUrl == artworkUrl,
            self.currentArtworkItemIdentifier == currentItemIdentifier else {
        return
      }

      guard let artwork else {
        return
      }

      self.cachedArtwork = artwork

      var latestNowPlayingInfo = self.nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
      latestNowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
      self.nowPlayingInfoCenter.nowPlayingInfo = latestNowPlayingInfo
    }
  }

  private func clearNowPlayingInfoOnMain() {
    nowPlayingInfoCenter.nowPlayingInfo = nil
    activePlayer = nil
    isLiveStream = false
    resetArtworkState()
    currentArtworkItemIdentifier = nil
  }

  private func performOnMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }

  private func resetArtworkState() {
    currentArtworkUrl = nil
    cachedArtwork = nil
    artworkLoadToken = nil
  }

  private func loadArtworkFromURL(url: URL, completion: @escaping (MPMediaItemArtwork?) -> Void) {
    URLSession.shared.dataTask(with: url) { data, _, error in
      if error != nil {
        self.performOnMain {
          completion(nil)
        }
        return
      }

      guard let data, let image = UIImage(data: data) else {
        self.performOnMain {
          completion(nil)
        }
        return
      }

      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      self.performOnMain {
        completion(artwork)
      }
    }
    .resume()
  }

  private func enableRemoteCommands(options: LockScreenOptions?) {
    removeTrackCommandTargets()

    remoteCommandCenter.playCommand.addTarget { [weak self] _ in
      guard let player = self?.activePlayer else {
        return .commandFailed
      }

      player.emitRemotePlay()
      player.play(at: Float(player.currentRate > 0 ? player.currentRate : 1.0))
      return .success
    }

    remoteCommandCenter.pauseCommand.addTarget { [weak self] _ in
      guard let player = self?.activePlayer else {
        return .commandFailed
      }

      player.emitRemotePause()
      player.pause()
      return .success
    }

    remoteCommandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let player = self?.activePlayer else {
        return .commandFailed
      }

      player.emitRemoteTogglePlayPause()
      if player.isPlaying {
        player.pause()
      } else {
        player.play(at: Float(player.currentRate > 0 ? player.currentRate : 1.0))
      }
      return .success
    }

    remoteCommandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let player = self?.activePlayer,
      let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }

      player.emitRemoteSeekTo(position: event.positionTime)
      let seekTime = CMTime(seconds: event.positionTime, preferredTimescale: 1)
      player.ref.seek(to: seekTime)

      return .success
    }

    remoteCommandCenter.skipForwardCommand.preferredIntervals = [10.0]
    remoteCommandCenter.skipForwardCommand.addTarget { [weak self] event in
      guard let player = self?.activePlayer,
      let event = event as? MPSkipIntervalCommandEvent else {
        return .commandFailed
      }

      player.emitRemoteSeekForward(interval: event.interval)
      let currentTime = player.ref.currentTime()
      let seekTime = currentTime + CMTime(seconds: event.interval, preferredTimescale: 1)
      player.ref.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

      return .success
    }

    remoteCommandCenter.skipBackwardCommand.preferredIntervals = [10.0]
    remoteCommandCenter.skipBackwardCommand.addTarget { [weak self] event in
      guard let player = self?.activePlayer,
      let event = event as? MPSkipIntervalCommandEvent else {
        return .commandFailed
      }

      player.emitRemoteSeekBackward(interval: event.interval)
      let currentTime = player.ref.currentTime()
      let seekTime = currentTime - CMTime(seconds: event.interval, preferredTimescale: 1)
      player.ref.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

      return .success
    }

    nextTrackTarget = remoteCommandCenter.nextTrackCommand.addTarget { [weak self] _ in
      guard let player = self?.activePlayer else {
        return .commandFailed
      }

      player.emitRemoteNextTrack()
      return .success
    }

    previousTrackTarget = remoteCommandCenter.previousTrackCommand.addTarget { [weak self] _ in
      guard let player = self?.activePlayer else {
        return .commandFailed
      }

      player.emitRemotePreviousTrack()
      return .success
    }

    remoteCommandCenter.playCommand.isEnabled = true
    remoteCommandCenter.pauseCommand.isEnabled = true
    remoteCommandCenter.togglePlayPauseCommand.isEnabled = true
    remoteCommandCenter.changePlaybackPositionCommand.isEnabled = !isLiveStream
    remoteCommandCenter.skipForwardCommand.isEnabled = options?.showSeekForward ?? false
    remoteCommandCenter.skipBackwardCommand.isEnabled = options?.showSeekBackward ?? false
    remoteCommandCenter.nextTrackCommand.isEnabled = options?.showNextTrack ?? false
    remoteCommandCenter.previousTrackCommand.isEnabled = options?.showPreviousTrack ?? false
  }

  private func disableRemoteCommands() {
    remoteCommandCenter.playCommand.isEnabled = false
    remoteCommandCenter.pauseCommand.isEnabled = false
    remoteCommandCenter.togglePlayPauseCommand.isEnabled = false
    remoteCommandCenter.changePlaybackPositionCommand.isEnabled = false
    remoteCommandCenter.skipForwardCommand.isEnabled = false
    remoteCommandCenter.skipBackwardCommand.isEnabled = false
    remoteCommandCenter.nextTrackCommand.isEnabled = false
    remoteCommandCenter.previousTrackCommand.isEnabled = false

    // Remove event targets
    remoteCommandCenter.playCommand.removeTarget(self)
    remoteCommandCenter.pauseCommand.removeTarget(self)
    remoteCommandCenter.togglePlayPauseCommand.removeTarget(self)
    remoteCommandCenter.changePlaybackPositionCommand.removeTarget(self)
    remoteCommandCenter.skipForwardCommand.removeTarget(self)
    remoteCommandCenter.skipBackwardCommand.removeTarget(self)
    removeTrackCommandTargets()
  }

  private func removeTrackCommandTargets() {
    if let nextTrackTarget {
      remoteCommandCenter.nextTrackCommand.removeTarget(nextTrackTarget)
    }
    if let previousTrackTarget {
      remoteCommandCenter.previousTrackCommand.removeTarget(previousTrackTarget)
    }
    nextTrackTarget = nil
    previousTrackTarget = nil
  }
}
