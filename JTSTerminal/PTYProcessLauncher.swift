#if os(macOS)
import Darwin
import Foundation

/// Keeps forkpty's controlling-terminal behavior while closing unrelated app
/// descriptors atomically at exec. Marking a newly created Pipe CLOEXEC in the
/// parent alone leaves a race with PTY launches on another thread.
nonisolated enum PTYProcessLauncher {
    static func launch(
        executable: String,
        arguments: [String],
        environment: [String],
        currentDirectory: String? = nil,
        preservingDescriptor: Int32? = nil,
        windowSize: inout winsize
    ) throws -> (pid: pid_t, masterFd: Int32) {
        let argv = try CStringVector([executable] + arguments)
        defer { argv.release() }
        let envp = try CStringVector(environment)
        defer { envp.release() }
        guard let executablePath = strdup(executable) else {
            throw POSIXError(.ENOMEM)
        }
        defer { free(executablePath) }

        // All allocation and file-action preparation happen before fork. The
        // child only adjusts its explicit inherited channel and executes.
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addinherit_np(&actions, descriptor))
        }
        if let preservingDescriptor {
            guard preservingDescriptor > STDERR_FILENO else {
                throw POSIXError(.EINVAL)
            }
            try check(posix_spawn_file_actions_addinherit_np(&actions, preservingDescriptor))
        }
        if let currentDirectory {
            try currentDirectory.withCString { path in
                try check(posix_spawn_file_actions_addchdir(&actions, path))
            }
        }

        // Extract pointers before fork: no Swift collection work is needed in
        // the child of this multithreaded application.
        let argumentBase = argv.base
        let environmentBase = envp.base
        let inheritedDescriptor = preservingDescriptor ?? -1
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &windowSize)
        guard pid >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            if inheritedDescriptor >= 0 {
                // SETEXEC may discard CLOEXEC descriptors before applying its
                // inherit action. Clear only the approved channel in the
                // single-threaded child; the parent's flags remain untouched.
                let flags = fcntl(inheritedDescriptor, F_GETFD)
                if flags < 0 || fcntl(inheritedDescriptor, F_SETFD, flags & ~FD_CLOEXEC) < 0 {
                    _exit(127)
                }
            }
            // SETEXEC retains the PID/session/controlling TTY created by
            // forkpty; CLOEXEC_DEFAULT also closes concurrently created FDs.
            _ = posix_spawn(nil, executablePath, &actions, &attributes, argumentBase, environmentBase)
            _exit(127)
        }
        return (pid, master)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private struct CStringVector {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int

        init(_ values: [String]) throws {
            base = .allocate(capacity: values.count + 1)
            count = values.count
            for (index, value) in values.enumerated() {
                guard let pointer = strdup(value) else {
                    for previous in 0..<index { free(base[previous]) }
                    base.deallocate()
                    throw POSIXError(.ENOMEM)
                }
                base[index] = pointer
            }
            base[count] = nil
        }

        func release() {
            for index in 0..<count { free(base[index]) }
            base.deallocate()
        }
    }
}
#endif
