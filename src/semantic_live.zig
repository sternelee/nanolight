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
    /// The runtime, started on the first search that needs it.
    server: runtime.Server = .{},
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

/// One download, off the main thread. It reports back through `nanoui.App.after`
/// so everything it touches is touched on the main thread.
const FetchJob = struct {
    live: *Live,
    dir: [model.max_path]u8 = undefined,
    dir_len: usize = 0,

    fn run(job: *FetchJob) void {
        const l = job.live;
        const io = l.app.io;
        const gpa = l.app.gpa;
        const dir = job.dir[0..job.dir_len];
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var out: [model.all.len]model.File = undefined;
        const n = download.missing(io, dir, &out);
        var problem: [128]u8 = @splat(0);
        var ok = true;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!download.fetchOne(io, gpa, dir, out[i], &l.meaning.progress, &problem)) {
                ok = false;
                break;
            }
        }
        // Back on the main thread, where the panel is.
        l.meaning.fetching = false;
        l.meaning.ready = ok and runtime.ready(io);
        if (!ok) {
            const n_problem = @min(problem.len, l.meaning.progress.problem_buf.len);
            @memcpy(l.meaning.progress.problem_buf[0..n_problem], problem[0..n_problem]);
            l.meaning.progress.problem_len = n_problem;
        }
        l.meaning.progress.phase = if (ok) .ready else .failed;
        if (l.window) |w| w.redraw();
        gpa.destroy(job);
    }
};

/// The query's vector, asked of the model. The answer comes back through
/// `nanoui.App.after`, on the main thread.
pub fn ask(ctx: *anyopaque, q: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (!l.s.meaning_on or !l.meaning.ready or q.len == 0 or q.len >= l.meaning.asking.len) return;
    @memcpy(l.meaning.asking[0..q.len], q);
    l.meaning.asking_len = q.len;
    l.meaning.epoch +%= 1;
    if (l.meaning.busy) return;
    const job = l.app.gpa.create(AskJob) catch return;
    job.* = .{ .live = l, .len = q.len, .epoch = l.meaning.epoch };
    @memcpy(job.text[0..q.len], q);
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

    fn run(job: *AskJob) void {
        const l = job.live;
        const io = l.app.io;
        const gpa = l.app.gpa;
        var vec_buf: [vectors.dimension]f32 = undefined;
        const got = embedOne(io, gpa, job.text[0..job.len], &vec_buf);
        l.meaning.busy = false;
        if (!got) {
            if (l.window) |w| w.redraw();
            gpa.destroy(job);
            return;
        }
        // The index, read once.
        if (!l.meaning.index_loaded) {
            var path_buf: [model.max_path]u8 = undefined;
            const path = indexPath(&path_buf);
            if (path.len > 0) {
                l.meaning.index = vectors.Index.load(io, gpa, path) catch .{ .gpa = gpa };
            }
            l.meaning.index_loaded = true;
        }
        // Only the query still in the field counts.
        if (job.epoch == l.meaning.epoch) {
            l.s.meaningAnswered(job.text[0..job.len], &vec_buf, &l.meaning.index);
            if (l.window) |w| w.redraw();
        }
        gpa.destroy(job);
    }
};

/// One text's vector, from the runtime. False when the server or the model
/// is not there, or the answer is not a vector.
fn embedOne(io: std.Io, gpa: std.mem.Allocator, text: []const u8, out: *[vectors.dimension]f32) bool {
    var srv: runtime.Server = .{};
    defer srv.stop(io);
    if (!srv.ensure(io, gpa)) return false;

    var qbuf: [512]u8 = undefined;
    const framed = model.queryText(&qbuf, text) orelse return false;
    var body_buf: [1024]u8 = undefined;
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
