//! What the Settings screen (settings_view.zig) asks of the app: the
//! shortcut, opening at login, the Codegraff account, updates. Optional,
//! like the panel's other host callbacks: tests, the film and the promo
//! draw Settings with defaults and call nothing.
const shortcut = @import("shortcut.zig");
const account = @import("account.zig");
const scope = @import("files_scope.zig");
const Theme = @import("palette.zig").Theme;

/// How an index build is going.
pub const IndexState = struct {
    running: bool = false,
    files_seen: usize = 0,
    files_indexed: usize = 0,
    /// How many kept their vector from the last build.
    files_reused: usize = 0,
    problem: []const u8 = "",
};

/// What Settings says about meaning search's model: whether it is here, and
/// how far a download has got.
pub const SemanticState = struct {
    /// The switch: meaning search is on.
    on: bool = false,
    /// The model is whole on this computer.
    ready: bool = false,
    /// A download is running.
    fetching: bool = false,
    /// 0 to 1, of both files.
    fraction: f64 = 0,
    /// Why it stopped, when it did.
    problem: []const u8 = "",
};

pub const SettingsHost = struct {
    ctx: *anyopaque,
    choice: *const fn (ctx: *anyopaque) shortcut.Choice,
    apply: *const fn (ctx: *anyopaque, c: shortcut.Choice) void,
    /// Starts or stops recording a key of one's own: the keys pressed go
    /// to `Settings.took`, not the panel (recorder.zig).
    record: *const fn (ctx: *anyopaque, on: bool) void,
    /// Whether it opens at login; `set` changes it first.
    login: *const fn (ctx: *anyopaque, set: ?bool) bool,
    /// Google's suggestions turned on or off in Settings.
    suggest: *const fn (ctx: *anyopaque, on: bool) void,
    /// File search turned on or off, with the folders it may use: kept.
    files: *const fn (ctx: *anyopaque, on: bool, locations: []const u8) void,
    /// The system's folder picker, adding what is chosen to the scope.
    folders: *const fn (ctx: *anyopaque, paths: *scope.Scope) void,
    /// Meaning search turned on or off: kept, and the model fetched if it
    /// is not here yet.
    semantic: *const fn (ctx: *anyopaque, on: bool) void,
    /// Whether the model is on this computer, and how its download is going.
    semantic_state: *const fn (ctx: *anyopaque) SemanticState,
    /// Starts (or retries) the model download.
    semantic_fetch: *const fn (ctx: *anyopaque) void,
    /// Builds the meaning index from the folders chosen.
    semantic_index: *const fn (ctx: *anyopaque) void,
    /// Whether an index build is running, and how far it got.
    index_state: *const fn (ctx: *anyopaque) IndexState,
    /// Return sends Google searches to the browser (on) or the panel.
    searches_out: *const fn (ctx: *anyopaque, on: bool) void,
    /// The panel's tint, chosen in Settings: kept for the next launch.
    theme: *const fn (ctx: *anyopaque, t: Theme) void,
    /// Whether the menu bar icon shows; `set` changes it first.
    menu_bar: *const fn (ctx: *anyopaque, set: ?bool) bool,
    account: *const fn (ctx: *anyopaque) account.State,
    email: *const fn (ctx: *anyopaque) []const u8,
    sign_in: *const fn (ctx: *anyopaque) void,
    sign_out: *const fn (ctx: *anyopaque) void,
    /// Codegraff's terms and privacy, in the browser.
    terms: *const fn (ctx: *anyopaque) void,
    /// The version running, and a newer one waiting (else null).
    version: *const fn (ctx: *anyopaque) []const u8,
    ready: *const fn (ctx: *anyopaque) ?[]const u8,
    check: *const fn (ctx: *anyopaque) void,
    restart: *const fn (ctx: *anyopaque) void,
    welcome: *const fn (ctx: *anyopaque) void,
    quit: *const fn (ctx: *anyopaque) void,
};
