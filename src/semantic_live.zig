//! Meaning search, live: the switch, the model's download, the runtime, and
//! the index it fills. Everything slow happens off the main thread; the
//! panel only reads what this has already worked out.
//!
//! The shape of a search: the query goes to the model for a vector, and the
//! vector is scored against the index `vector_index.zig` keeps. When the
//! model or the index is not ready, nothing is added and the panel shows
//! the name search it always had.
const std = @import("std");
const nanoui = @import("nanoui");
const model = @import("embed_model.zig");
const download = @import("model_download.zig");
const runtime = @import("embed_runtime.zig");
const vectors = @import("vector_index.zig");
const Live = @import("main.zig").Live;
const Host = @import("view.zig").Host;

pub const enabled_key = "nanolight.meaning";
/// Where the index lives, beside the model.
pub const index_name = "vectors.idx";

pub const State = struct {
    /// The switch, as Settings and the welcome leave it.
    on: bool = false,
    /// The model is whole on this computer.
    ready: bool = false,
    /// A download is running, and how far it got.
    fetching: bool = false,
    progress: download.Progress = .{},
    /// The runtime, started on the first search that needs it and kept
    /// until idle. Shared by queries and the index builder.
    server: runtime.Server = .{},
    /// Token for the pending idle stop: a callback whose token is stale
    /// does nothing, so a new query cancels the old timer.
    idle_token: u64 = 0,
    /// The index, read once and kept.
    index: vectors.Index = .{},
    index_loaded: bool = false,
    /// A query's vector on its way: the words it is about, so a late answer
    /// for older words is dropped.
    asking: [256]u8 = undefined,
    asking_len: usize = 0,
    epoch: u64 = 0,
    busy: bool = false,
};

/// The index's path, in `buf`.
pub fn indexPath(buf: []u8) []const u8 {
    var dir_buf: [model.max_path]u8 = undefined;
    const dir = download.folder(&dir_buf);
    if (dir.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, index_name }) catch "";
}

/// Reads what was kept: the switch, and whether the model is here.
pub fn load(l: *Live) void {
    const gpa = l.app.gpa;
    if (l.kv.get(gpa, enabled_key) catch null) |v| {
        defer gpa.free(v);
        l.s.meaning_on = std.mem.eql(u8, v, "1");
    }
    l.meaning.ready = runtime.ready(l.app.io);
    l.meaning.on = l.s.meaning_on;
}

/// What Settings shows: the switch, and the model's state.
pub fn state(ctx: *anyopaque) @import("settings_host.zig").SemanticState {
    const l: *Live = @ptrCast(@alignCast(ctx));
    return .{
        .on = l.s.meaning_on,
        .ready = l.meaning.ready,
        .fetching = l.meaning.fetching,
        .fraction = l.meaning.progress.fraction(),
        .problem = l.meaning.progress.problem(),
    };
}

/// The switch, kept. Turning it on with no model starts the download, since
/// the switch is useless without one.
pub fn set(ctx: *anyopaque, on: bool) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    l.s.meaning_on = on;
    l.meaning.on = on;
    l.kv.set(enabled_key, if (on) "1" else "0") catch {};
    if (on and !l.meaning.ready and !l.meaning.fetching) fetch(ctx);
    l.s.built = 1;
    l.s.rebuild();
    if (l.window) |w| w.redraw();
}

/// Starts (or retries) the model download, on a thread of its own.
pub fn fetch(ctx: *anyopaque) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (l.meaning.fetching) return;
    var dir_buf: [model.max_path]u8 = undefined;
    const dir = download.folder(&dir_buf);
    if (dir.len == 0) return;
    l.meaning.fetching = true;
    l.meaning.progress = .{ .phase = .downloading };
    const job = l.app.gpa.create(FetchJob) catch {
        l.meaning.fetching = false;
        return;
    };
    job.* = .{ .live = l, .dir_len = @min(dir.len, job.dir.len) };
    @memcpy(job.dir[0..job.dir_len], dir[0..job.dir_len]);
    const thread = std.Thread.spawn(.{}, FetchJob.run, .{job}) catch {
        l.meaning.fetching = false;
        l.app.gpa.destroy(job);
        return;
    };
    thread.detach();
}

/// One download, off the main thread. The worker uses its own progress
/// buffer; every `Live` field is written back on the main thread in
/// `finish`, through `App.after`.
const FetchJob = struct {
    live: *Live,
    dir: [model.max_path]u8 = undefined,
    dir_len: usize = 0,
    progress: download.Progress = .{},
    ok: bool = false,

    fn run(job: *FetchJob) void {
        const l = job.live;
        const io = l.app.io;
        const gpa = l.app.gpa;
        const dir = job.dir[0..job.dir_len];
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var out: [model.all.len]model.File = undefined;
        const n = download.missing(io, dir, &out);
        job.ok = true;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!download.fetchOne(io, gpa, dir, out[i], &job.progress)) {
                job.ok = false;
                break;
            }
        }
        // Back on the main thread for anything the UI can see.
        nanoui.App.after(0, job, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *FetchJob = @ptrCast(@alignCast(ctx.?));
        const l = job.live;
        defer l.app.gpa.destroy(job);
        l.meaning.fetching = false;
        l.meaning.ready = job.ok and runtime.ready(l.app.io);
        l.meaning.progress = job.progress; // carries its own problem text and length
        l.meaning.progress.phase = if (job.ok) .ready else .failed;
        if (l.window) |w| w.redraw();
    }
};

/// A queued idle stop. Held on the heap because `App.after` keeps only the
/// context pointer; a stale token means a newer query superseded it.
const IdleStop = struct {
    live: *Live,
    token: u64,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const stop: *IdleStop = @ptrCast(@alignCast(ctx.?));
        const l = stop.live;
        defer l.app.gpa.destroy(stop);
        // A newer query bumped the token: this timer is obsolete.
        if (stop.token != l.meaning.idle_token) return;
        l.meaning.server.stop(l.app.io);
        if (l.window) |w| w.redraw();
    }
};

/// Schedules a stop after `runtime.idle_ms`. Called on the main thread when
/// a query finishes; the next query invalidates it by bumping the token.
fn scheduleIdleStop(l: *Live) void {
    l.meaning.idle_token +%= 1;
    const stop = l.app.gpa.create(IdleStop) catch return;
    stop.* = .{ .live = l, .token = l.meaning.idle_token };
    nanoui.App.after(runtime.idle_ms, stop, IdleStop.fire);
}

/// Whether a finished worker should ask again: the field's words changed
/// while it was out. Kept pure so the continuous-typing path can be tested
/// without spawning threads or loading a model.
pub fn shouldRedispatch(job_epoch: u64, current_epoch: u64) bool {
    return job_epoch != current_epoch;
}

/// The query's vector, asked of the model. Only the model call is on a
/// worker; every change to `Live` happens back on the main thread through
/// `App.after`, so the UI never races the worker.
pub fn ask(ctx: *anyopaque, q: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (!l.s.meaning_on or !l.meaning.ready or q.len == 0 or q.len >= l.meaning.asking.len) return;
    @memcpy(l.meaning.asking[0..q.len], q);
    l.meaning.asking_len = q.len;
    l.meaning.epoch +%= 1;
    // A worker already out: its `finish` will see the new epoch and ask
    // again for the words now in the field. Returning here without that
    // would leave the new query with no answer at all.
    if (l.meaning.busy) return;
    dispatch(l);
}

/// Starts a worker for the words currently in `asking`. Main thread only.
fn dispatch(l: *Live) void {
    if (l.meaning.busy or l.meaning.asking_len == 0) return;
    // A query is using the server again: any queued idle stop is stale.
    l.meaning.idle_token +%= 1;
    const job = l.app.gpa.create(AskJob) catch return;
    job.* = .{ .live = l, .len = l.meaning.asking_len, .epoch = l.meaning.epoch };
    @memcpy(job.text[0..job.len], l.meaning.asking[0..job.len]);
    l.meaning.busy = true;
    const thread = std.Thread.spawn(.{}, AskJob.run, .{job}) catch {
        l.meaning.busy = false;
        l.app.gpa.destroy(job);
        return;
    };
    thread.detach();
}

const AskJob = struct {
    live: *Live,
    text: [256]u8 = undefined,
    len: usize,
    epoch: u64,
    got: bool = false,
    vec: [@import("vector_index.zig").dimension]f32 = undefined,

    /// Only the model call: no `Live` state is touched here.
    fn run(job: *AskJob) void {
        job.got = embedOne(&job.live.meaning.server, job.live.app.io, job.live.app.gpa, job.text[0..job.len], &job.vec);
        // Back to the main thread for everything else.
        nanoui.App.after(0, job, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *AskJob = @ptrCast(@alignCast(ctx.?));
        const l = job.live;
        defer l.app.gpa.destroy(job);
        l.meaning.busy = false;

        if (job.got) {
            // The index, read once on the main thread.
            if (!l.meaning.index_loaded) {
                var path_buf: [model.max_path]u8 = undefined;
                const path = indexPath(&path_buf);
                if (path.len > 0) {
                    l.meaning.index = vectors.Index.loadFor(l.app.io, l.app.gpa, path, model.fingerprint) catch .{ .gpa = l.app.gpa };
                }
                l.meaning.index_loaded = true;
            }
            // Only a vector for the words still in the field counts.
            if (job.epoch == l.meaning.epoch) {
                l.s.meaningAnswered(job.text[0..job.len], &job.vec, &l.meaning.index);
            }
        }
        if (l.window) |w| w.redraw();
        // If words changed while this was out, ask for them now. This is
        // what makes continuous typing end with the right answer.
        if (shouldRedispatch(job.epoch, l.meaning.epoch)) {
            dispatch(l);
        } else {
            scheduleIdleStop(l);
        }
    }
};

/// One text's vector, from the runtime. False when the server or the model
/// is not there, or the answer is not a vector.
fn embedOne(srv: *runtime.Server, io: std.Io, gpa: std.mem.Allocator, text: []const u8, out: *[vectors.dimension]f32) bool {
    if (!srv.ensure(io, gpa)) return false;

    var qbuf: [512]u8 = undefined;
    const framed = model.queryText(&qbuf, text) orelse return false;
    var body_buf: [runtime.jsonBound(512, 1)]u8 = undefined;
    const body = runtime.requestBody(&body_buf, &.{framed}) orelse return false;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/embeddings", .{runtime.port}) catch return false;
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &aw.writer,
    }) catch return false;
    if (res.status != .ok) return false;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var got: [1][]f32 = undefined;
    const n = runtime.parseVectors(arena.allocator(), aw.written(), &got) catch return false;
    if (n == 0 or got[0].len != vectors.dimension) return false;
    @memcpy(out, got[0][0..vectors.dimension]);
    vectors.normalize(out);
    return true;
}

test "the index lives beside the model" {
    const t = std.testing;
    var buf: [model.max_path]u8 = undefined;
    const path = indexPath(&buf);
    if (path.len == 0) return error.SkipZigTest;
    try t.expect(std.mem.endsWith(u8, path, index_name));
    try t.expect(std.mem.indexOf(u8, path, ".nanolight/models") != null);
}

test "typing while a worker is out asks again for the new words" {
    const t = std.testing;
    // The bug: `ask` bumped the epoch and returned when busy, and the
    // in-flight answer was dropped on the mismatch, leaving no worker for
    // the new words. `finish` now re-dispatches when the epoch moved.
    try t.expect(!shouldRedispatch(7, 7));   // no typing: keep the answer
    try t.expect(shouldRedispatch(7, 8));    // one new query: ask again
    try t.expect(shouldRedispatch(7, 11));   // several: still ask again
    // Epoch wraps on overflow; equality is still the only thing that
    // decides whether the answer matches the field.
    try t.expect(!shouldRedispatch(std.math.maxInt(u64), std.math.maxInt(u64)));
}
