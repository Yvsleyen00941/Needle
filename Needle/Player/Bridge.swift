import Foundation

/// Runs NeedleBridge inside /usr/bin/perl and passes its lines on. macOS answers Now Playing
/// questions only from Apple's own processes; perl is one, and it can load the bridge library that
/// ships inside Needle. If the bridge stops, it starts again, waiting a little longer each time.
final class Bridge {
    var onMessage: ((BridgeMessage) -> Void)?
    /// Said when the bridge can't run at all, so the menu can say why nothing shows.
    var onFailure: ((String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var failures = 0
    private var stopped = false

    static let script = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $run = DynaLoader::dl_find_symbol($lib, "needle_bridge_run") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $run);
    run();
    """

    static var libraryURL: URL? {
        let url = Bundle.main.privateFrameworksURL?.appending(path: "libNeedleBridge.dylib")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restart?.cancel()
        reader?.cancel()
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }

    /// play, pause, toggle, next, previous, seek <seconds>, refresh.
    func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func launch() {
        guard let library = Self.libraryURL else {
            onFailure?("Needle's bridge is missing from the app.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script, library.path]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        do {
            try process.run()
        } catch {
            onFailure?("Couldn't start /usr/bin/perl.")
            scheduleRestart()
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        let handle = output.fileHandleForReading
        let messages = Self.messages(from: handle)
        reader = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                if case .error(let reason) = message {
                    self.onFailure?("Now Playing can't be read: \(reason).")
                } else {
                    self.failures = 0
                }
                self.onMessage?(message)
            }
        }
    }

    /// Lines as they arrive, read off the main thread; a cover is a hundred kilobytes of text.
    nonisolated private static func messages(from handle: FileHandle) -> AsyncStream<BridgeMessage> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let message = BridgeMessage.decode(line) { continuation.yield(message) }
                    }
                }
                continuation.finish()
            }
        }
    }

    private func ended() {
        process = nil
        input = nil
        reader?.cancel()
        guard !stopped else { return }
        failures += 1
        // The bridge keeps dying without a word: say so, rather than show an empty corner silently.
        if failures >= 3 { onFailure?("Now Playing can't be read on this Mac.") }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restart?.cancel()
        let wait = min(30, pow(2, Double(max(0, failures - 1))))
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.launch()
        }
    }
}
