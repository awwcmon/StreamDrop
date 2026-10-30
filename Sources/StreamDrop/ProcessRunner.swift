import Darwin
import Foundation

enum CommandEvent: Sendable {
    case stdout(String), stderr(String), exited(Int32)
}

enum EngineWorker {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == "--engine-worker" else { return }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(126) }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        let values = Array(arguments.dropFirst(2)).map { strdup($0) }
        var argv = values + [nil]
        argv.withUnsafeMutableBufferPointer { pointer in
            _ = execv(arguments[2], pointer.baseAddress!)
        }
        perror("StreamDrop engine")
        values.forEach { free($0) }
        exit(127)
    }
}

final class ManagedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let worker: URL
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(worker: URL) { self.worker = worker }

    func untilExit<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            let result = try await withTaskCancellationHandler(operation: operation, onCancel: { self.cancel() })
            await waitForExit()
            return result
        } catch {
            cancel()
            await waitForExit()
            throw error
        }
    }

    private func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func events(executable: URL, arguments: [String]) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            let child = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let readers = DispatchGroup()
            readers.enter()
            child.terminationHandler = { _ in readers.leave() }
            child.executableURL = worker
            child.arguments = ["--engine-worker", executable.path] + arguments
            child.standardOutput = stdout
            child.standardError = stderr
            child.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PYTHONNOUSERSITE"] = "1"
            environment.removeValue(forKey: "PYTHONPATH")
            environment.removeValue(forKey: "PYTHONHOME")
            child.environment = environment
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
            }
            lock.lock()
            if cancelled {
                finished = true
                lock.unlock()
                continuation.finish(throwing: CancellationError())
                return
            }
            do {
                try child.run()
                process = child
                lock.unlock()
            } catch {
                finished = true
                lock.unlock()
                continuation.finish(throwing: error)
                return
            }
            for (handle, isError) in [(stdout.fileHandleForReading, false), (stderr.fileHandleForReading, true)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer {
                        try? handle.close()
                        readers.leave()
                    }
                    var pending = Data()
                    do {
                        var buffer = [UInt8](repeating: 0, count: 16_384)
                        while true {
                            let count = buffer.withUnsafeMutableBytes { bytes in
                                Darwin.read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
                            }
                            if count == 0 { break }
                            if count < 0 {
                                if errno == EINTR { continue }
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                            pending.append(contentsOf: buffer.prefix(count))
                            guard pending.count <= 8 * 1024 * 1024 else {
                                continuation.finish(throwing: StreamDropError.engine("The media response is too large to process."))
                                self?.cancel()
                                return
                            }
                            while let end = pending.firstIndex(of: 10) {
                                let line = String(decoding: pending[..<end], as: UTF8.self)
                                    .trimmingCharacters(in: .newlines)
                                pending.removeSubrange(...end)
                                continuation.yield(isError ? .stderr(line) : .stdout(line))
                            }
                        }
                        if !pending.isEmpty {
                            let line = String(decoding: pending, as: UTF8.self)
                            continuation.yield(isError ? .stderr(line) : .stdout(line))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        self?.cancel()
                    }
                }
            }
            readers.notify(queue: .global(qos: .utility)) { [self] in
                lock.lock()
                let wasCancelled = cancelled
                process = nil
                finished = true
                let callbacks = waiters
                waiters.removeAll()
                lock.unlock()
                callbacks.forEach { $0.resume() }
                if wasCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.yield(.exited(child.terminationStatus))
                    continuation.finish()
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        if let child { send(SIGINT, to: child) }
        lock.unlock()
        guard let child else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if process === child { send(SIGKILL, to: child) }
        }
    }

    private func send(_ signal: Int32, to process: Process) {
        let pid = process.processIdentifier
        if kill(-pid, signal) != 0, process.isRunning { _ = kill(pid, signal) }
    }
}
