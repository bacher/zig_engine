//! Service-owned save policy. Jobs retain encoder, source, and commit ownership;
//! callers execute the returned actions without blocking completion processing.
const std = @import("std");

pub const Intent = struct { id: u64, final: bool };
pub const Stage = enum { capturing, writing, finalizing };
pub const Attempt = struct {
    intent: Intent,
    epoch: u64,
    stage: Stage = .capturing,
    started_ns: i96,
    final_policy: bool,
    cancel_requested: bool = false,
};
pub const Retry = union(enum) { available, scheduled: i96, exhausted };
pub const Drain = struct {
    intent: Intent,
    fence_remaining: usize,
    selected: bool = false,
    retry: Retry = .available,
};
pub const Observations = struct {
    source_holds: usize = 0,
    pending_commands: usize = 0,
    pending_reads: usize = 0,
    waiting_queries: usize = 0,
    compactor_active: bool = false,
    oldest_player_wait: ?i96 = null,
};
pub const Deadlines = struct { capture_wait_ns: u64, player_wait_ns: u64, overdue_ns: u64 };
/// Both retained queries and mutations must be retried for this action. Either
/// can discover a dependency without another completion to wake the service.
pub const DrainAction = enum { none, retry_dependencies };
pub const WatchdogAction = enum { none, cancel_capture, start_overdue };
pub const Outcome = union(enum) { complete, canceled: anyerror, failed: anyerror };
pub const Completion = struct { intent: Intent, outcome: Outcome };

pub const Lifecycle = struct {
    active: ?Attempt = null,
    queued: ?Drain = null,
    unsaved_work: bool = false,
    last_success_ns: i96 = 0,
    overdue: bool = false,

    /// Establish the resolved-command fence before the caller restarts reads:
    /// synchronous preparation can immediately resolve an operation.
    pub fn request(self: *Lifecycle, intent: Intent, pending_commands: usize) DrainAction {
        if (self.queued != null and !intent.final) return .none;
        self.queued = .{ .intent = intent, .fence_remaining = pending_commands };
        return .retry_dependencies;
    }

    /// An older writer keeps its identity until its terminal event. Once it is
    /// gone, selecting a queued drain publishes its own preparation failures.
    pub fn selectDrain(self: *Lifecycle) ?Intent {
        const drain = if (self.queued) |*drain| drain else return null;
        if (self.active != null or drain.selected) return null;
        drain.selected = true;
        return drain.intent;
    }

    pub fn needsQueryRecheck(self: *const Lifecycle, observed: Observations) bool {
        const drain = self.queued orelse return false;
        return drain.intent.final and self.active == null and observed.pending_reads == 0 and observed.waiting_queries != 0;
    }

    pub fn takeReady(self: *Lifecycle, observed: Observations) ?Intent {
        const drain = self.queued orelse return null;
        if (self.active != null or drain.fence_remaining != 0) return null;
        if (drain.intent.final and (observed.pending_reads != 0 or observed.waiting_queries != 0 or observed.compactor_active)) return null;
        self.queued = null;
        return drain.intent;
    }

    /// Call only for a resolved command, never for a dependency/capture defer.
    pub fn commandResolved(self: *Lifecycle) void {
        if (self.queued) |*drain| if (drain.fence_remaining != 0) {
            drain.fence_remaining -= 1;
        };
    }

    pub fn isRetryableReadFailure(err: anyerror) bool {
        return err == error.Io or err == error.OutOfMemory;
    }

    /// Returns whether a final drain has an automatic retry pending. Repeated
    /// failures share one deadline; the automatic retry never replenishes itself.
    pub fn dependencyFailed(self: *Lifecycle, err: anyerror, at: i96) bool {
        const drain = if (self.queued) |*drain| drain else return false;
        if (!drain.intent.final) return false;
        if (!isRetryableReadFailure(err)) {
            // A permanent failure suppresses the deadline without consuming an
            // automatic retry that has not yet run.
            if (drain.retry != .exhausted) drain.retry = .available;
            return false;
        }
        switch (drain.retry) {
            .available => drain.retry = .{ .scheduled = at + std.time.ns_per_s },
            .scheduled => {},
            .exhausted => return false,
        }
        return true;
    }

    pub fn takeDueRetry(self: *Lifecycle, at: i96) DrainAction {
        const drain = if (self.queued) |*drain| drain else return .none;
        switch (drain.retry) {
            .scheduled => |deadline| if (at >= deadline) {
                drain.retry = .exhausted;
                return .retry_dependencies;
            },
            else => {},
        }
        return .none;
    }

    pub fn started(self: *Lifecycle, intent: Intent, epoch: u64, at: i96) void {
        std.debug.assert(self.active == null);
        self.active = .{ .intent = intent, .epoch = epoch, .started_ns = at, .final_policy = intent.final };
    }

    pub fn encoded(self: *Lifecycle, epoch: u64) bool {
        const attempt = if (self.active) |*attempt| attempt else return false;
        if (attempt.epoch != epoch) return false;
        attempt.stage = .writing;
        return true;
    }

    /// Only a durable acknowledgement resets overdue age. Source release,
    /// cancellation requests, and failed attempts do not establish saved progress.
    pub fn committed(self: *Lifecycle, epoch: u64, at: i96) bool {
        const attempt = if (self.active) |*attempt| attempt else return false;
        if (attempt.epoch != epoch) return false;
        attempt.stage = .finalizing;
        self.last_success_ns = at;
        self.overdue = false;
        return true;
    }

    pub fn finished(self: *Lifecycle, epoch: u64, failure: ?anyerror) ?Completion {
        const attempt = self.active orelse return null;
        if (attempt.epoch != epoch) return null;
        self.active = null;
        return .{ .intent = attempt.intent, .outcome = if (failure) |err| switch (err) {
            error.CaptureCanceled, error.Cancelled, error.Canceled => .{ .canceled = err },
            else => .{ .failed = err },
        } else .complete };
    }

    /// Cancel exit hands final-save policy back to gameplay. A request neither
    /// releases sources nor establishes an outcome: the worker may already have
    /// authorized a successful durable commit.
    pub fn cancel(self: *Lifecycle, id: u64) bool {
        if (self.queued) |drain| if (drain.intent.id == id) {
            self.queued = null;
        };
        const attempt = if (self.active) |*attempt| attempt else return false;
        if (attempt.intent.id != id) return false;
        attempt.final_policy = false;
        if (self.overdue) return false;
        attempt.cancel_requested = true;
        return true;
    }

    pub fn finalPolicy(self: *const Lifecycle) bool {
        return if (self.active) |attempt| attempt.final_policy else false;
    }

    fn captureDeadline(self: *const Lifecycle, limits: Deadlines, observed: Observations) ?i96 {
        const attempt = self.active orelse return null;
        if (observed.source_holds == 0 or attempt.cancel_requested or attempt.final_policy or self.overdue) return null;
        const capture = attempt.started_ns + limits.capture_wait_ns;
        return if (observed.oldest_player_wait) |since| @min(capture, since + limits.player_wait_ns) else capture;
    }

    pub fn nextDeadline(self: *const Lifecycle, limits: Deadlines, observed: Observations) ?i96 {
        var next: ?i96 = if (self.unsaved_work and !self.overdue) self.last_success_ns + limits.overdue_ns else null;
        if (self.captureDeadline(limits, observed)) |capture| next = if (next) |current| @min(current, capture) else capture;
        if (self.queued) |drain| switch (drain.retry) {
            .scheduled => |retry| next = if (next) |current| @min(current, retry) else retry,
            else => {},
        };
        return next;
    }

    /// Consume due dependency retries before calling this with fresh observations:
    /// retrying a drain can start a capture or discover additional waiting work.
    pub fn watchdog(self: *Lifecycle, at: i96, limits: Deadlines, observed: Observations) WatchdogAction {
        if (self.unsaved_work and at - self.last_success_ns >= limits.overdue_ns) self.overdue = true;
        if (self.captureDeadline(limits, observed)) |deadline| if (at >= deadline) {
            self.active.?.cancel_requested = true;
            return .cancel_capture;
        };
        if (self.active == null and self.overdue and self.queued == null and observed.pending_commands == 0) return .start_overdue;
        return .none;
    }
};

const testing = std.testing;
const test_deadlines: Deadlines = .{ .capture_wait_ns = 500, .player_wait_ns = 100, .overdue_ns = 10_000 };

test "save drain fences the accepted prefix before retry and coalesces ordinary requests" {
    var lifecycle: Lifecycle = .{};
    try testing.expectEqual(DrainAction.retry_dependencies, lifecycle.request(.{ .id = 1, .final = false }, 2));
    try testing.expectEqual(@as(usize, 2), lifecycle.queued.?.fence_remaining);
    try testing.expectEqual(@as(u64, 1), lifecycle.selectDrain().?.id);
    try testing.expect(lifecycle.selectDrain() == null);
    lifecycle.commandResolved();
    try testing.expect(lifecycle.takeReady(.{}) == null);
    try testing.expectEqual(DrainAction.none, lifecycle.request(.{ .id = 2, .final = false }, 9));
    try testing.expectEqual(@as(usize, 1), lifecycle.queued.?.fence_remaining);
    lifecycle.commandResolved();
    // Commands accepted after the fence do not postpone this capture.
    const intent = lifecycle.takeReady(.{ .pending_commands = 7, .pending_reads = 1, .waiting_queries = 1, .compactor_active = true }).?;
    try testing.expectEqual(@as(u64, 1), intent.id);
    try testing.expect(lifecycle.queued == null);
    lifecycle.commandResolved();
}

test "queued final drain retains identity retry and query wake after older writer completes" {
    var lifecycle: Lifecycle = .{};
    lifecycle.started(.{ .id = 1, .final = false }, 10, 100);
    _ = lifecycle.request(.{ .id = 2, .final = true }, 1);
    try testing.expect(lifecycle.selectDrain() == null);
    try testing.expect(lifecycle.dependencyFailed(error.Io, 200));
    lifecycle.commandResolved();
    const waiting: Observations = .{ .waiting_queries = 1 };
    try testing.expect(!lifecycle.needsQueryRecheck(waiting));
    try testing.expect(lifecycle.takeReady(.{}) == null);
    try testing.expect(lifecycle.encoded(10));
    try testing.expectEqual(Stage.writing, lifecycle.active.?.stage);
    try testing.expect(lifecycle.committed(10, 300));
    try testing.expectEqual(Stage.finalizing, lifecycle.active.?.stage);
    try testing.expectEqual(@as(u64, 1), lifecycle.finished(10, null).?.intent.id);
    try testing.expectEqual(@as(u64, 2), lifecycle.selectDrain().?.id);
    try testing.expect(lifecycle.needsQueryRecheck(waiting));
    try testing.expect(lifecycle.takeReady(waiting) == null);
    try testing.expect(lifecycle.takeReady(.{ .pending_reads = 1 }) == null);
    try testing.expect(lifecycle.takeReady(.{ .compactor_active = true }) == null);
    try testing.expectEqual(DrainAction.retry_dependencies, lifecycle.takeDueRetry(200 + std.time.ns_per_s));
    try testing.expectEqual(@as(u64, 2), lifecycle.takeReady(.{}).?.id);
}

test "ready drain retires an unneeded retry deadline" {
    var lifecycle: Lifecycle = .{};
    _ = lifecycle.request(.{ .id = 1, .final = true }, 1);
    try testing.expect(lifecycle.dependencyFailed(error.OutOfMemory, 100));
    try testing.expect(lifecycle.nextDeadline(test_deadlines, .{}) != null);
    // Meaningful progress can resolve preparation before its retry timer fires.
    lifecycle.commandResolved();
    try testing.expectEqual(@as(u64, 1), lifecycle.takeReady(.{}).?.id);
    try testing.expect(lifecycle.nextDeadline(test_deadlines, .{}) == null);
    try testing.expectEqual(DrainAction.none, lifecycle.takeDueRetry(100 + std.time.ns_per_s));
}

test "final dependency retry has one stable deadline and explicit replacement replenishes it" {
    var lifecycle: Lifecycle = .{};
    _ = lifecycle.request(.{ .id = 1, .final = true }, 1);
    try testing.expect(lifecycle.dependencyFailed(error.Io, 100));
    const deadline = 100 + std.time.ns_per_s;
    try testing.expect(lifecycle.dependencyFailed(error.OutOfMemory, 200));
    try testing.expectEqual(@as(i96, deadline), lifecycle.queued.?.retry.scheduled);
    try testing.expectEqual(DrainAction.none, lifecycle.takeDueRetry(deadline - 1));
    try testing.expectEqual(DrainAction.retry_dependencies, lifecycle.takeDueRetry(deadline));
    try testing.expectEqual(DrainAction.none, lifecycle.takeDueRetry(deadline + std.time.ns_per_s));
    try testing.expect(!lifecycle.dependencyFailed(error.Io, deadline + 1));
    try testing.expectEqual(DrainAction.none, lifecycle.request(.{ .id = 2, .final = false }, 4));
    try testing.expect(lifecycle.queued.?.retry == .exhausted);
    try testing.expectEqual(DrainAction.retry_dependencies, lifecycle.request(.{ .id = 3, .final = true }, 4));
    try testing.expectEqual(@as(usize, 4), lifecycle.queued.?.fence_remaining);
    try testing.expect(lifecycle.dependencyFailed(error.Io, deadline + 2));
}

test "permanent drain failure removes retry deadline without consuming unused allowance" {
    var lifecycle: Lifecycle = .{};
    _ = lifecycle.request(.{ .id = 1, .final = true }, 1);
    try testing.expect(!lifecycle.dependencyFailed(error.ChecksumMismatch, 100));
    try testing.expect(lifecycle.nextDeadline(test_deadlines, .{}) == null);
    try testing.expect(lifecycle.dependencyFailed(error.Io, 200));
    try testing.expect(!lifecycle.dependencyFailed(error.ChecksumMismatch, 300));
    try testing.expectEqual(DrainAction.none, lifecycle.takeDueRetry(200 + std.time.ns_per_s));
    try testing.expect(lifecycle.dependencyFailed(error.Io, 400));
    try testing.expectEqual(DrainAction.retry_dependencies, lifecycle.takeDueRetry(400 + std.time.ns_per_s));
    try testing.expect(!lifecycle.dependencyFailed(error.ChecksumMismatch, 500 + std.time.ns_per_s));
    try testing.expect(!lifecycle.dependencyFailed(error.Io, 600 + std.time.ns_per_s));
}

test "watchdog selects earliest player capture overdue and drain retry deadlines" {
    var lifecycle: Lifecycle = .{ .unsaved_work = true, .last_success_ns = 50 };
    lifecycle.started(.{ .id = 1, .final = false }, 1, 100);
    const held: Observations = .{ .source_holds = 1, .oldest_player_wait = 200 };
    try testing.expectEqual(@as(?i96, 300), lifecycle.nextDeadline(test_deadlines, held));
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(299, test_deadlines, held));
    try testing.expectEqual(WatchdogAction.cancel_capture, lifecycle.watchdog(300, test_deadlines, held));
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(600, test_deadlines, held));
    try testing.expectEqual(@as(?i96, 10_050), lifecycle.nextDeadline(test_deadlines, held));
    _ = lifecycle.finished(1, error.CaptureCanceled);
    lifecycle.started(.{ .id = 2, .final = false }, 2, 700);
    try testing.expectEqual(@as(?i96, 1200), lifecycle.nextDeadline(test_deadlines, .{ .source_holds = 1 }));
    // Source release removes gameplay deadlines independently of writer completion.
    try testing.expectEqual(@as(?i96, 10_050), lifecycle.nextDeadline(test_deadlines, .{}));
    var drain: Lifecycle = .{};
    _ = drain.request(.{ .id = 3, .final = true }, 1);
    try testing.expect(drain.dependencyFailed(error.Io, 1));
    try testing.expectEqual(@as(?i96, 1 + std.time.ns_per_s), drain.nextDeadline(test_deadlines, .{}));
}

test "final saves ignore gameplay deadlines and cancel exit hands policy back safely" {
    var lifecycle: Lifecycle = .{};
    lifecycle.started(.{ .id = 1, .final = true }, 1, 100);
    const held: Observations = .{ .source_holds = 1, .oldest_player_wait = 100 };
    try testing.expect(lifecycle.nextDeadline(test_deadlines, held) == null);
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(9000, test_deadlines, held));
    try testing.expect(!lifecycle.cancel(2));
    try testing.expect(lifecycle.finalPolicy());
    try testing.expect(lifecycle.cancel(1));
    try testing.expect(!lifecycle.finalPolicy());
    try testing.expect(lifecycle.active.?.intent.final);
    try testing.expect(lifecycle.active.?.cancel_requested);
    // A request does not predict which side of the worker commit gate won.
    try testing.expect(lifecycle.encoded(1));
    try testing.expect(lifecycle.committed(1, 10_000));
    try testing.expectEqual(Outcome.complete, lifecycle.finished(1, null).?.outcome);
    try testing.expectEqual(@as(i96, 10_000), lifecycle.last_success_ns);
}

test "terminal transitions preserve actual cancellation and failure errors" {
    var lifecycle: Lifecycle = .{ .last_success_ns = 10 };
    for ([_]anyerror{ error.CaptureCanceled, error.Cancelled, error.Canceled }) |failure| {
        lifecycle.started(.{ .id = 1, .final = false }, 1, 20);
        try testing.expect(lifecycle.cancel(1));
        try testing.expect(lifecycle.encoded(1));
        try testing.expectEqual(failure, lifecycle.finished(1, failure).?.outcome.canceled);
        try testing.expect(lifecycle.active == null);
        try testing.expectEqual(@as(i96, 10), lifecycle.last_success_ns);
    }
    lifecycle.started(.{ .id = 2, .final = false }, 2, 30);
    try testing.expectEqual(error.Io, lifecycle.finished(2, error.Io).?.outcome.failed);
    try testing.expectEqual(@as(i96, 10), lifecycle.last_success_ns);
}

test "overdue priority survives source release cancel exit and failed attempts until durable ack" {
    var lifecycle: Lifecycle = .{ .unsaved_work = true, .last_success_ns = 10 };
    lifecycle.started(.{ .id = 1, .final = true }, 1, 100);
    const held: Observations = .{ .source_holds = 1, .oldest_player_wait = 100 };
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(10_010, test_deadlines, held));
    try testing.expect(lifecycle.overdue);
    try testing.expect(!lifecycle.cancel(1));
    try testing.expect(!lifecycle.finalPolicy());
    try testing.expect(!lifecycle.active.?.cancel_requested);
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(20_000, test_deadlines, held));
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(20_000, test_deadlines, .{}));
    _ = lifecycle.finished(1, error.Io);
    try testing.expect(lifecycle.overdue);
    try testing.expectEqual(WatchdogAction.none, lifecycle.watchdog(20_000, test_deadlines, .{ .pending_commands = 1 }));
    try testing.expectEqual(WatchdogAction.start_overdue, lifecycle.watchdog(20_000, test_deadlines, .{}));
    lifecycle.started(.{ .id = 2, .final = false }, 2, 20_000);
    try testing.expect(lifecycle.encoded(2));
    try testing.expect(lifecycle.committed(2, 20_100));
    try testing.expect(!lifecycle.overdue);
    try testing.expectEqual(@as(i96, 20_100), lifecycle.last_success_ns);
    _ = lifecycle.finished(2, null);
    try testing.expectEqual(@as(?i96, 30_100), lifecycle.nextDeadline(test_deadlines, .{}));
    lifecycle.unsaved_work = false;
    try testing.expect(lifecycle.nextDeadline(test_deadlines, .{}) == null);
}

test "cancel queued intent discards its retry without canceling the active writer" {
    var lifecycle: Lifecycle = .{};
    lifecycle.started(.{ .id = 1, .final = false }, 1, 100);
    _ = lifecycle.request(.{ .id = 2, .final = true }, 3);
    try testing.expect(lifecycle.dependencyFailed(error.Io, 200));
    try testing.expect(!lifecycle.cancel(3));
    try testing.expect(lifecycle.queued != null);
    try testing.expect(!lifecycle.cancel(2));
    try testing.expect(lifecycle.queued == null);
    try testing.expect(!lifecycle.active.?.cancel_requested);
    try testing.expect(lifecycle.nextDeadline(test_deadlines, .{}) == null);
}

test "stale epoch events cannot transition a replacement attempt or reset overdue age" {
    var lifecycle: Lifecycle = .{ .unsaved_work = true, .last_success_ns = 100, .overdue = true };
    lifecycle.started(.{ .id = 2, .final = false }, 2, 200);
    try testing.expect(!lifecycle.encoded(1));
    try testing.expect(!lifecycle.committed(1, 300));
    try testing.expect(lifecycle.finished(1, error.Io) == null);
    try testing.expectEqual(Stage.capturing, lifecycle.active.?.stage);
    try testing.expectEqual(@as(u64, 2), lifecycle.active.?.intent.id);
    try testing.expectEqual(@as(i96, 100), lifecycle.last_success_ns);
    try testing.expect(lifecycle.overdue);
}
