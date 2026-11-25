//! A scope's folders as chips: each takes one out with its ×, and a last one
//! opens the system's folder picker. The welcome's file step and Settings
//! draw this same row, so both edit one set (files_scope.zig).
const std = @import("std");
const ui = @import("nanoui").ui;
const scope_mod = @import("files_scope.zig");
const Scope = scope_mod.Scope;
const Palette = @import("palette.zig").Palette;

pub const Actions = struct {
    ctx: *anyopaque,
    /// Opens the picker, which adds what is chosen to the scope it is given.
    add: ?*const fn (ctx: *anyopaque, scope: *Scope) void = null,
};

pub const chip_h: f32 = 28;
pub const gap: f32 = 8;
const chip_w: f32 = 150;
const add_w: f32 = 108;
/// What the picker's chip says.
pub const add_label = "+ Add Folder…";

/// The rows the chips need, the picker's included.
pub fn rows(s: *const Scope) usize {
    return @max(1, (s.count() + scope_mod.per_row - 1) / scope_mod.per_row);
}

pub fn height(s: *const Scope) f32 {
    const n: f32 = @floatFromInt(rows(s));
    return n * chip_h + (n - 1) * gap;
}

/// Draws the scope's folders; true when the scope changed (a folder taken
/// out, or the picker's chip opened), so the caller keeps it as it is now.
pub fn chips(c: *ui.Context, p: Palette, s: *Scope, act: ?Actions) bool {
    var dirty = false;
    const n = s.count();
    for (0..rows(s)) |row_i| {
        const row = ui.div(c).row().wFull().gap(gap);
        defer row.end();
        for (0..scope_mod.per_row) |k| {
            const path = s.at(row_i * scope_mod.per_row + k) orelse continue;
            const chip = ui.div(c).row().w(chip_w).h(chip_h).px(10).gap(6).itemsCenter().rounded(8).bg(p.tile).border(p.rim).control();
            defer chip.end();
            ui.icon(c, "folder", .{ .size = 11, .weight = .medium, .color = p.sub });
            ui.text(c, scope_mod.label(path), .{ .size = 12, .weight = .medium, .color = p.text, .truncate = .ellipsis });
            ui.spacer(c);
            // Its × takes the folder out; the picker adds one back.
            const x = ui.div(c).size(16, 16).rounded(4).center().control().hover(p.sel);
            defer x.end();
            ui.icon(c, "xmark", .{ .size = 9, .weight = .semibold, .color = p.sub.alpha(0.75) });
            if (x.clicked()) {
                if (s.remove(path)) dirty = true;
                c.changed = true;
            }
        }
        // The picker's chip goes after the last folder, on its row. It is
        // drawn without a host too (the film, a snapshot), where it does
        // nothing.
        if (n <= (row_i + 1) * scope_mod.per_row) {
            const add = ui.div(c).row().gap(6).h(chip_h).px(10).itemsCenter().rounded(8).control().border(p.rim).hover(p.sel);
            defer add.end();
            if (add.clicked()) {
                if (act) |a| if (a.add) |f| {
                    f(a.ctx, s);
                    dirty = true;
                    c.changed = true;
                };
            }
            ui.icon(c, "plus", .{ .size = 10, .weight = .semibold, .color = p.sub });
            ui.text(c, add_label, .{ .size = 12, .weight = .medium, .color = p.sub });
        }
    }
    return dirty;
}

test "chips fit the panel's width, three a row" {
    const t = std.testing;
    var s = Scope.withDefaults();
    try t.expectEqual(@as(usize, 1), rows(&s));
    try t.expectEqual(chip_h, height(&s));
    _ = s.add("/opt/one");
    _ = s.add("/opt/two");
    _ = s.add("/opt/three");
    try t.expectEqual(@as(usize, 2), rows(&s));
    try t.expectEqual(chip_h * 2 + gap, height(&s));
    // Three chips and the picker on one row still fit inside the panel.
    const inner: f32 = 680 - 40;
    try t.expect(3 * chip_w + 2 * gap + gap + add_w <= inner);
}
