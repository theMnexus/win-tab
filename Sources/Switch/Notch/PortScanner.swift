import Darwin
import Foundation

/// A process of yours listening on a TCP port: a dev server, a local API, a database.
struct DevServer: Identifiable, Equatable {
    let pid: pid_t
    /// Lowest first.
    let ports: [Int]
    /// Folder it was started in (its working directory).
    let folder: String
    /// "node serve.mjs", "python3 -m uvicorn main:app --port 8130".
    let command: String
    let branch: String?
    let started: Date
    /// The process and everything it started.
    let memory: UInt64
    /// "Claude Code" or "Codex" when one of them started it.
    let agent: String?
    /// Executable name: "node", "mongod", "cliproxyapi".
    let program: String
    /// Started by launchd (at login, `brew services`) rather than from a terminal or an agent.
    let background: Bool
    var id: pid_t { pid }

    /// The folder it runs from; a background service's folder is wherever launchd put it, so
    /// its own name says more.
    var name: String {
        let last = (folder as NSString).lastPathComponent
        return background || !folder.hasPrefix(NSHomeDirectory() + "/") || last.isEmpty ? program : last
    }
}

/// Finds listening TCP sockets with libproc (no `lsof`, ~10 ms for every process of yours).
/// Apps (anything inside an .app bundle, like Postman or Chrome's debug port) and system
/// daemons are left out; what's left are servers started from a terminal or an agent.
enum PortScanner {
    private struct Proc {
        let ppid: pid_t
        let path: String
    }

    static func scan() -> [DevServer] {
        let me = getpid()
        let uid = getuid()
        var procs: [pid_t: Proc] = [:]
        for pid in allPIDs() where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_uid == uid else { continue }
            procs[pid] = Proc(ppid: pid_t(info.pbi_ppid), path: path(of: pid))
        }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, p) in procs { children[p.ppid, default: []].append(pid) }

        return procs.compactMap { pid, proc -> DevServer? in
            guard pid != me, isDevProcess(proc.path), !startedByApp(pid, procs: procs) else { return nil }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { return nil }
            var bsd = proc_bsdinfo()
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            let folder = cwd(of: pid) ?? "/"
            let tree = descendants(of: pid, children: children)
            let exe = (proc.path as NSString).lastPathComponent
            return DevServer(pid: pid, ports: ports, folder: folder, command: command(of: pid) ?? exe,
                             branch: branch(near: folder), started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
                             memory: ([pid] + tree).reduce(0) { $0 + footprint($1) },
                             agent: agent(above: pid, procs: procs), program: exe == "Python" ? "python" : exe, background: proc.ppid == 1)
        }
        .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    /// SIGTERM (or SIGKILL) to the server and everything it started, children first.
    static func stop(_ pid: pid_t, force: Bool) {
        var children: [pid_t: [pid_t]] = [:]
        for p in allPIDs() where p > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(p)
        }
        let signal = force ? SIGKILL : SIGTERM
        for p in descendants(of: pid, children: children).reversed() + [pid] { kill(p, signal) }
    }

    /// Terminal-started programs: not macOS's own, not inside an app bundle (Homebrew's
    /// Python.app and Electron under node_modules are still command-line tools).
    static func isDevProcess(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        for system in ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(system) { return false }
        guard path.contains(".app/Contents/") else { return true }
        return path.contains("/Python.app/") || path.contains("/node_modules/")
    }

    /// Helpers an app runs for itself, with their program outside the bundle (Raycast Backend is
    /// Raycast's own Node in Application Support): the nearest app up the parent chain comes
    /// before any shell. A server you start has a shell (or an agent's) between it and the
    /// terminal app.
    private static func startedByApp(_ pid: pid_t, procs: [pid_t: Proc]) -> Bool {
        var current = procs[pid]?.ppid ?? 0
        for _ in 0..<12 {
            guard current > 1, let proc = procs[current] else { return false }
            let name = (proc.path as NSString).lastPathComponent
            if shells.contains(name) { return false }
            if proc.path.contains(".app/Contents/"), !proc.path.contains("/Python.app/") { return true }
            current = proc.ppid
        }
        return false
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "dash", "tcsh", "csh", "ksh", "login", "tmux", "screen"]

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0))))
    }

    private static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    private static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        var ports = Set<Int>()
        for fd in fds.prefix(Int(max(used, 0)) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(MemoryLayout<socket_fdinfo>.size)) == Int32(MemoryLayout<socket_fdinfo>.size),
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // Network byte order in the low 16 bits.
            let port = Int(UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).byteSwapped)
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    private static func footprint(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? usage.ri_phys_footprint : 0
    }

    private static func descendants(of pid: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var out: [pid_t] = []
        var queue = children[pid] ?? []
        while let next = queue.popLast(), out.count < 500 {
            out.append(next)
            queue += children[next] ?? []
        }
        return out
    }

    /// Claude Code or Codex somewhere up the parent chain.
    private static func agent(above pid: pid_t, procs: [pid_t: Proc]) -> String? {
        var current = procs[pid]?.ppid ?? 0
        for _ in 0..<32 where current > 1 {
            guard let p = procs[current] else { return nil }
            let exe = (p.path as NSString).lastPathComponent.lowercased()
            if exe == "claude" || p.path.contains("/claude-code/") { return "Claude Code" }
            if exe == "codex" { return "Codex" }
            current = p.ppid
        }
        return nil
    }

    // MARK: - Command line and git

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then the arguments.
    static func command(of pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(buf.prefix(size)))
    }

    static func parseArguments(_ buf: [UInt8]) -> String? {
        guard buf.count > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 } // executable path
        while i < buf.count, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        guard let first = args.first else { return nil }
        // Homebrew's interpreter runs as ".../Python.app/Contents/MacOS/Python".
        let program = (first as NSString).lastPathComponent
        let home = NSHomeDirectory()
        let rest = args.dropFirst().map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let line = ([program == "Python" ? "python" : program] + rest).joined(separator: " ")
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// The branch checked out in the repository holding `folder`, read from `.git/HEAD`. Only
    /// your own folders: Homebrew's prefix is a git checkout too.
    static func branch(near folder: String) -> String? {
        let fm = FileManager.default
        var dir = folder
        let home = NSHomeDirectory()
        guard folder.hasPrefix(home + "/") else { return nil }
        while dir.count > 1, dir != home {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                // A worktree's .git is a file: "gitdir: /path/to/repo/.git/worktrees/name".
                let gitDir = isDir.boolValue ? git
                    : (try? String(contentsOfFile: git, encoding: .utf8)).flatMap { text -> String? in
                        guard text.hasPrefix("gitdir:") else { return nil }
                        let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                        return path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
                    }
                guard let gitDir, let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                return parseHead(head)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// "ref: refs/heads/main" → "main"; a detached HEAD → its short hash.
    static func parseHead(_ head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        return text.count >= 7 && text.allSatisfy(\.isHexDigit) ? String(text.prefix(7)) : nil
    }
}
