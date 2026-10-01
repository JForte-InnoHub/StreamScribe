import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - StreamScribe Web Portal — job queue + API
//
// THE ONE RULE THIS FILE IS BUILT AROUND: StreamScribe has exactly one
// TranscriptionEngine, and it runs one session at a time (shared singletons,
// VoiceprintService resets on every start(), one GPU). So web users don't get
// their own sessions — they get a FIFO QUEUE that feeds the one engine, exactly
// as if someone were sitting at the Mac pasting links and pressing Start.
//
// Dispatching a job reproduces the Mac's own paste → probe → Start sequence:
//   1. Mirror the job's input into the Mac's URL field (ContentView observes
//      `macURLMirror`), so the Mac UI always shows what it's working on and its
//      probe cache matches the field. The sidebar's onChange kicks the probe;
//      if the window is closed we kick it ourselves.
//   2. Wait for the probe to settle. This matters: start() reuses the cached
//      probe duration and title from whatever was probed last, so starting a
//      job without probing it first would inherit the previous URL's duration
//      (and could misclassify live vs static).
//   3. Apply the job's settings (PortalSettingsApplier), start(), confirm the
//      engine actually took the session, and restore the Mac's settings when
//      the session ends.
//
// While the engine still holds a job's session — during the run AND after it
// finishes, until another session starts — the job is "live": its snapshot
// follows the engine, and speaker renames / pins from the web go straight to the
// engine (so the Mac sees them too). After that the snapshot is frozen and web
// edits apply to the snapshot only.

struct PortalIdentity {
    let email: String
    /// A browser on this Mac itself (not through Cloudflare).
    let isLocal: Bool
}

@MainActor
final class PortalJobQueue: ObservableObject {
    static let shared = PortalJobQueue()

    // MARK: Settings keys

    static let enabledKey = "portal.enabled"
    static let portKey = "portal.port"
    static let pausedKey = "portal.queuePaused"
    static let adminEmailsKey = "portal.adminEmails"
    static let retentionDaysKey = "portal.retentionDays"
    static let pendingRestoreKey = "portal.pendingRestore"

    static let defaultPort: Int = 8795
    static let defaultRetentionDays: Int = 30
    static let maxUploadBytes: Int64 = 10 * 1024 * 1024 * 1024   // 10 GB
    /// Browser upload chunk. Well under Cloudflare's 100 MB request-body cap.
    static let uploadChunkBytes: Int = 16 * 1024 * 1024
    static let uploadExtensions: [String] = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "oga", "opus", "wma", "aif", "aiff", "caf",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "3gp", "wmv", "flv",
    ]

    // MARK: Published (drives the Mac's Settings section / sidebar)

    @Published private(set) var serverState: PortalServerState = .stopped
    /// True while a job is between "picked from the queue" and "engine confirmed
    /// it started". The Mac's Start button is disabled during this window.
    @Published private(set) var isDispatching = false
    /// ContentView copies this into the Mac's URL field.
    @Published private(set) var macURLMirror: String?
    @Published private(set) var summary: String = "No jobs"
    @Published var isPaused: Bool = UserDefaults.standard.bool(forKey: PortalJobQueue.pausedKey) {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: Self.pausedKey)
            refreshSummary()
            if !isPaused { pump() }
        }
    }

    // MARK: State

    private weak var engine: TranscriptionEngine?
    private let server = PortalServer()
    private var cancellables = Set<AnyCancellable>()
    private var jobs: [PortalJob] = []                 // oldest first
    private var indexes: [UUID: PortalTranscriptIndex] = [:]
    private var uploads: [UUID: PortalUploadSession] = [:]
    private var activeJobID: UUID?                     // on the engine now
    private var attachedJobID: UUID?                   // engine still holds its session
    private var dispatchingJobID: UUID?
    private var cancelDuringDispatch: Set<UUID> = []
    private var restoreItems: [PortalRestoreItem] = []
    private var pendingSaves: Set<UUID> = []
    private var sleepActivity: NSObjectProtocol?
    private var retentionTimer: Timer?
    private var didLoad = false
    private var modelCache: (at: Date, models: [String: [PortalOptionDTO]])?
    private var probeCache: [String: (at: Date, result: PortalProbeDTO)] = [:]
    private var probesInFlight: [String: Task<PortalProbeDTO, Never>] = [:]
    /// At most this many link checks run at once (each is a yt-dlp or ffmpeg
    /// process). Every one is a request from the Mini's IP — the same IP a
    /// running YouTube job depends on — so they are kept few and cached.
    private static let maxConcurrentProbes = 2
    private static let probeCacheSeconds: TimeInterval = 600
    /// Changes every launch; tells browsers to discard diff state.
    let epoch = UUID().uuidString

    private init() {}

    // MARK: - Lifecycle

    /// Called from the app's WindowGroup `.task`. Idempotent.
    func attach(engine: TranscriptionEngine) {
        if self.engine === engine && didLoad { return }
        self.engine = engine

        if !didLoad {
            didLoad = true
            restorePendingSettingsFromLastLaunch()
            loadJobs()
            cleanupStaleUploads()
            applyRetention()
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
                Task { @MainActor in PortalJobQueue.shared.applyRetention() }
            }
        }

        cancellables.removeAll()
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleEngineState() }
            .store(in: &cancellables)
        engine.$segments
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.syncAttached() }
            .store(in: &cancellables)
        Publishers.Merge4(
            engine.$speakerNames.map { _ in () },
            engine.$pinnedQuotes.map { _ in () },
            engine.$detectedTitle.map { _ in () },
            VoiceprintService.shared.$identifications.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncAttached() }
            .store(in: &cancellables)
        engine.$sessionStartedAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkAttachment() }
            .store(in: &cancellables)
        // A download finishing (from the portal or the Mac sidebar) changes
        // what the portal can offer — drop the cached model list.
        ModelDownloadManager.shared.$statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.modelCache = nil }
            .store(in: &cancellables)

        applyServerSetting()
        refreshSummary()
        pump()
    }

    /// Start or stop the HTTP server to match Settings. Safe to call repeatedly.
    func applyServerSetting() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: Self.enabledKey)
        let storedPort = d.integer(forKey: Self.portKey)
        let port = (1024...65535).contains(storedPort) ? storedPort : Self.defaultPort

        server.stop()
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        guard enabled else {
            serverState = .stopped
            return
        }
        server.start(port: UInt16(port), handler: { request in
            await PortalJobQueue.shared.handle(request)
        }, onState: { state in
            PortalJobQueue.shared.serverState = state
        })
        // A server that sleeps is a server that's down, and App Nap throttles
        // timers in apps with no visible window. Hold an activity for as long
        // as the portal is on.
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "StreamScribe web portal is serving requests")
    }

    // MARK: - Queue runner

    private func pump() {
        guard let engine, !isPaused, !isDispatching, activeJobID == nil,
              !engine.state.isActive else { return }
        guard let next = jobs.first(where: { $0.status == .queued }) else { return }
        // Claim the engine synchronously so a second pump() in the same
        // run-loop turn can't dispatch a second job.
        isDispatching = true
        dispatchingJobID = next.id
        refreshSummary()
        let id = next.id
        Task { await self.dispatch(id) }
    }

    private func dispatch(_ id: UUID) async {
        await runDispatch(id)
        isDispatching = false
        dispatchingJobID = nil
        cancelDuringDispatch.remove(id)
        refreshSummary()
        // Processes the new session's current state if the job started, or
        // pumps the next job if it didn't. (A pump() inside runDispatch would
        // be a no-op: isDispatching is still true there.)
        handleEngineState()
    }

    private func runDispatch(_ id: UUID) async {
        guard let engine, var job = job(id), job.status == .queued else { return }

        // Final sync of the previous transcript before the engine lets go of it.
        syncAttached()
        attachedJobID = nil

        job.status = .preparing
        job.message = "Checking source…"
        job.startedAt = Date()
        update(job, saveNow: true)

        // 1. Mirror into the Mac's URL field; let its onChange kick the probe.
        let input = job.input
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let generationBefore = engine.probeGeneration
        macURLMirror = input
        var probeKicked = false
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if engine.probeGeneration != generationBefore && engine.lastProbeInput == trimmed {
                probeKicked = true
                break
            }
        }
        if !probeKicked { engine.beginProbe(for: input) }

        // 2. Let the probe settle (yt-dlp probes take up to ~15 s).
        let deadline = Date().addingTimeInterval(45)
        while engine.probeStatus == .probing && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if cancelDuringDispatch.contains(id) { break }
        }
        if cancelDuringDispatch.remove(id) != nil {
            if var j = self.job(id) {
                j.status = .cancelled
                j.message = "Cancelled before it started"
                j.finishedAt = Date()
                update(j, saveNow: true)
            }
            return
        }

        // If a session started on the Mac while we were probing, go back in line.
        if engine.state.isActive {
            requeue(id, message: "Waiting for a session started on the Mac to finish")
            return
        }

        // 3. Apply settings and start.
        let resolvedStatic: Bool?
        switch engine.probeStatus {
        case .finite: resolvedStatic = true
        case .live: resolvedStatic = false
        default: resolvedStatic = nil
        }
        restoreItems = PortalSettingsApplier.apply(job.settings, resolvedStatic: resolvedStatic, engine: engine)
        savePendingRestore()

        if var j = self.job(id) {
            j.message = "Starting…"
            update(j)
        }
        let generationBeforeStart = engine.sessionGeneration
        await engine.start(urlString: input)

        // 4. Reconcile: did the engine take THIS session?
        guard engine.sessionGeneration != generationBeforeStart else {
            // start() returned at its `guard !state.isActive` — something else
            // got the engine first.
            restoreSettings()
            if cancelDuringDispatch.remove(id) != nil {
                // Stop was pressed while we were starting: honour it rather
                // than quietly putting the job back in line.
                if var j = self.job(id) {
                    j.status = .cancelled
                    j.message = "Cancelled before it started"
                    j.finishedAt = Date()
                    update(j, saveNow: true)
                }
                return
            }
            requeue(id, message: "Waiting for a session started on the Mac to finish")
            return
        }
        if case .error(let message) = engine.state {
            // Early validation failure inside start() (bad URL, missing file…).
            // No snapshot: start() returns before resetting the transcript, so
            // the engine still holds the PREVIOUS session's segments.
            restoreSettings()
            if var j = self.job(id) {
                j.status = .failed
                j.message = message
                j.finishedAt = Date()
                update(j, saveNow: true)
            }
            return
        }

        if var j = self.job(id) {
            j.engineSession = engine.sessionGeneration
            j.status = .preparing
            update(j)
        }
        activeJobID = id
        attachedJobID = id
        print("[Portal] Job \(id.uuidString.prefix(8)) started on the engine: \(job.displaySource)")

        // Stop pressed while start() was still running: honour it now that
        // there is a session to stop. (stopJob already recorded stoppedBy.)
        if cancelDuringDispatch.remove(id) != nil {
            engine.stop()
        }
    }

    private func requeue(_ id: UUID, message: String) {
        guard var j = job(id) else { return }
        j.status = .queued
        j.message = message
        j.startedAt = nil
        update(j, saveNow: true)
        // pump() runs again when the engine goes idle (state sink).
    }

    // MARK: - Engine observation

    private func handleEngineState() {
        guard let engine else { return }
        defer { refreshSummary() }
        guard !isDispatching else { return }

        guard let id = activeJobID, var job = job(id) else {
            pump()
            return
        }
        switch engine.state {
        case .preparing(let label):
            job.status = .preparing
            job.message = label
            update(job)
        case .streaming:
            job.status = .running
            job.message = nil
            update(job)
        case .finishing:
            job.status = .finishing
            job.message = "Finishing up"
            update(job)
        case .finalizing(let label):
            job.status = .finishing
            job.message = label
            update(job)
        case .idle:
            finishActive(error: nil)
        case .error(let message):
            finishActive(error: message)
        }
    }

    private func finishActive(error: String?) {
        guard let id = activeJobID else { return }
        syncAttached()   // final transcript while the token still matches
        activeJobID = nil
        restoreSettings()
        guard var job = job(id) else { pump(); return }
        job.finishedAt = Date()
        if let error {
            job.status = .failed
            job.message = error
        } else {
            job.status = .completed
            if let who = job.stoppedBy {
                job.message = "Stopped by \(who)"
            } else if job.segments.isEmpty {
                job.message = "Finished — no speech was transcribed"
            } else {
                job.message = nil
            }
        }
        update(job, saveNow: true)
        print("[Portal] Job \(id.uuidString.prefix(8)) \(job.status.rawValue) (\(job.segments.count) segments).")
        pump()
    }

    /// A new session (from anyone) replaces the engine's transcript → detach.
    /// Triggered by `$sessionStartedAt`, but decided by `sessionGeneration`:
    /// sessionStartedAt goes nil at every session END, which must not detach
    /// (the finished transcript is still on the Mac and still editable).
    private func checkAttachment() {
        guard let engine, let id = attachedJobID, let job = job(id) else { return }
        if engine.sessionGeneration != job.engineSession {
            attachedJobID = nil
            saveNow(id)
        }
    }

    private func isAttached(_ job: PortalJob) -> Bool {
        guard let engine, attachedJobID == job.id, let token = job.engineSession else { return false }
        return engine.sessionGeneration == token
    }

    /// Copy the engine's transcript, names and pins into the attached job.
    private func syncAttached() {
        guard let engine, let id = attachedJobID, var job = job(id) else { return }
        guard isAttached(job) else {
            attachedJobID = nil
            return
        }

        // Word timings are dropped from the snapshot: the portal and exporters
        // don't use them and they are most of the bytes on disk.
        let segments = engine.segments.map { seg -> TranscriptSegment in
            var copy = seg
            copy.words = nil
            return copy
        }
        var index = indexFor(job)
        let segmentsChanged = index.update(segments)

        var voiceprint: [String: String] = [:]
        var seen = Set<String>()
        for seg in segments {
            guard let label = seg.speaker, seen.insert(label).inserted else { continue }
            let info = VoiceprintService.shared.displayInfo(forClusterId: label)
            if info.isIdentified { voiceprint[label] = info.name }
        }
        let names = engine.speakerNames
        let pins = engine.pinnedQuotes
        let title = engine.detectedTitle ?? job.title
        let metaChanged = names != job.speakerNames || voiceprint != job.voiceprintNames
            || pins != job.pins || title != job.title
        if metaChanged { index.bumpMeta() }
        indexes[id] = index

        guard segmentsChanged || metaChanged || job.processedSeconds != engine.processedDurationSeconds else { return }
        job.segments = segments
        job.speakerNames = names
        job.voiceprintNames = voiceprint
        job.pins = pins
        job.title = title
        job.durationSeconds = engine.totalDurationSeconds
        job.processedSeconds = engine.processedDurationSeconds
        job.resolvedMode = engine.resolvedSessionMode.rawValue
        update(job)
    }

    // MARK: - Settings restore

    private func restoreSettings() {
        engine?.portalEngineChoiceActive = false
        guard !restoreItems.isEmpty else { return }
        PortalSettingsApplier.restore(restoreItems, engine: engine)
        restoreItems = []
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    private func savePendingRestore() {
        if restoreItems.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
        } else if let data = try? JSONEncoder().encode(restoreItems) {
            UserDefaults.standard.set(data, forKey: Self.pendingRestoreKey)
        }
    }

    /// If the app quit mid-job, the UserDefaults-backed settings the job changed
    /// (cleanup, backlog-from-start, expected speakers) are still changed. Put
    /// them back before anything reads them.
    private func restorePendingSettingsFromLastLaunch() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingRestoreKey),
              let items = try? JSONDecoder().decode([PortalRestoreItem].self, from: data) else { return }
        print("[Portal] Restoring \(items.count) setting(s) left over from an interrupted job.")
        PortalSettingsApplier.restore(items, engine: nil)
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    // MARK: - Job storage

    private func job(_ id: UUID) -> PortalJob? { jobs.first { $0.id == id } }

    private func update(_ job: PortalJob, saveNow now: Bool = false) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else {
            jobs.append(job)
        }
        if now { saveNow(job.id) } else { scheduleSave(job.id) }
        refreshSummary()
    }

    private func indexFor(_ job: PortalJob) -> PortalTranscriptIndex {
        if let existing = indexes[job.id] { return existing }
        var fresh = PortalTranscriptIndex()
        fresh.update(job.segments)
        fresh.bumpMeta()
        indexes[job.id] = fresh
        return fresh
    }

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("StreamScribe").appendingPathComponent("Portal")
    }
    private static var jobsDirectory: URL { rootDirectory.appendingPathComponent("jobs") }
    private static var uploadsDirectory: URL { rootDirectory.appendingPathComponent("uploads") }

    private static func jobFile(_ id: UUID) -> URL {
        jobsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    private func saveNow(_ id: UUID) {
        pendingSaves.remove(id)
        guard let job = job(id) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.jobsDirectory, withIntermediateDirectories: true)
            let data = try Self.makeEncoder().encode(job)
            try data.write(to: Self.jobFile(id), options: .atomic)
        } catch {
            print("[Portal] Could not save job \(id.uuidString.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Coalesced save — a running job updates twice a second; disk gets it
    /// every 15 s (and immediately on every status change).
    private func scheduleSave(_ id: UUID) {
        guard pendingSaves.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.pendingSaves.contains(id) else { return }
            self.saveNow(id)
        }
    }

    private func loadJobs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.jobsDirectory, includingPropertiesForKeys: nil) else { return }
        let decoder = Self.makeDecoder()
        var loaded: [PortalJob] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var job = try? decoder.decode(PortalJob.self, from: data) else {
                print("[Portal] Skipping unreadable job file \(file.lastPathComponent)")
                continue
            }
            if job.status.isOnEngine {
                job.status = .interrupted
                job.message = "StreamScribe quit while this job was running. The transcript up to that point is kept."
                job.finishedAt = job.finishedAt ?? Date()
            }
            loaded.append(job)
        }
        jobs = loaded.sorted { $0.createdAt < $1.createdAt }
        for job in jobs where job.status == .interrupted { saveNow(job.id) }
        print("[Portal] Loaded \(jobs.count) job(s); \(jobs.filter { $0.status == .queued }.count) queued.")
    }

    private func deleteJobFiles(_ job: PortalJob) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.jobFile(job.id))
        if let dir = job.uploadDirectory,
           !jobs.contains(where: { $0.id != job.id && $0.uploadDirectory == dir }) {
            try? fm.removeItem(at: URL(fileURLWithPath: dir))
        }
    }

    private func applyRetention() {
        let d = UserDefaults.standard
        let days = d.object(forKey: Self.retentionDaysKey) == nil
            ? Self.defaultRetentionDays : d.integer(forKey: Self.retentionDaysKey)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = jobs.filter {
            $0.status.isTerminal && ($0.finishedAt ?? $0.createdAt) < cutoff && $0.id != attachedJobID
        }
        guard !expired.isEmpty else { return }
        for job in expired {
            jobs.removeAll { $0.id == job.id }
            indexes[job.id] = nil
            deleteJobFiles(job)
        }
        print("[Portal] Retention: removed \(expired.count) job(s) older than \(days) day(s).")
        refreshSummary()
    }

    /// Upload folders no job refers to, older than a day, are abandoned uploads.
    private func cleanupStaleUploads() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: Self.uploadsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let referenced = Set(jobs.compactMap { $0.uploadDirectory })
        let cutoff = Date().addingTimeInterval(-86_400)
        for dir in dirs where !referenced.contains(dir.path) {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: dir) }
        }
    }

    private func refreshSummary() {
        let queued = jobs.filter { $0.status == .queued }.count
        var parts: [String] = []
        if let id = activeJobID ?? dispatchingJobID, let job = job(id) {
            parts.append("Running: \(job.title ?? job.displaySource)")
        }
        if queued > 0 { parts.append("\(queued) queued") }
        if isPaused { parts.append("queue paused") }
        let text = parts.isEmpty ? "Idle — \(jobs.count) job(s) on file" : parts.joined(separator: " · ")
        if text != summary { summary = text }
    }

    // MARK: - Identity

    private func identity(for request: PortalHTTPRequest) -> PortalIdentity? {
        if let email = request.header("cf-access-authenticated-user-email")?
            .trimmingCharacters(in: .whitespaces), !email.isEmpty {
            return PortalIdentity(email: email.lowercased(), isLocal: false)
        }
        // Came through Cloudflare (or any reverse proxy) but WITHOUT an Access
        // identity → the hostname isn't protected by an Access policy. Fail
        // closed rather than serve an open transcription server.
        if request.header("cf-connecting-ip") != nil || request.header("cf-ray") != nil
            || request.header("x-forwarded-for") != nil {
            return nil
        }
        // The listener is loopback-only, so this is a browser on the Mac itself.
        return PortalIdentity(email: "local", isLocal: true)
    }

    private func adminEmails() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: Self.adminEmailsKey) ?? ""
        return Set(raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func isAdmin(_ who: PortalIdentity) -> Bool {
        who.isLocal || adminEmails().contains(who.email)
    }

    private func canManage(_ job: PortalJob, _ who: PortalIdentity) -> Bool {
        isAdmin(who) || job.submittedBy == who.email
    }

    // MARK: - HTTP routing

    func handle(_ request: PortalHTTPRequest) async -> PortalHTTPResponse {
        guard let who = identity(for: request) else {
            return .error(403, "This portal must be reached through Cloudflare Access. The hostname is not protected by an Access policy.")
        }
        let c = request.pathComponents
        let method = request.method

        if method == "GET" && (c.isEmpty || c == ["index.html"]) {
            return .html(PortalPage.html)
        }
        if method == "GET" && c == ["healthz"] {
            return .json(["ok": "true"])
        }
        guard c.first == "api" else { return .error(404, "Not found") }

        // CSRF guard: browsers won't attach a custom header cross-site without a
        // CORS preflight, which this server never approves.
        if method == "POST" && request.header("x-streamscribe-portal") != "1" {
            return .error(403, "Missing portal request header")
        }

        let r = Array(c.dropFirst())
        switch (method, r.count) {
        case ("GET", 1) where r[0] == "status":
            return .dto(statusDTO(who))
        case ("GET", 1) where r[0] == "jobs":
            return .dto(jobs.reversed().map { jobDTO($0, who) })
        case ("POST", 1) where r[0] == "jobs":
            return createURLJob(request, who)
        case ("POST", 2) where r[0] == "queue" && r[1] == "pause":
            guard isAdmin(who) else { return .error(403, "Only portal admins can pause the queue") }
            guard let body = request.decodeBody(PortalPauseBody.self) else { return .error(400, "Expected {\"paused\": true|false}") }
            isPaused = body.paused
            return .dto(statusDTO(who))
        case ("POST", 1) where r[0] == "uploads":
            return createUpload(request, who)
        case ("POST", 1) where r[0] == "probe":
            return await probeLink(request)
        case ("POST", 2) where r[0] == "models" && r[1] == "download":
            return startModelDownload(request, who)
        case ("POST", 3) where r[0] == "uploads":
            guard let id = UUID(uuidString: r[1]) else { return .error(404, "Unknown upload") }
            switch r[2] {
            case "chunk": return receiveChunk(id, request, who)
            case "finish": return finishUpload(id, request, who)
            case "abort": return abortUpload(id, who)
            default: return .error(404, "Not found")
            }
        default:
            break
        }

        // /api/jobs/{id}/…
        guard r.count >= 2, r[0] == "jobs", let id = UUID(uuidString: r[1]), let job = job(id) else {
            return .error(404, "Not found")
        }
        let action = r.count >= 3 ? r[2] : ""
        switch (method, action) {
        case ("GET", ""):
            return .dto(jobDTO(job, who))
        case ("GET", "transcript"):
            let since = Int(request.query["since"] ?? "") ?? 0
            return transcriptResponse(job, since: since, clientEpoch: request.query["epoch"] ?? "", who: who)
        case ("GET", "export"):
            return exportResponse(job, format: request.query["format"] ?? "docx")
        case ("POST", "stop"):
            return stopJob(job, who)
        case ("POST", "retry"):
            return retryJob(job, who)
        case ("POST", "delete"):
            return deleteJob(job, who)
        case ("POST", "speakers"):
            return renameSpeaker(job, request, who)
        case ("POST", "pins") where r.count == 3:
            return addPin(job, request, who)
        case ("POST", "pins") where r.count == 5 && r[4] == "delete":
            guard let pinID = UUID(uuidString: r[3]) else { return .error(404, "Unknown pin") }
            return removePin(job, pinID, who)
        default:
            return .error(404, "Not found")
        }
    }

    // MARK: - Endpoints: status / jobs

    private func statusDTO(_ who: PortalIdentity) -> PortalStatusDTO {
        let engine = self.engine
        let state = engine?.state ?? .idle
        let busyWithMac = state.isActive && activeJobID == nil && !isDispatching
        let d = UserDefaults.standard

        let languages = TranscriptionEngine.availableLanguages.map {
            PortalOptionDTO(id: $0.code ?? "auto", label: $0.name)
        }
        let formats: [TranscriptFormat] = [.docx, .plainText, .markdown, .rtf, .srt, .vtt, .json]
        return PortalStatusDTO(
            me: .init(email: who.email, isLocal: who.isLocal, isAdmin: isAdmin(who)),
            engine: .init(
                label: state.displayLabel,
                active: state.isActive,
                busyWithMacSession: busyWithMac,
                title: engine?.detectedTitle,
                activeJobId: (activeJobID ?? dispatchingJobID)?.uuidString),
            queue: .init(paused: isPaused, queued: jobs.filter { $0.status == .queued }.count),
            options: .init(
                modes: [.init(id: "auto", label: "Auto (detect live vs. recording)"),
                        .init(id: "live", label: "Live"),
                        .init(id: "static", label: "Recording (whole-file, best speaker labels)")],
                engines: [.init(id: "auto", label: "Auto"),
                          .init(id: "whisperKit", label: "WhisperKit"),
                          .init(id: "parakeet", label: "Parakeet"),
                          .init(id: "canary", label: "Canary")],
                // Short names, as in the Mac sidebar's compact labels.
                diarizers: [.init(id: "fluidAudio", label: "FluidAudio"),
                            .init(id: "speakerKit", label: "SpeakerKit"),
                            .init(id: "sortformer", label: "Sortformer"),
                            .init(id: "off", label: "Off")],
                languages: languages,
                exportFormats: formats.map { .init(id: $0.fileExtension, label: $0.rawValue) },
                models: downloadedModels(),
                downloads: downloadStates(),
                uploadExtensions: Self.uploadExtensions,
                maxUploadBytes: Self.maxUploadBytes,
                chunkBytes: Self.uploadChunkBytes),
            defaults: .init(
                mode: engine?.sessionMode.rawValue ?? "auto",
                // Always Auto: the Mac's own engine field shows whatever the
                // per-mode default last picked, which isn't a choice anyone made.
                engine: "auto",
                models: [
                    "whisperKit": engine?.whisperModelName ?? TranscriptionEngine.defaultWhisperModel,
                    "parakeet": engine?.parakeetModelName ?? TranscriptionEngine.defaultParakeetModel,
                ],
                diarization: engine.map { PortalJobSettings.id(for: $0.diarizationEngine) } ?? "fluidAudio",
                language: engine?.selectedLanguageCode ?? "auto",
                expectedSpeakers: TranscriptionEngine.expectedSpeakerCount,
                liveFromStart: AudioStreamExtractor.liveFromStartEnabled,
                cleanup: d.bool(forKey: TranscriptCleanupService.enabledKey)),
            epoch: epoch)
    }

    // MARK: - Link check (probe before submitting)

    /// Check a pasted link the way the Mac's URL field does — live vs
    /// recording, duration, title, or why it can't be read — WITHOUT using
    /// the engine's probe. That probe is a single shared slot (beginProbe
    /// cancels the previous one, and start() reuses its cached duration),
    /// so web users checking links would cancel the Mac's own probe or the
    /// one the dispatcher runs just before starting a job.
    /// `TranscriptionEngine.probeForPortal` runs the same resolution and
    /// per-source strategy with no shared state, so any number can overlap
    /// with each other and with a running session. Identical links share
    /// one in-flight check and a 10-minute cache.
    private func probeLink(_ request: PortalHTTPRequest) async -> PortalHTTPResponse {
        guard let body = request.decodeBody(PortalProbeBody.self) else {
            return .error(400, "Expected {\"url\": \"https://…\"}")
        }
        let checked = Self.validateSubmittedURL(body.url)
        guard let url = checked.url else { return .error(422, checked.problem ?? "Invalid link") }
        let key = url.absoluteString

        if let cached = probeCache[key], Date().timeIntervalSince(cached.at) < Self.probeCacheSeconds {
            return .dto(cached.result)
        }
        if let running = probesInFlight[key] {
            return .dto(await running.value)
        }
        guard probesInFlight.count < Self.maxConcurrentProbes else {
            return .dto(PortalProbeDTO(url: key, kind: "busy", durationSeconds: nil, title: nil,
                                       source: nil, message: "Other links are being checked; retrying shortly."))
        }

        let task = Task { () -> PortalProbeDTO in
            let result = await TranscriptionEngine.probeForPortal(url: url)
            switch result.kind {
            case .recording(let seconds):
                return PortalProbeDTO(url: key, kind: "recording", durationSeconds: seconds, title: result.title,
                                      source: result.source.rawValue, message: nil)
            case .live:
                return PortalProbeDTO(url: key, kind: "live", durationSeconds: nil, title: result.title,
                                      source: result.source.rawValue, message: nil)
            case .failed(let reason):
                return PortalProbeDTO(url: key, kind: "failed", durationSeconds: nil, title: result.title,
                                      source: result.source.rawValue, message: reason)
            }
        }
        probesInFlight[key] = task
        let dto = await task.value
        probesInFlight[key] = nil
        // Failures aren't cached: they're often transient (network, a stream
        // that hasn't started yet), and a retry should actually retry.
        if dto.kind != "failed" {
            probeCache[key] = (Date(), dto)
            if probeCache.count > 200 {
                let cutoff = Date().addingTimeInterval(-Self.probeCacheSeconds)
                probeCache = probeCache.filter { $0.value.at > cutoff }
            }
        }
        print("[Portal] Link check \(dto.kind)\(dto.durationSeconds.map { String(format: " %.0fs", $0) } ?? ""): \(key)")
        return .dto(dto)
    }

    // MARK: - Model availability

    /// Models on the Mini's disk, per engine. The portal only offers these:
    /// starting a job on a missing model would try to download it mid-job
    /// (and on the managed fleet, HuggingFace isn't reachable at all).
    /// Cached for a minute — the probes walk the model folders, and
    /// /api/status is polled every few seconds by every open page.
    private func downloadedModels(forceRefresh: Bool = false) -> [String: [PortalOptionDTO]] {
        if !forceRefresh, let cache = modelCache, Date().timeIntervalSince(cache.at) < 60 {
            return cache.models
        }
        let whisper = TranscriptionEngine.availableWhisperModels
            .filter { WhisperKitBackend.isModelCached(modelName: $0) }
            .map { PortalOptionDTO(id: $0, label: TranscriptionEngine.displayName(forWhisperModel: $0)) }
        let parakeet = TranscriptionEngine.availableParakeetModels
            .filter { ParakeetBackend.isModelCached(modelRepo: $0) }
            .map { PortalOptionDTO(id: $0, label: TranscriptionEngine.displayName(forParakeetModel: $0)) }
        let canary = CanaryBackend.isModelCached()
            ? [PortalOptionDTO(id: "canary-1b-v2", label: "Canary 1B v2 (int4)")]
            : []
        let models = ["whisperKit": whisper, "parakeet": parakeet, "canary": canary]
        modelCache = (Date(), models)
        return models
    }

    // MARK: - Model downloads

    /// The model a portal download fetches for each engine: the Mini's
    /// currently selected model (what Auto would use), or Canary's only one.
    private func downloadTarget(_ engineID: String) -> (key: ModelDownloadManager.ModelKey, model: String, label: String)? {
        switch engineID {
        case "whisperKit":
            let name = engine?.whisperModelName ?? TranscriptionEngine.defaultWhisperModel
            return (.whisper(modelName: name), name, TranscriptionEngine.displayName(forWhisperModel: name))
        case "parakeet":
            let repo = engine?.parakeetModelName ?? TranscriptionEngine.defaultParakeetModel
            return (.parakeet(modelRepo: repo), repo, TranscriptionEngine.displayName(forParakeetModel: repo))
        case "canary":
            // Size from the R2 object's Content-Length (532,228,379 bytes).
            return (.canary, "canary-1b-v2", "Canary 1B v2 (int4) — about 530 MB download")
        default:
            return nil
        }
    }

    private func downloadStates() -> [String: PortalDownloadDTO] {
        var out: [String: PortalDownloadDTO] = [:]
        for id in ["whisperKit", "parakeet", "canary"] {
            guard let target = downloadTarget(id) else { continue }
            let status = ModelDownloadManager.shared.statuses[target.key] ?? .unknown
            let state: String
            var progress: Double? = nil
            var message: String? = nil
            switch status {
            case .downloading(_, let p):
                state = "downloading"
                progress = p.map { max(0, min(1, $0)) }
            case .loading:
                state = "loading"
            case .error(let m):
                state = "error"
                message = m
            default:
                state = "idle"
            }
            out[id] = PortalDownloadDTO(model: target.model, label: target.label, state: state,
                                        progress: progress, message: message)
        }
        return out
    }

    /// Download an engine's model to the Mini, through the same
    /// ModelDownloadManager path as the Mac sidebar's Download buttons (R2
    /// mirror first). Admins only: it's a large download on the Mini's
    /// connection, which a running YouTube job also depends on.
    private func startModelDownload(_ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard isAdmin(who) else { return .error(403, "Only portal admins can download models to the Mac Mini") }
        guard let body = request.decodeBody(PortalDownloadBody.self),
              let target = downloadTarget(body.engine) else {
            return .error(400, "Expected {\"engine\": \"whisperKit\" | \"parakeet\" | \"canary\"}")
        }
        let manager = ModelDownloadManager.shared
        print("[Portal] \(who.email) started a download of \(target.label).")
        Task {
            switch target.key {
            case .whisper(let name): await manager.downloadWhisperModel(name: name)
            case .parakeet(let repo): await manager.downloadParakeetModel(repo: repo)
            case .canary: await manager.downloadCanaryModel()
            default: break
            }
            PortalJobQueue.shared.modelCache = nil
        }
        return .dto(statusDTO(who))
    }

    /// Refuse a job whose engine or model isn't on the Mini. "auto" always
    /// passes: it uses the Mini's current model for whichever engine it picks.
    private func modelProblem(_ settings: PortalJobSettings) -> String? {
        guard settings.engine != "auto" else { return nil }
        let models = downloadedModels(forceRefresh: true)[settings.engine] ?? []
        let engineName: String
        switch settings.engine {
        case "whisperKit": engineName = "WhisperKit"
        case "parakeet": engineName = "Parakeet"
        case "canary": engineName = "Canary"
        default: engineName = settings.engine
        }
        if models.isEmpty {
            return "\(engineName) isn't downloaded on the Mac Mini. Pick another engine, or download it in StreamScribe on the Mini."
        }
        if settings.engine != "canary", let model = settings.model, !model.isEmpty,
           !models.contains(where: { $0.id == model }) {
            return "That \(engineName) model isn't downloaded on the Mac Mini."
        }
        return nil
    }

    private func jobDTO(_ job: PortalJob, _ who: PortalIdentity) -> PortalJobDTO {
        var position: Int? = nil
        if job.status == .queued {
            position = (jobs.filter { $0.status == .queued }.firstIndex { $0.id == job.id } ?? 0) + 1
        }
        return PortalJobDTO(
            id: job.id.uuidString,
            title: job.title,
            source: job.displaySource,
            isUpload: job.isUpload,
            status: job.status.rawValue,
            message: job.message,
            submittedBy: job.submittedBy,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            mode: job.resolvedMode,
            durationSeconds: job.durationSeconds,
            processedSeconds: job.processedSeconds,
            segmentCount: job.segments.count,
            queuePosition: position,
            canManage: canManage(job, who),
            live: isAttached(job),
            settings: job.settings)
    }

    private func createURLJob(_ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let body = request.decodeBody(PortalCreateJobBody.self) else {
            return .error(400, "Expected {\"url\": \"https://…\"}")
        }
        let settings = body.settings ?? PortalJobSettings()
        if let problem = settings.validationError() ?? modelProblem(settings) { return .error(422, problem) }
        let checked = Self.validateSubmittedURL(body.url)
        guard let url = checked.url else { return .error(422, checked.problem ?? "Invalid link") }
        let job = PortalJob(input: url.absoluteString, displaySource: url.absoluteString,
                            isUpload: false, uploadDirectory: nil,
                            settings: settings, submittedBy: who.email)
        update(job, saveNow: true)
        print("[Portal] \(who.email) queued \(url.absoluteString)")
        pump()
        return .dto(jobDTO(job, who), status: 201)
    }

    /// Only http(s) links. Local paths and file:// are refused outright — the
    /// engine happily opens absolute paths, which must never be reachable from
    /// the web. The loopback / link-local host check is a best-effort string
    /// match (numeric forms, DNS names and redirects can still point home); it
    /// only matters to signed-in users, and the engine only ever GETs media.
    static func validateSubmittedURL(_ raw: String) -> (url: URL?, problem: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Paste a link to transcribe") }
        guard trimmed.count <= 4096 else { return (nil, "That link is too long") }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return (nil, "Enter a full web link starting with https:// (to transcribe a file, use Upload)")
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare == "0.0.0.0" || bare == "::1"
            || bare.hasPrefix("127.") || bare.hasPrefix("169.254.") {
            return (nil, "Links to this machine aren't allowed")
        }
        return (url, nil)
    }

    // MARK: - Endpoints: job actions

    private func stopJob(_ job: PortalJob, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard canManage(job, who) else { return .error(403, "Only the person who submitted this job (or an admin) can stop it") }
        var j = job
        switch job.status {
        case .queued:
            j.status = .cancelled
            j.message = "Cancelled by \(who.email)"
            j.finishedAt = Date()
            update(j, saveNow: true)
        case .preparing, .running, .finishing:
            j.stoppedBy = who.email
            update(j)
            if dispatchingJobID == job.id {
                cancelDuringDispatch.insert(job.id)
            } else if activeJobID == job.id, let engine, !engine.isStopping {
                print("[Portal] Stop requested by \(who.email) for job \(job.id.uuidString.prefix(8)).")
                engine.stop()
            }
        default:
            return .error(409, "This job has already finished")
        }
        return .dto(jobDTO(self.job(job.id) ?? j, who))
    }

    private func retryJob(_ job: PortalJob, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard job.status.isTerminal else { return .error(409, "This job hasn't finished yet") }
        if job.isUpload && !FileManager.default.fileExists(atPath: job.input) {
            return .error(410, "The uploaded file is no longer on the Mac Mini — upload it again")
        }
        // Both jobs reference the same upload folder; deleteJobFiles only
        // removes a folder once no remaining job refers to it.
        var fresh = PortalJob(input: job.input, displaySource: job.displaySource, isUpload: job.isUpload,
                              uploadDirectory: job.uploadDirectory, settings: job.settings,
                              submittedBy: who.email)
        fresh.title = job.title
        update(fresh, saveNow: true)
        pump()
        return .dto(jobDTO(fresh, who), status: 201)
    }

    private func deleteJob(_ job: PortalJob, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard canManage(job, who) else { return .error(403, "Only the person who submitted this job (or an admin) can delete it") }
        guard job.status.isTerminal || job.status == .queued else {
            return .error(409, "Stop the job before deleting it")
        }
        jobs.removeAll { $0.id == job.id }
        indexes[job.id] = nil
        pendingSaves.remove(job.id)
        if attachedJobID == job.id { attachedJobID = nil }
        deleteJobFiles(job)
        refreshSummary()
        return .ok()
    }

    private func renameSpeaker(_ job: PortalJob, _ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let body = request.decodeBody(PortalRenameBody.self), !body.label.isEmpty else {
            return .error(400, "Expected {\"label\": \"Speaker 1\", \"name\": \"…\"}")
        }
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 120 else { return .error(422, "Name is too long") }
        guard job.segments.contains(where: { $0.speaker == body.label }) else {
            return .error(404, "No speaker '\(body.label)' in this transcript")
        }
        if isAttached(job), let engine {
            if name.isEmpty {
                engine.speakerNames.removeValue(forKey: body.label)
            } else {
                engine.speakerNames[body.label] = name
            }
            syncAttached()
        } else {
            var j = job
            if name.isEmpty { j.speakerNames.removeValue(forKey: body.label) } else { j.speakerNames[body.label] = name }
            var index = indexFor(j)
            index.bumpMeta()
            indexes[j.id] = index
            update(j, saveNow: true)
        }
        return .ok()
    }

    private func addPin(_ job: PortalJob, _ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let body = request.decodeBody(PortalPinBody.self), let segID = UUID(uuidString: body.segmentId) else {
            return .error(400, "Expected {\"segmentId\": \"…\"}")
        }
        if isAttached(job), let engine {
            guard let seg = engine.segments.first(where: { $0.id == segID }) else { return .error(404, "Segment not found") }
            engine.pinSelection(text: seg.text, speaker: seg.speaker, start: seg.start, end: seg.end, sourceSegmentID: seg.id)
            syncAttached()
        } else {
            guard let seg = job.segments.first(where: { $0.id == segID }) else { return .error(404, "Segment not found") }
            var j = job
            if !j.pins.contains(where: { $0.sourceSegmentID == seg.id && $0.text == seg.text }) {
                j.pins.append(PinnedQuote(text: seg.text, speaker: seg.speaker, start: seg.start,
                                          end: seg.end, sourceSegmentID: seg.id))
                var index = indexFor(j)
                index.bumpMeta()
                indexes[j.id] = index
                update(j, saveNow: true)
            }
        }
        return .ok()
    }

    private func removePin(_ job: PortalJob, _ pinID: UUID, _ who: PortalIdentity) -> PortalHTTPResponse {
        if isAttached(job), let engine {
            engine.unpin(pinID)
            syncAttached()
        } else {
            var j = job
            j.pins.removeAll { $0.id == pinID }
            var index = indexFor(j)
            index.bumpMeta()
            indexes[j.id] = index
            update(j, saveNow: true)
        }
        return .ok()
    }

    // MARK: - Endpoints: transcript + export

    private func transcriptResponse(_ job: PortalJob, since: Int, clientEpoch: String,
                                    who: PortalIdentity) -> PortalHTTPResponse {
        if isAttached(job) { syncAttached() }
        let current = self.job(job.id) ?? job
        let index = indexFor(current)
        let full = clientEpoch != epoch || since <= 0 || since > index.rev

        let segments: [PortalSegmentDTO] = current.segments.compactMap { seg in
            guard full || index.revision(of: seg.id) > since else { return nil }
            return PortalSegmentDTO(id: seg.id.uuidString, start: seg.start, end: seg.end, text: seg.text,
                                    speaker: seg.speaker, review: seg.needsReview ?? false,
                                    edited: seg.userEdited ?? false)
        }
        let order: [String]? = (full || index.orderRev > since) ? current.segments.map { $0.id.uuidString } : nil

        var speakers: [PortalSpeakerDTO]? = nil
        var pins: [PortalPinDTO]? = nil
        // The speaker list is derived from the segments (new labels, counts),
        // so it rides along with ANY segment change, not only renames/pins —
        // otherwise a speaker first seen mid-session never reaches the page.
        if full || index.metaRev > since || !segments.isEmpty || order != nil {
            var counts: [String: Int] = [:]
            var ordered: [String] = []
            for seg in current.segments {
                guard let label = seg.speaker else { continue }
                if counts[label] == nil { ordered.append(label) }
                counts[label, default: 0] += 1
            }
            speakers = ordered.map { label in
                let renamed = current.speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let source: String
                if let renamed, !renamed.isEmpty { source = "rename" }
                else if current.voiceprintNames[label] != nil { source = "voiceprint" }
                else { source = "machine" }
                return PortalSpeakerDTO(label: label, name: current.displayName(for: label) ?? label,
                                        source: source, count: counts[label] ?? 0)
            }
            pins = current.pins.map {
                PortalPinDTO(id: $0.id.uuidString, text: $0.text, speaker: $0.speaker, start: $0.start,
                             end: $0.end, segmentId: $0.sourceSegmentID?.uuidString, keyword: $0.matchedKeyword)
            }
        }
        return .dto(PortalTranscriptDTO(epoch: epoch, rev: index.rev, full: full, job: jobDTO(current, who),
                                         order: order, segments: segments, speakers: speakers, pins: pins))
    }

    private func exportResponse(_ job: PortalJob, format id: String) -> PortalHTTPResponse {
        if isAttached(job) { syncAttached() }
        let current = self.job(job.id) ?? job
        guard let format = TranscriptFormat.allCases.first(where: { $0.fileExtension == id.lowercased() }) else {
            return .error(400, "Unknown export format '\(id)'")
        }
        guard !current.segments.isEmpty else { return .error(409, "There's no transcript to export yet") }

        // Same resolution the Mac's export uses: rename → voiceprint → label.
        let segments = current.segments.map { seg -> TranscriptSegment in
            var copy = seg
            if let name = current.displayName(for: seg.speaker) { copy.speaker = name }
            return copy
        }
        let d = UserDefaults.standard
        func pref(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        let options = ExportOptions(
            includeTimestamps: pref("export.includeTimestamps", true),
            speakerLabelsBold: pref("export.speakerLabelsBold", true),
            speakerPlacement: SpeakerPlacement(rawValue: d.string(forKey: "export.speakerPlacement") ?? "") ?? .above,
            includeTitle: pref("export.includeTitle", true),
            includeSource: pref("export.includeSource", true),
            includeGenerated: pref("export.includeGenerated", true))

        let data: Data?
        if format.isBinary {
            data = TranscriptExporter.renderData(segments, as: format, sourceURL: current.displaySource,
                                                 title: current.title, speakerNames: current.speakerNames,
                                                 options: options)
        } else {
            data = Data(TranscriptExporter.render(segments, as: format, sourceURL: current.displaySource,
                                                  title: current.title, speakerNames: current.speakerNames,
                                                  options: options).utf8)
        }
        guard let data else { return .error(500, "The \(format.rawValue) exporter didn't produce a file") }

        let fallback = current.isUpload ? (current.displaySource as NSString).deletingPathExtension : "transcript"
        let base = Self.safeFilename(current.title ?? fallback)
        let stamp = Self.fileStamp.string(from: current.finishedAt ?? current.createdAt)
        let mime = format.contentType.preferredMIMEType ?? "application/octet-stream"
        return .attachment(data, filename: "\(base) \(stamp).\(format.fileExtension)", contentType: mime)
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Callers strip a file extension themselves when there is one — titles
    /// like "U.S. Senate Banking Hearing" must keep their periods.
    static func safeFilename(_ raw: String) -> String {
        var name = raw
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        name = name.components(separatedBy: bad).joined(separator: " ")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "transcript" : name
    }

    // MARK: - Endpoints: uploads (chunked, resumable)

    private func createUpload(_ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let body = request.decodeBody(PortalCreateUploadBody.self) else {
            return .error(400, "Expected {\"filename\": \"…\", \"size\": 123}")
        }
        guard body.size > 0 else { return .error(422, "That file is empty") }
        if let settings = body.settings,
           let problem = settings.validationError() ?? modelProblem(settings) {
            return .error(422, problem)
        }
        guard body.size <= Self.maxUploadBytes else {
            return .error(413, "Files up to \(Self.maxUploadBytes / (1024 * 1024 * 1024)) GB are supported")
        }
        let original = (body.filename as NSString).lastPathComponent
        let ext = (original as NSString).pathExtension.lowercased()
        guard Self.uploadExtensions.contains(ext) else {
            return .error(415, "Unsupported file type '.\(ext)'. Upload an audio or video file.")
        }
        // Keep 2 GB free beyond the file itself so the engine's caches still fit.
        if let free = Self.freeDiskBytes(), free < body.size + 2 * 1024 * 1024 * 1024 {
            return .error(507, "The Mac Mini doesn't have enough free disk space for this file")
        }

        let id = UUID()
        let dir = Self.uploadsDirectory.appendingPathComponent(id.uuidString)
        let fileURL = dir.appendingPathComponent(Self.safeFilename((original as NSString).deletingPathExtension) + "." + ext)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return .error(500, "Couldn't prepare the upload: \(error.localizedDescription)")
        }
        uploads[id] = PortalUploadSession(id: id, owner: who.email, originalName: original, directory: dir,
                                          fileURL: fileURL, size: body.size, received: 0, createdAt: Date())
        return .json(["uploadId": id.uuidString, "chunkBytes": String(Self.uploadChunkBytes)], status: 201)
    }

    private func receiveChunk(_ id: UUID, _ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard var session = uploads[id], session.owner == who.email else { return .error(404, "Unknown upload") }
        guard let offset = Int64(request.query["offset"] ?? "") else { return .error(400, "Missing ?offset=") }
        let length = Int64(request.body.count)
        guard length > 0 else { return .error(400, "Empty chunk") }

        // Idempotent retries: a chunk we already have is acknowledged, not re-written.
        if offset + length <= session.received {
            return .json(["received": String(session.received)])
        }
        guard offset == session.received else {
            return .json(["error": "Out-of-order chunk", "received": String(session.received)], status: 409)
        }
        guard session.received + length <= session.size else {
            return .error(413, "More data than the declared file size")
        }
        do {
            let handle = try FileHandle(forWritingTo: session.fileURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: request.body)
        } catch {
            return .error(500, "Couldn't write the upload: \(error.localizedDescription)")
        }
        session.received += length
        uploads[id] = session
        return .json(["received": String(session.received)])
    }

    private func finishUpload(_ id: UUID, _ request: PortalHTTPRequest, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let session = uploads[id], session.owner == who.email else { return .error(404, "Unknown upload") }
        guard session.received == session.size else {
            return .json(["error": "Upload incomplete", "received": String(session.received)], status: 409)
        }
        let settings = request.decodeBody(PortalFinishUploadBody.self)?.settings ?? PortalJobSettings()
        if let problem = settings.validationError() ?? modelProblem(settings) { return .error(422, problem) }
        uploads[id] = nil

        var job = PortalJob(input: session.fileURL.path, displaySource: session.originalName, isUpload: true,
                            uploadDirectory: session.directory.path, settings: settings, submittedBy: who.email)
        job.title = (session.originalName as NSString).deletingPathExtension
        update(job, saveNow: true)
        print("[Portal] \(who.email) uploaded \(session.originalName) (\(session.size) bytes)")
        pump()
        return .dto(jobDTO(job, who), status: 201)
    }

    private func abortUpload(_ id: UUID, _ who: PortalIdentity) -> PortalHTTPResponse {
        guard let session = uploads[id], session.owner == who.email else { return .ok() }
        uploads[id] = nil
        try? FileManager.default.removeItem(at: session.directory)
        return .ok()
    }

    private static func freeDiskBytes() -> Int64? {
        let url = rootDirectory.deletingLastPathComponent()
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Main-actor JSON helpers
//
// With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, the portal's model and DTO
// types have MainActor-isolated Codable conformances. These extensions are
// MainActor-isolated too (default isolation), so encoding and decoding
// happen where those conformances are valid — not inside the nonisolated
// HTTP layer.

extension PortalHTTPResponse {
    static func dto<T: Encodable>(_ value: T, status: Int = 200) -> PortalHTTPResponse {
        do {
            return .jsonData(try PortalHTTPResponse.makeEncoder().encode(value), status: status)
        } catch {
            print("[Portal] JSON encode failed: \(error)")
            return .error(500, "Internal encoding error")
        }
    }
}

extension PortalHTTPRequest {
    /// Decode the body as JSON into `T`. nil on an empty or malformed body.
    func decodeBody<T: Decodable>(_ type: T.Type) -> T? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }
}
