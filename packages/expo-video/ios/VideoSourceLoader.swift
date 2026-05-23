import AVKit

internal class VideoSourceLoader {
  private(set) var isLoading: Bool = true
  private var currentSource: VideoSource?
  private var currentTask: Task<LoadingResult, Error>?

  private var listeners = Set<WeakVideoSourceLoaderListener>()

  func registerListener(listener: VideoSourceLoaderListener) {
    let weakListener = WeakVideoSourceLoaderListener(value: listener)
    listeners.insert(weakListener)
  }

  func unregisterListener(listener: VideoSourceLoaderListener) {
    listeners.remove(WeakVideoSourceLoaderListener(value: listener))
  }

  /**
   Asynchronously loads a video item from the provided `videoSource`. If another loading operation is in progress, it will be cancelled.

   - Parameter videoSource: The source description for the video to load. If `nil`, the current player item will be cleared.
   - Parameter player: The `VideoPlayer` instance whose current item will be replaced.
   */
  func load(videoSource: VideoSource) async throws -> VideoPlayerItem? {
    isLoading = true
    if let currentTask {
      currentTask.cancel()
      notifyListeners { listener in
        listener.onLoadingCancelled(loader: self, videoSource: self.currentSource)
      }
    }

    let newTask = Task {
      return try await loadImpl(videoSource: videoSource)
    }

    self.currentTask = newTask
    self.currentSource = videoSource
    let loadingResult = try await newTask.value

    if !loadingResult.isCancelled {
      notifyListeners { listener in
        listener.onLoadingFinished(loader: self, videoSource: videoSource, result: loadingResult.value)
      }
    }

    isLoading = false
    self.currentSource = nil
    self.currentTask = nil
    return loadingResult.value
  }

  func cancelCurrentTask() {
    currentTask?.cancel()
    currentTask = nil
    isLoading = false
  }

  deinit {
    cancelCurrentTask()
  }

  private func loadImpl(videoSource: VideoSource) async throws -> LoadingResult {
    notifyListeners { listener in
      listener.onLoadingStarted(loader: self, videoSource: videoSource)
    }

    guard
      let url = videoSource.uri
    else {
      return LoadingResult(value: nil, isCancelled: false)
    }

    let safeUrl = try await url.toUrlWithPermissions()
    let playerItem = try await VideoPlayerItem(videoSource: videoSource, urlOverride: safeUrl)

    if Task.isCancelled {
      print("The loading task has been cancelled")
      return LoadingResult(value: nil, isCancelled: true)
    }

    return LoadingResult(value: playerItem, isCancelled: false)
  }

  private func notifyListeners(_ operation: @escaping (VideoSourceLoaderListener) -> Void) {
    let notify = { [weak self] in
      guard let self else {
        return
      }
      self.listeners.forEach { listener in
        if let value = listener.value {
          operation(value)
        }
      }
    }

    if Thread.isMainThread {
      notify()
    } else {
      DispatchQueue.main.sync(execute: notify)
    }
  }
}

private struct LoadingResult {
  let value: VideoPlayerItem?
  let isCancelled: Bool
}
