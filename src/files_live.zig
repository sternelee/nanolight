//! File lookups run off the main thread; answers move their icons to the view.
//! The folders they may use are the ones the welcome and Settings chose
//! (files_scope.zig), kept here and handed to the worker with each ask.
const std = @import("std");
const nanoui = @import("nanoui");
const files = @import("files.zig");
const scope = @import("files_scope.zig");
const suggest = @import("suggest.zig");
const Live = @import("main.zig").Live;

/// File lookups share the suggestions' pause and keep at most one worker.
pub fn askFiles(ctx: *anyopaque, q: []const u8) void {
    if (!files.available() or q.len >= files.max_path) return;
    const l: *Live = @ptrCast(@alignCast(ctx));
    @memcpy(l.files.query[0..q.len], q);
    l.files.len = q.len;
    l.files.epoch +%= 1;
    l.files.waiting += 1;
    nanoui.App.after(suggest.pause_ms, l, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            const live: *Live = @ptrCast(@alignCast(c.?));
            live.files.waiting -= 1;
            if (live.files.waiting == 0) sendFiles(live);
        }
    }.f);
}

fn sendFiles(l: *Live) void {
    if (!files.available() or l.files.busy or l.files.waiting > 0 or l.files.sent == l.files.epoch or !l.s.files_on) return;
    const q = l.files.query[0..l.files.len];
    if (!std.mem.eql(u8, q, std.mem.trim(u8, l.s.query.text(), " \t\r\n"))) return;
    const a = l.app.gpa.create(FileAsk) catch return;
    a.* = .{ .live = l, .len = q.len, .epoch = l.files.epoch, .found = .{ .allocator = l.app.gpa } };
    @memcpy(a.text[0..q.len], q);
    // The folders as they are now: a change while a lookup runs asks again.
    a.locations = l.app.gpa.dupe(u8, l.s.files_scope.text()) catch null;
    a.exclusions = l.kv.get(l.app.gpa, files.exclusions_key) catch null;
    l.files.busy = true;
    l.files.sent = l.files.epoch;
    const thread = std.Thread.spawn(.{}, FileAsk.run, .{a}) catch {
        l.files.busy = false;
        a.destroy();
        return;
    };
    thread.detach();
}

/// One file query, with all filesystem, process and icon work off the UI thread.
const FileAsk = struct {
    live: *Live,
    text: [files.max_path]u8 = undefined,
    len: usize,
    epoch: u64,
    locations: ?[]u8 = null,
    exclusions: ?[]u8 = null,
    found: files.List = .{},
    ok: bool = false,

    fn run(a: *FileAsk) void {
        const q = a.text[0..a.len];
        if (files.isPath(q)) {
            files.complete(a.live.app.io, q, &a.found);
            a.ok = true;
        } else a.ok = files.find(a.live.app.io, q, a.locations orelse "", a.exclusions orelse "", &a.found);
        if (a.ok) a.found.icons();
        nanoui.App.after(0, a, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const a: *FileAsk = @ptrCast(@alignCast(ctx.?));
        const l = a.live;
        defer a.destroy();
        l.files.busy = false;
        if (a.ok and a.epoch == l.files.epoch) {
            l.s.filesAnswered(a.text[0..a.len], &a.found);
            if (l.window) |w| w.redraw();
        }
        sendFiles(l);
    }

    fn destroy(a: *FileAsk) void {
        const gpa = a.live.app.gpa;
        if (a.locations) |v| gpa.free(v);
        if (a.exclusions) |v| gpa.free(v);
        a.found.deinit();
        gpa.destroy(a);
    }
};

pub const State = struct {
    query: [files.max_path]u8 = undefined,
    len: usize = 0,
    waiting: u32 = 0,
    epoch: u64 = 0,
    sent: u64 = 0,
    busy: bool = false,
};

pub fn load(l: *Live) void {
    // File search is local to this computer and off unless turned on; the
    // folders chosen live beside the switch (files_scope.zig).
    if (!files.available()) return;
    const gpa = l.app.gpa;
    // The folders kept, or the ones a fresh install starts with; an empty
    // scope stays empty (a picked set of none searches nothing).
    if (l.kv.get(gpa, files.locations_key) catch null) |v| {
        defer gpa.free(v);
        l.s.files_scope = scope.Scope.fromText(v);
    } else l.s.files_scope = scope.Scope.withDefaults();
    if (l.kv.get(gpa, files.enabled_key) catch null) |v| {
        defer gpa.free(v);
        l.s.files_on = std.mem.eql(u8, v, "1");
    }
}

/// What Settings and the welcome keep: on or off, and the folders it may use.
/// The panel lists files again now (or stops listing them).
pub fn set(ctx: *anyopaque, on: bool, locations: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (!files.available()) return;
    l.s.files_on = on;
    l.s.files_scope = scope.Scope.fromText(locations);
    l.kv.set(files.enabled_key, if (on) "1" else "0") catch {};
    l.kv.set(files.locations_key, l.s.files_scope.text()) catch {};
    l.s.built = 1;
    l.s.rebuild();
    if (l.window) |w| w.redraw();
}

/// The system's folder picker, over the panel: what is chosen is added to
/// `chosen`, and kept with the rest of the scope.
pub fn choose(ctx: *anyopaque, chosen: *scope.Scope) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (!files.available()) return;
    const picked = (nanoui.dialog.open(l.app.gpa, .{
        .title = "Search Files In",
        .message = "Nanolight searches these folders, and nothing else.",
        .button = "Search Here",
        .files = false,
        .directories = true,
        .multiple = true,
    }) catch return) orelse return;
    defer nanoui.dialog.freePaths(l.app.gpa, picked);
    for (picked) |path| _ = chosen.add(path);
    set(l, l.s.files_on, chosen.text());
}
