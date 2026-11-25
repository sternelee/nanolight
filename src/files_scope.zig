//! The folders file search may look in: one path a line (home-relative with
//! `~`, or absolute), in the order they were chosen. The welcome and Settings
//! edit one of these (files_scope_view.zig); files.zig turns it into
//! Spotlight's `-onlyin` scopes, and it is kept in the app's kv.
//!
//! A folder under the home folder is kept as `~…`, so two machines' scopes
//! read the same, and a folder picked twice (once as `~/Desktop`, once as
//! `/Users/me/Desktop`) is one.
const std = @import("std");
const builtin = @import("builtin");

pub const max_path = 4096;
pub const max_folders = 8;
/// Chips a row holds before it wraps (files_scope_view.zig).
pub const per_row = 3;

/// What a fresh install's welcome starts with, and what a launch with no
/// folder kept yet searches. An empty scope chosen in Settings searches
/// nothing: it is never widened to these behind the user's back.
pub const defaults = [_][]const u8{ "~/Desktop", "~/Documents", "~/Downloads" };

pub fn home() []const u8 {
    const name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const v = std.c.getenv(name) orelse return "";
    return std.mem.span(v);
}

/// `~` at the front becomes the home folder; null when `~` starts something
/// that is not a folder path.
pub fn expand(buf: []u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~")) return path;
    if (path.len > 1 and path[1] != '/') return null;
    const h = home();
    if (h.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ h, path[1..] }) catch null;
}

/// A folder as its chip says it: "~/Pictures" is "Pictures".
pub fn label(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "~")) return "Home";
    const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
    return if (base.len > 0) base else path;
}

/// `path` as the scope keeps it, in `buf`; null when it is not a folder
/// path at all (relative, empty, or too long).
fn normalized(buf: []u8, path: []const u8) ?[]const u8 {
    var p = std.mem.trim(u8, path, " \t\r\n");
    if (p.len == 0 or p.len > max_path - 2) return null;
    if (p[0] != '/' and p[0] != '~') return null;
    if (p.len > 1) p = std.mem.trimEnd(u8, p, "/");
    const h = home();
    if (h.len > 0 and std.mem.startsWith(u8, p, h) and (p.len == h.len or p[h.len] == '/')) {
        return std.fmt.bufPrint(buf, "~{s}", .{p[h.len..]}) catch null;
    }
    @memcpy(buf[0..p.len], p);
    return buf[0..p.len];
}

/// The folders file search may look in, in a fixed buffer: text in, text out.
pub const Scope = struct {
    bytes: [max_path]u8 = undefined,
    len: usize = 0,

    pub fn text(s: *const Scope) []const u8 {
        return s.bytes[0..s.len];
    }

    pub fn lines(s: *const Scope) Lines {
        return .{ .s = s.text() };
    }

    pub fn count(s: *const Scope) usize {
        var it = s.lines();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    pub fn at(s: *const Scope, i: usize) ?[]const u8 {
        var it = s.lines();
        var k: usize = 0;
        while (it.next()) |line| : (k += 1) if (k == i) return line;
        return null;
    }

    pub fn has(s: *const Scope, path: []const u8) bool {
        var buf: [max_path]u8 = undefined;
        const p = normalized(&buf, path) orelse return false;
        var it = s.lines();
        while (it.next()) |line| if (std.mem.eql(u8, line, p)) return true;
        return false;
    }

    /// Adds a folder; false when it was already there, is not a folder path,
    /// or there is no room for another.
    pub fn add(s: *Scope, path: []const u8) bool {
        var buf: [max_path]u8 = undefined;
        const p = normalized(&buf, path) orelse return false;
        if (s.has(p)) return false;
        if (s.count() >= max_folders) return false;
        const sep: usize = @intFromBool(s.len > 0);
        if (s.len + sep + p.len > s.bytes.len) return false;
        if (sep == 1) {
            s.bytes[s.len] = '\n';
            s.len += 1;
        }
        @memcpy(s.bytes[s.len..][0..p.len], p);
        s.len += p.len;
        return true;
    }

    pub fn remove(s: *Scope, path: []const u8) bool {
        var buf: [max_path]u8 = undefined;
        const p = normalized(&buf, path) orelse return false;
        var out: [max_path]u8 = undefined;
        var n: usize = 0;
        var found = false;
        var it = s.lines();
        while (it.next()) |line| {
            if (std.mem.eql(u8, line, p)) {
                found = true;
                continue;
            }
            if (n > 0) {
                out[n] = '\n';
                n += 1;
            }
            @memcpy(out[n..][0..line.len], line);
            n += line.len;
        }
        if (!found) return false;
        @memcpy(s.bytes[0..n], out[0..n]);
        s.len = n;
        return true;
    }

    pub fn clear(s: *Scope) void {
        s.len = 0;
    }

    /// A kept scope, read back as it was written.
    pub fn fromText(t: []const u8) Scope {
        var s: Scope = .{};
        var it = std.mem.tokenizeAny(u8, t, "\r\n");
        while (it.next()) |line| _ = s.add(line);
        return s;
    }

    pub fn withDefaults() Scope {
        var s: Scope = .{};
        for (defaults) |d| _ = s.add(d);
        return s;
    }
};

pub const Lines = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Lines) ?[]const u8 {
        while (it.i < it.s.len) {
            const start = it.i;
            const end = std.mem.indexOfScalarPos(u8, it.s, start, '\n') orelse it.s.len;
            it.i = if (end < it.s.len) end + 1 else end;
            if (end > start) return it.s[start..end];
        }
        return null;
    }
};

test "a scope keeps home-relative folders, once each" {
    var s: Scope = .{};
    try std.testing.expect(s.add("~/Desktop"));
    try std.testing.expect(s.add("/opt/data"));
    try std.testing.expect(!s.add("~/Desktop/"));
    try std.testing.expect(!s.add("/opt/data"));
    try std.testing.expect(!s.add("relative/path"));
    try std.testing.expect(!s.add(""));
    try std.testing.expectEqual(@as(usize, 2), s.count());
    try std.testing.expectEqualStrings("~/Desktop\n/opt/data", s.text());
    try std.testing.expectEqualStrings("~/Desktop", s.at(0).?);
    try std.testing.expectEqualStrings("/opt/data", s.at(1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), s.at(2));
    try std.testing.expectEqualStrings("Desktop", label("~/Desktop"));
    try std.testing.expectEqualStrings("data", label("/opt/data/"));
    try std.testing.expectEqualStrings("Home", label("~"));
}

test "a scope reads back what it wrote, and forgets one folder" {
    var s = Scope.fromText("~/Documents\n\n~/Pictures\n");
    try std.testing.expectEqual(@as(usize, 2), s.count());
    try std.testing.expect(s.remove("~/Documents"));
    try std.testing.expectEqualStrings("~/Pictures", s.text());
    try std.testing.expect(!s.remove("~/Documents"));
    try std.testing.expect(s.remove("~/Pictures"));
    // Emptied, it stays empty: it searches nothing until a folder is added
    // again, and it is not quietly the defaults.
    try std.testing.expectEqual(@as(usize, 0), s.count());
    try std.testing.expectEqualStrings("", s.text());
    s = Scope.withDefaults();
    try std.testing.expectEqual(@as(usize, defaults.len), s.count());
    try std.testing.expectEqualStrings(defaults[0], s.at(0).?);
}

test "a folder under the home folder is kept home-relative" {
    const h = home();
    if (h.len == 0) return error.SkipZigTest;
    var s: Scope = .{};
    var buf: [max_path]u8 = undefined;
    const absolute = try std.fmt.bufPrint(&buf, "{s}/Projects", .{h});
    try std.testing.expect(s.add(absolute));
    try std.testing.expectEqualStrings("~/Projects", s.at(0).?);
    // The same folder, written the other way, is not a second one.
    try std.testing.expect(!s.add("~/Projects"));
    // A folder that only begins with the home folder's name is its own.
    const lookalike = try std.fmt.bufPrint(&buf, "{s}Work", .{h});
    try std.testing.expect(s.add(lookalike));
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "a scope is bounded, and expands back to real paths" {
    var s: Scope = .{};
    var buf: [64]u8 = undefined;
    for (0..max_folders + 4) |i| {
        const p = try std.fmt.bufPrint(&buf, "/opt/folder{d}", .{i});
        _ = s.add(p);
    }
    try std.testing.expectEqual(@as(usize, max_folders), s.count());
    var path: [max_path]u8 = undefined;
    if (home().len == 0) return;
    const expanded = expand(&path, "~/Desktop").?;
    try std.testing.expect(std.mem.endsWith(u8, expanded, "/Desktop"));
    try std.testing.expectEqualStrings("/opt/x", expand(&path, "/opt/x").?);
    try std.testing.expect(expand(&path, "~user/x") == null);
}
