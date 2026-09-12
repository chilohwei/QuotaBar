import AppKit
import Darwin

// Restarting "Codex" means bouncing every process that still holds the previous auth.json in
// memory. Two kinds exist: GUI apps that embed a codex backend (the ChatGPT desktop app runs
// `codex app-server` from inside its bundle) and loose codex processes (terminal TUI sessions,
// IDE-extension-spawned app-servers). The former are quit and relaunched gracefully — the app
// gets to prompt for unsaved work, exactly like the Cursor restart path; the latter receive
// SIGTERM and are respawned on demand by their hosts (or the user's next `codex` invocation)
// with the freshly activated credentials.
enum CodexRestartService {
    struct RunningProcess {
        let pid: pid_t
        let executablePath: String
    }

    struct RestartPlan: Equatable {
        var appBundlePaths: [String] = []
        var loosePIDs: [pid_t] = []
    }

    /// Pure partition of running codex processes: a process living inside an .app bundle is
    /// restarted via its owning app; anything else is terminated directly.
    static func makeRestartPlan(for processes: [RunningProcess]) -> RestartPlan {
        var plan = RestartPlan()
        var seenBundles = Set<String>()
        for process in processes {
            if let bundle = owningAppBundlePath(of: process.executablePath) {
                if seenBundles.insert(bundle).inserted {
                    plan.appBundlePaths.append(bundle)
                }
            } else {
                plan.loosePIDs.append(process.pid)
            }
        }
        return plan
    }

    static func owningAppBundlePath(of executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    static func runningCodexProcesses() -> [RunningProcess] {
        let declaredCount = proc_listallpids(nil, 0)
        guard declaredCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(declaredCount) + 64)
        let filledCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filledCount > 0 else { return [] }

        var result: [RunningProcess] = []
        for pid in pids.prefix(Int(filledCount)) where pid > 0 {
            // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself doesn't import.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if URL(fileURLWithPath: path).lastPathComponent == "codex" {
                result.append(RunningProcess(pid: pid, executablePath: path))
            }
        }
        return result
    }

    @MainActor
    static func restartCodex() {
        let plan = makeRestartPlan(for: runningCodexProcesses())
        AppLog.app.info("Restarting Codex: \(plan.appBundlePaths.count) host app(s), \(plan.loosePIDs.count) loose process(es)")

        for pid in plan.loosePIDs {
            kill(pid, SIGTERM)
        }
        for bundlePath in plan.appBundlePaths {
            relaunchApp(atBundlePath: bundlePath)
        }
    }

    // `terminate()` lets the host app prompt for unsaved work; the relaunch happens only after
    // it actually exits, so a cancelled quit leaves everything untouched.
    @MainActor
    private static func relaunchApp(atBundlePath bundlePath: String) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == bundleURL.path
        }) else {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return
        }

        running.terminate()
        Task { @MainActor in
            for _ in 0 ..< 40 where !running.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard running.isTerminated else {
                AppLog.app.info("Codex host \(bundleURL.lastPathComponent, privacy: .public) did not quit (likely unsaved work); skipping relaunch")
                return
            }
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
