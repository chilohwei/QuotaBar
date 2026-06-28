import Darwin
import Foundation
import Network

enum RefreshEventReason: Hashable {
    case claudeStatusLineChanged
    case credentialsChanged(ToolKind)
    case appForegrounded
    case systemWoke
    case networkRestored
}

struct RefreshWatchTarget: Hashable {
    let url: URL
    let reason: RefreshEventReason
}

@MainActor
final class RefreshEventMonitor {
    private let onEvent: @MainActor (RefreshEventReason) -> Void
    private var fileWatchers: [FileChangeWatcher] = []
    private var debounceTasks: [RefreshEventReason: Task<Void, Never>] = [:]
    private var networkMonitor: NWPathMonitor?
    private var wasNetworkSatisfied = true

    init(onEvent: @escaping @MainActor (RefreshEventReason) -> Void) {
        self.onEvent = onEvent
    }

    func start(watchTargets: [RefreshWatchTarget]) {
        stop()

        fileWatchers = watchTargets.map { target in
            FileChangeWatcher(url: target.url) { [weak self] in
                self?.emit(target.reason, debounce: 2)
            }
        }
        fileWatchers.forEach { $0.start() }
        startNetworkMonitor()
    }

    func stop() {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        fileWatchers.forEach { $0.stop() }
        fileWatchers.removeAll()
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    func notifyAppForegrounded() {
        emit(.appForegrounded, debounce: 3)
    }

    func notifySystemDidWake() {
        emit(.systemWoke, debounce: 3)
    }

    private func emit(_ reason: RefreshEventReason, debounce: TimeInterval) {
        debounceTasks[reason]?.cancel()
        debounceTasks[reason] = Task { @MainActor [weak self] in
            let delay = UInt64(debounce * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.debounceTasks[reason] = nil
            self?.onEvent(reason)
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let isSatisfied = path.status == .satisfied
                if isSatisfied, !self.wasNetworkSatisfied {
                    self.emit(.networkRestored, debounce: 5)
                }
                self.wasNetworkSatisfied = isSatisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "QuotaBar.RefreshEventMonitor.Network"))
        networkMonitor = monitor
    }
}

@MainActor
private final class FileChangeWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var restartTask: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        configureSource()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        source?.cancel()
        source = nil
    }

    private func configureSource() {
        source?.cancel()
        source = nil

        guard let watchURL = existingWatchURL() else {
            scheduleRestart()
            return
        }

        let descriptor = Darwin.open(watchURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRestart()
            return
        }

        let nextSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        nextSource.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        nextSource.setCancelHandler {
            Darwin.close(descriptor)
        }
        source = nextSource
        nextSource.resume()
    }

    private func handleEvent() {
        onChange()
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.configureSource()
        }
    }

    private func existingWatchURL() -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return url
        }

        var candidate = url.deletingLastPathComponent()
        while !candidate.path.isEmpty {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }

        return nil
    }
}
