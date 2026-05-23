// Copyright 2026-present 650 Industries. All rights reserved.

import AVFoundation
import ExpoModulesCore

private enum VideoPlaylistConstants {
  static let playlistStatusUpdate = "playlistStatusUpdate"
  static let trackChanged = "trackChanged"
}

internal enum VideoPlaylistLoopMode: String, Enumerable {
  case none
  case single
  case all
}

// swiftlint:disable redundant_optional_initialization - Initialization with nil is necessary
internal struct VideoPlaylistSource: Record {
  @Field
  var id: String? = nil

  @Field
  var source: VideoSource? = nil

  @Field
  var metadata: VideoMetadata? = nil
}

internal struct VideoPlaylistReplaceOptions: Record {
  @Field
  var preserveCurrentSource: Bool = false
}
// swiftlint:enable redundant_optional_initialization

internal final class VideoPlaylist: SharedObject, VideoPlayerObserverDelegate {
  let id = UUID().uuidString
  let player: VideoPlayer

  private let queuePlayer: AVQueuePlayer
  private let interval: Double
  private let preloadLoader = VideoSourceLoader()
  private var sources: [VideoPlaylistSource]
  private var currentIndex: Int
  private var loopMode: VideoPlaylistLoopMode
  private var shouldPreloadNext: Bool
  private var autoAdvance: Bool
  private var shouldPlayWhenReady = false
  private var transitionGeneration = 0
  private var transitionTask: Task<Void, Never>?
  private var preloadTask: Task<Void, Never>?
  private var preloadedItem: VideoPlayerItem?
  private var preloadedIndex: Int?
  private var preloadedIdentity: String?
  private var preloadedItemIsQueued = false
  private var currentItem: AVPlayerItem?
  private var timeToken: Any?
  private var error: PlaybackError?
  private var isDestroyed = false

  init(
    sources: [VideoPlaylistSource],
    initialIndex: Int,
    interval: Double,
    loopMode: VideoPlaylistLoopMode,
    preloadNext: Bool,
    autoAdvance: Bool
  ) throws {
    self.sources = sources
    self.currentIndex = sources.isEmpty ? 0 : min(max(initialIndex, 0), sources.count - 1)
    self.interval = max(interval, 1)
    self.loopMode = loopMode
    self.shouldPreloadNext = preloadNext
    self.autoAdvance = autoAdvance
    let queuePlayer = AVQueuePlayer()
    self.queuePlayer = queuePlayer
    self.player = try VideoPlayer(queuePlayer, initialSource: nil)

    super.init()

    player.observer?.registerDelegate(delegate: self)
    registerTimeObserver()

    if !sources.isEmpty {
      transition(to: currentIndex, shouldPlay: false)
    } else {
      emitStatus()
    }
  }

  deinit {
    cleanup()
  }

  var sourceCount: Int {
    sources.count
  }

  var currentStatus: [String: Any] {
    statusPayload()
  }

  func play() {
    shouldPlayWhenReady = true
    player.ref.play()
    emitStatus()
  }

  func pause() {
    shouldPlayWhenReady = false
    player.ref.pause()
    emitStatus()
  }

  func next() {
    guard let nextIndex = nextIndex() else {
      return
    }
    transition(to: nextIndex, shouldPlay: shouldPlayWhenReady || player.isPlaying)
  }

  func previous() {
    guard let previousIndex = previousIndex() else {
      return
    }
    transition(to: previousIndex, shouldPlay: shouldPlayWhenReady || player.isPlaying)
  }

  func skipTo(index: Int) {
    guard validIndex(index) else {
      return
    }
    transition(to: index, shouldPlay: shouldPlayWhenReady || player.isPlaying)
  }

  func seekTo(seconds: Double) async {
    let clampedSeconds = max(seconds, 0)
    let time = CMTime(seconds: clampedSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      player.ref.seek(to: time) { [weak self] _ in
        self?.emitStatus()
        continuation.resume()
      }
    }
  }

  func add(source: VideoPlaylistSource) {
    sources.append(source)
    if sources.count == 1 {
      currentIndex = 0
      transition(to: 0, shouldPlay: shouldPlayWhenReady || player.isPlaying)
    } else {
      preloadNextItem()
      emitStatus()
    }
  }

  func insert(source: VideoPlaylistSource, at index: Int) {
    guard index >= 0 && index <= sources.count else {
      return
    }

    let wasEmpty = sources.isEmpty
    sources.insert(source, at: index)

    if wasEmpty {
      currentIndex = 0
      transition(to: 0, shouldPlay: shouldPlayWhenReady || player.isPlaying)
      return
    }

    if index <= currentIndex {
      currentIndex += 1
    }

    preloadNextItem()
    emitStatus()
  }

  func remove(at index: Int) {
    guard validIndex(index) else {
      return
    }

    let wasCurrentSource = index == currentIndex
    let shouldResume = shouldPlayWhenReady || player.isPlaying
    sources.remove(at: index)

    guard !sources.isEmpty else {
      clear()
      return
    }

    if wasCurrentSource {
      if currentIndex >= sources.count {
        currentIndex = sources.count - 1
      }
      transition(to: currentIndex, shouldPlay: shouldResume)
      return
    }

    if index < currentIndex {
      currentIndex -= 1
    }

    preloadNextItem()
    emitStatus()
  }

  func clear() {
    transitionGeneration += 1
    transitionTask?.cancel()
    clearPreloadedItem(removeQueuedItem: false)
    shouldPlayWhenReady = false
    sources.removeAll()
    currentIndex = 0
    currentItem = nil
    error = nil
    player.ref.pause()
    removeAllQueuedItems()
    DispatchQueue.main.async { [weak self] in
      self?.emitStatus()
    }
  }

  func replaceAll(sources newSources: [VideoPlaylistSource], options: VideoPlaylistReplaceOptions?) {
    let sourceToPreserve = currentSource()
    let shouldResume = shouldPlayWhenReady || player.isPlaying
    let preserveCurrentSource = options?.preserveCurrentSource ?? false
    let newIndex = preserveCurrentSource ? indexPreservingCurrentSource(in: newSources, currentSource: sourceToPreserve) : 0

    sources = newSources
    currentIndex = newSources.isEmpty ? 0 : newIndex
    clearPreloadedItem(removeQueuedItem: true)

    guard !newSources.isEmpty else {
      clear()
      return
    }

    transition(to: currentIndex, shouldPlay: shouldResume)
  }

  func destroy() {
    cleanup()
  }

  override func sharedObjectWillRelease() {
    cleanup()
  }

  // MARK: - VideoPlayerObserverDelegate

  func onStatusChanged(player: AVPlayer, oldStatus: PlayerStatus?, newStatus: PlayerStatus, error: Exception?) {
    if let error {
      self.error = PlaybackError(message: error.description)
    } else if newStatus != .error {
      self.error = nil
    }
    emitStatus()
  }

  func onIsPlayingChanged(player: AVPlayer, oldIsPlaying: Bool?, newIsPlaying: Bool) {
    emitStatus()
  }

  func onItemChanged(player: AVPlayer, oldVideoPlayerItem: VideoPlayerItem?, newVideoPlayerItem: VideoPlayerItem?) {
    let previousIndex = currentIndex
    currentItem = newVideoPlayerItem

    if let newVideoPlayerItem,
      let preloadedItem,
      newVideoPlayerItem === preloadedItem,
      let preloadedIndex {
      currentIndex = preloadedIndex
      self.preloadedItem = nil
      self.preloadedIndex = nil
      self.preloadedIdentity = nil
      preloadedItemIsQueued = false
      emitTrackChanged(previousIndex: previousIndex, currentIndex: currentIndex)
      preloadNextItem()
      return
    }

    emitStatus()
  }

  func onLoadedPlayerItem(player: AVPlayer, playerItem: AVPlayerItem?) {
    emitStatus()
  }

  func onPlayedToEnd(player: AVPlayer, playerItem: AVPlayerItem) {
    runOnMainAsync { [weak self, weak playerItem] in
      guard let self, let playerItem, self.isCurrentItem(playerItem) else {
        return
      }
      self.handlePlayToEnd()
    }
  }

  // MARK: - Transitions

  private func transition(to index: Int, shouldPlay: Bool) {
    guard validIndex(index), !isDestroyed else {
      return
    }

    transitionGeneration += 1
    let generation = transitionGeneration
    let previousIndex = currentIndex
    currentIndex = index
    shouldPlayWhenReady = shouldPlay
    emitStatus()

    transitionTask?.cancel()
    transitionTask = Task { [weak self] in
      guard let self else {
        return
      }
      await self.transition(to: index, previousIndex: previousIndex, shouldPlay: shouldPlay, generation: generation)
    }
  }

  private func transition(to index: Int, previousIndex: Int, shouldPlay: Bool, generation: Int) async {
    guard validIndex(index), !Task.isCancelled else {
      return
    }

    let playlistSource = sources[index]
    let sourceIdentity = sourceIdentity(playlistSource)
    let playerItem: VideoPlayerItem?
    let shouldAdvanceToQueuedItem: Bool

    if let preloadedItem,
      preloadedIndex == index,
      preloadedIdentity == sourceIdentity {
      playerItem = preloadedItem
      shouldAdvanceToQueuedItem = preloadedItemIsQueued
      self.preloadedItem = nil
      self.preloadedIndex = nil
      self.preloadedIdentity = nil
      self.preloadedItemIsQueued = false
    } else {
      shouldAdvanceToQueuedItem = false
      clearPreloadedItem(removeQueuedItem: true)
      if let source = playlistSource.source {
        do {
          playerItem = try await player.loadPlayerItem(with: source, using: player.videoSourceLoader)
        } catch {
          guard generation == transitionGeneration else {
            return
          }
          self.error = PlaybackError(message: error.localizedDescription)
          emitStatus()
          preloadNextItem()
          return
        }
      } else {
        playerItem = nil
      }
    }

    guard generation == transitionGeneration, !Task.isCancelled, !isDestroyed else {
      return
    }

    guard applyCurrentQueueItem(
      playerItem,
      shouldPlay: shouldPlay,
      generation: generation,
      advanceToQueuedItem: shouldAdvanceToQueuedItem
    ) else {
      return
    }

    emitTrackChanged(previousIndex: previousIndex, currentIndex: currentIndex)
    preloadNextItem()
  }

  private func handlePlayToEnd() {
    guard !sources.isEmpty else {
      emitStatus(with: ["didJustFinish": true, "playing": false])
      return
    }

    guard autoAdvance else {
      shouldPlayWhenReady = false
      player.ref.pause()
      emitStatus(with: ["didJustFinish": true, "playing": false])
      return
    }

    switch loopMode {
    case .single:
      shouldPlayWhenReady = true
      player.seeker.seek(to: .zero)
      player.ref.play()
      emitStatus(with: ["didJustFinish": true])
    case .all:
      handleSequentialPlaybackEnd()
    case .none:
      if currentIndex >= sources.count - 1 {
        shouldPlayWhenReady = false
        player.ref.pause()
        emitStatus(with: ["didJustFinish": true, "playing": false])
      } else {
        handleSequentialPlaybackEnd()
      }
    }
  }

  private func handleSequentialPlaybackEnd() {
    shouldPlayWhenReady = true
    emitStatus(with: ["didJustFinish": true])

    guard preloadedItemIsQueued else {
      guard let nextIndex = nextIndex() else {
        shouldPlayWhenReady = false
        player.ref.pause()
        emitStatus(with: ["playing": false])
        return
      }
      transition(to: nextIndex, shouldPlay: true)
      return
    }
  }

  // MARK: - Preloading

  private func preloadNextItem() {
    clearPreloadedItem(removeQueuedItem: true)

    guard shouldPrepareNextItem,
      !isDestroyed,
      sources.count > 1,
      loopMode != .single,
      let index = nextIndex(),
      let source = sources[index].source else {
      return
    }

    let generation = transitionGeneration
    let identity = sourceIdentity(sources[index])
    preloadTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        guard let item = try await self.player.loadPlayerItem(with: source, using: self.preloadLoader) else {
          return
        }
        guard !Task.isCancelled,
          generation == self.transitionGeneration,
          self.validIndex(index),
          self.sourceIdentity(self.sources[index]) == identity else {
          return
        }

        self.applyPreloadedItem(item, index: index, identity: identity, generation: generation)
      } catch {
        // Preloading is opportunistic. The main transition path will surface load errors.
      }
    }
  }

  private var shouldPrepareNextItem: Bool {
    autoAdvance || shouldPreloadNext
  }

  // MARK: - Queue

  private func applyCurrentQueueItem(
    _ playerItem: VideoPlayerItem?,
    shouldPlay: Bool,
    generation: Int,
    advanceToQueuedItem: Bool = false
  ) -> Bool {
    var didApply = false

    runOnMainSync {
      guard generation == transitionGeneration, !isDestroyed else {
        return
      }

      queuePlayer.pause()
      if advanceToQueuedItem,
        let playerItem,
        advanceQueue(to: playerItem) {
        currentItem = queuePlayer.currentItem
        if shouldPlay {
          queuePlayer.play()
        }
        didApply = true
        return
      }

      queuePlayer.removeAllItems()

      if let playerItem {
        queuePlayer.insert(playerItem, after: nil)
      }
      currentItem = queuePlayer.currentItem

      if shouldPlay {
        queuePlayer.play()
      }

      didApply = true
    }

    return didApply
  }

  private func advanceQueue(to item: AVPlayerItem) -> Bool {
    guard queuePlayer.items().contains(where: { $0 === item }) else {
      return false
    }

    while let currentItem = queuePlayer.currentItem, currentItem !== item {
      queuePlayer.advanceToNextItem()
    }

    guard let currentItem = queuePlayer.currentItem else {
      return false
    }
    return currentItem === item
  }

  private func applyPreloadedItem(_ item: VideoPlayerItem, index: Int, identity: String, generation: Int) {
    runOnMainSync {
      guard !isDestroyed,
        generation == transitionGeneration,
        validIndex(index),
        sourceIdentity(sources[index]) == identity else {
        return
      }

      var didInsertInQueue = false
      if autoAdvance,
        let currentItem = queuePlayer.currentItem,
        queuePlayer.canInsert(item, after: currentItem) {
        queuePlayer.insert(item, after: currentItem)
        didInsertInQueue = true
      }

      preloadedItem = item
      preloadedIndex = index
      preloadedIdentity = identity
      preloadedItemIsQueued = didInsertInQueue
    }
  }

  private func clearPreloadedItem(removeQueuedItem: Bool) {
    preloadTask?.cancel()
    preloadTask = nil
    preloadLoader.cancelCurrentTask()

    if removeQueuedItem,
      preloadedItemIsQueued,
      let preloadedItem {
      runOnMainSync {
        if let currentItem = self.queuePlayer.currentItem,
          currentItem === preloadedItem {
          return
        }
        guard self.queuePlayer.items().contains(where: { $0 === preloadedItem }) else {
          return
        }
        self.queuePlayer.remove(preloadedItem)
      }
    }

    preloadedItem = nil
    preloadedIndex = nil
    preloadedIdentity = nil
    preloadedItemIsQueued = false
  }

  private func removeAllQueuedItems() {
    runOnMainAsync { [weak self] in
      self?.queuePlayer.removeAllItems()
      self?.currentItem = nil
    }
  }

  private func runOnMainSync(_ operation: () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.sync(execute: operation)
    }
  }

  private func runOnMainAsync(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }

  // MARK: - Status

  private func statusPayload(extra: [String: Any] = [:]) -> [String: Any] {
    var payload: [String: Any] = [
      "id": id,
      "currentIndex": currentIndex,
      "sourceCount": sources.count,
      "currentSource": currentSourcePayload() ?? NSNull(),
      "currentTime": player.currentTime,
      "duration": playerDuration,
      "playing": player.isPlaying,
      "isBuffering": isBuffering,
      "isLoaded": isLoaded,
      "status": player.status.rawValue,
      "loop": loopMode.rawValue,
      "canPlayNext": nextIndex() != nil,
      "canPlayPrevious": previousIndex() != nil,
      "error": errorPayload() ?? NSNull(),
      "didJustFinish": false
    ]
    payload.merge(extra) { _, new in new }
    return payload
  }

  private func emitStatus(with extra: [String: Any] = [:]) {
    let emit = { [weak self] in
      guard let self else {
        return
      }
      self.emit(event: VideoPlaylistConstants.playlistStatusUpdate, payload: self.statusPayload(extra: extra))
    }

    if Thread.isMainThread {
      emit()
    } else {
      DispatchQueue.main.async(execute: emit)
    }
  }

  private func emitTrackChanged(previousIndex: Int, currentIndex: Int) {
    guard previousIndex != currentIndex else {
      emitStatus()
      return
    }

    let emit = { [weak self] in
      guard let self else {
        return
      }
      self.emit(event: VideoPlaylistConstants.trackChanged, payload: [
        "previousIndex": previousIndex,
        "currentIndex": currentIndex
      ])
      self.emit(event: VideoPlaylistConstants.playlistStatusUpdate, payload: self.statusPayload())
    }

    if Thread.isMainThread {
      emit()
    } else {
      DispatchQueue.main.async(execute: emit)
    }
  }

  private func currentSourcePayload() -> [String: Any]? {
    guard let source = currentSource() else {
      return nil
    }

    var payload: [String: Any] = [
      "source": videoSourcePayload(source.source)
    ]

    if let id = source.id {
      payload["id"] = id
    }

    if let metadata = source.metadata {
      payload["metadata"] = metadataPayload(metadata)
    }

    return payload
  }

  private func videoSourcePayload(_ source: VideoSource?) -> Any {
    guard let source else {
      return NSNull()
    }

    var payload: [String: Any] = [
      "useCaching": source.useCaching,
      "contentType": source.contentType.rawValue
    ]

    if let uri = source.uri {
      payload["uri"] = uri.absoluteString
    }
    if let headers = source.headers {
      payload["headers"] = headers
    }
    if let drm = source.drm {
      payload["drm"] = drmPayload(drm)
    }
    if let metadata = source.metadata {
      payload["metadata"] = metadataPayload(metadata)
    }

    return payload
  }

  private func drmPayload(_ drm: DRMOptions) -> [String: Any] {
    var payload: [String: Any] = [
      "type": drm.type.rawValue
    ]

    if let licenseServer = drm.licenseServer {
      payload["licenseServer"] = licenseServer
    }
    if let headers = drm.headers?.compactMapValues({ $0 as? String }) {
      payload["headers"] = headers
    }
    if let contentId = drm.contentId {
      payload["contentId"] = contentId
    }
    if let certificateUrl = drm.certificateUrl {
      payload["certificateUrl"] = certificateUrl.absoluteString
    }
    if let base64CertificateData = drm.base64CertificateData {
      payload["base64CertificateData"] = base64CertificateData
    }

    return payload
  }

  private func metadataPayload(_ metadata: VideoMetadata) -> [String: Any] {
    var payload: [String: Any] = [:]

    if let title = metadata.title {
      payload["title"] = title
    }
    if let artist = metadata.artist {
      payload["artist"] = artist
    }
    if let artwork = metadata.artwork {
      payload["artwork"] = artwork.absoluteString
    }

    return payload
  }

  private func errorPayload() -> [String: Any]? {
    guard let message = error?.message else {
      return nil
    }
    return ["message": message]
  }

  private var playerDuration: Double {
    let duration = player.ref.currentItem?.duration.seconds ?? 0
    return duration.isNaN ? 0 : duration
  }

  private var isLoaded: Bool {
    player.ref.currentItem?.status == .readyToPlay
  }

  private var isBuffering: Bool {
    if player.isPlaying {
      return false
    }
    if player.ref.timeControlStatus == .waitingToPlayAtSpecifiedRate {
      return true
    }
    if let currentItem = player.ref.currentItem {
      return !currentItem.isPlaybackLikelyToKeepUp && currentItem.isPlaybackBufferEmpty
    }
    return false
  }

  private func registerTimeObserver() {
    let updateInterval = interval / 1000
    let interval = CMTime(seconds: updateInterval, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    timeToken = player.ref.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
      self?.emitStatus()
    }
  }

  // MARK: - Source helpers

  private func currentSource() -> VideoPlaylistSource? {
    guard validIndex(currentIndex) else {
      return nil
    }
    return sources[currentIndex]
  }

  private func nextIndex() -> Int? {
    guard !sources.isEmpty else {
      return nil
    }

    let nextIndex = currentIndex + 1
    if nextIndex < sources.count {
      return nextIndex
    }
    return loopMode == .all ? 0 : nil
  }

  private func previousIndex() -> Int? {
    guard !sources.isEmpty else {
      return nil
    }

    let previousIndex = currentIndex - 1
    if previousIndex >= 0 {
      return previousIndex
    }
    return loopMode == .all ? sources.count - 1 : nil
  }

  private func validIndex(_ index: Int) -> Bool {
    index >= 0 && index < sources.count
  }

  private func isCurrentItem(_ item: AVPlayerItem) -> Bool {
    if let currentItem {
      return currentItem === item
    }
    return queuePlayer.currentItem === item
  }

  private func indexPreservingCurrentSource(in newSources: [VideoPlaylistSource], currentSource: VideoPlaylistSource?) -> Int {
    guard let currentSource, !newSources.isEmpty else {
      return 0
    }

    if let id = currentSource.id,
      let index = newSources.firstIndex(where: { $0.id == id }) {
      return index
    }

    let identity = sourceIdentity(currentSource)
    return newSources.firstIndex { sourceIdentity($0) == identity } ?? 0
  }

  private func sourceIdentity(_ playlistSource: VideoPlaylistSource) -> String {
    guard let source = playlistSource.source else {
      return "null"
    }

    var parts = [
      source.uri?.absoluteString ?? "",
      source.contentType.rawValue,
      source.useCaching ? "cache" : "no-cache"
    ]

    if let headers = source.headers {
      for key in headers.keys.sorted() {
        parts.append("header:\(key)=\(headers[key] ?? "")")
      }
    }

    if let drm = source.drm {
      parts.append("drm:\(drm.type.rawValue)")
      parts.append("license:\(drm.licenseServer ?? "")")
      parts.append("contentId:\(drm.contentId ?? "")")
      parts.append("certificate:\(drm.certificateUrl?.absoluteString ?? "")")
      parts.append("certificateData:\(drm.base64CertificateData ?? "")")
    }

    return parts.joined(separator: "|")
  }

  private func cleanup() {
    guard !isDestroyed else {
      return
    }

    isDestroyed = true
    transitionGeneration += 1
    transitionTask?.cancel()
    preloadTask?.cancel()
    preloadLoader.cancelCurrentTask()
    player.videoSourceLoader.cancelCurrentTask()
    player.observer?.unregisterDelegate(delegate: self)

    if let timeToken {
      player.ref.removeTimeObserver(timeToken)
      self.timeToken = nil
    }

    player.ref.pause()
    removeAllQueuedItems()
  }
}
