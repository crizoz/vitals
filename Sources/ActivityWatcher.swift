import Foundation
import CoreServices

/// Avisa cuando Claude Code escribe en sus transcripciones. La idea es de
/// CCSeva: si no hubo actividad, el consumo no pudo haber cambiado, así que
/// consultar el servidor en ese rato es puro desperdicio.
final class ActivityWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        let path = NSHomeDirectory() + "/.claude/projects"
        guard stream == nil, FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        // 2 s de latencia: junta la ráfaga de escrituras de un mismo turno en
        // un solo aviso.
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault,
                                               callback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               2.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
