const std = @import("std");
const TTY = @import("./TTY.zig");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const Dir = std.fs.Dir;
const eql = std.mem.eql;
const extension = std.fs.path.extension;
const isDigit = std.ascii.isDigit;

/// Limit number of parent directories to scan (inclusive of current directory)
const max_scan_depth = 5;

pub const Prop = enum {
    bun,
    deno,
    docker,
    git,
    node,
    rust,
    zig,

    /// Nerd font unicode characters
    pub fn symbol(prop: Prop) []const u8 {
        return switch (prop) {
            .bun => "",
            .deno => "",
            .docker => "󰡨",
            .git => "",
            .node => "󰎙",
            .rust => "󱘗",
            .zig => "",
        };
    }

    /// Spawn child process to get the version string.
    /// If successful, caller owns result.
    pub fn version(prop: Prop, allocator: Allocator) ?[]const u8 {
        if (prop.versionArgv()) |argv| {
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = argv,
            }) catch return null;
            if (result.term == .Exited) {
                allocator.free(result.stderr);
                return result.stdout;
            }
            allocator.free(result.stderr);
            allocator.free(result.stdout);
        }
        return null;
    }

    /// Get the version command arguments
    pub fn versionArgv(prop: Prop) ?[]const []const u8 {
        return switch (prop) {
            .bun => &.{ "bun", "-v" },
            .deno => &.{ "deno", "-v" },
            .docker => &.{ "docker", "-v" },
            .node => &.{ "node", "-v" },
            .rust => &.{ "rustc", "--version" },
            .zig => &.{ "zig", "version" },
            else => null,
        };
    }

    /// Returns a version slice, e.g. "1.0.0", trimming additional text
    pub fn versionFormat(prop: Prop, string: []const u8) []const u8 {
        _ = prop;
        var start: usize = 0;
        var end: usize = 0;
        for (0..string.len) |i| if (isDigit(string[i])) {
            start = i;
            break;
        };
        for (start..string.len) |i| if (string[i] != '.' and !isDigit(string[i])) {
            end = i;
            break;
        };
        return if (start < end) string[start..end] else "";
    }
};

const Context = @This();

allocator: Allocator,
cwd: Dir,
props: AutoHashMap(Prop, void),
project: ?[]const u8 = null,

pub fn init(allocator: Allocator, cwd: Dir) Context {
    return Context{
        .allocator = allocator,
        .cwd = cwd,
        .props = AutoHashMap(Prop, void).init(allocator),
    };
}

pub fn deinit(self: *Context) void {
    if (self.project) |p| self.allocator.free(p);
    self.props.deinit();
}

pub fn is(self: Context, prop: Prop) bool {
    return self.props.contains(prop);
}

/// Write formatted prompt line
pub fn print(self: Context, tty: *TTY) !void {
    if (self.project) |p| {
        try tty.color(.reset);
        try tty.print(" | ", .{});
        try tty.color(.cyan);
        try tty.color(.bold);
        try tty.print("{s}", .{p});
    }
    inline for (std.meta.fields(Prop)) |field| {
        try tty.color(.reset);
        const prop: Prop = @enumFromInt(field.value);
        if (self.props.contains(prop)) {
            if (prop != .git) {
                try tty.write(" | ");
                try tty.color(.yellow);
                try tty.write(prop.symbol());
                const version = prop.version(self.allocator);
                if (version) |string| {
                    defer self.allocator.free(string);
                    try tty.write(" ");
                    try tty.write(prop.versionFormat(string));
                }
            }
        }
    }
    if (self.is(.git)) {
        if (self.gitBranch()) |branch| {
            const dirty = self.gitDirty();
            defer self.allocator.free(branch);
            try tty.color(.reset);
            try tty.write(" on ");
            try tty.color(if (dirty) .red else .magenta);
            try tty.color(.bold);
            try tty.print("{s} {s}{s}", .{
                Prop.git.symbol(),
                std.mem.trimRight(u8, branch, " \n"),
                if (dirty) "*" else "",
            });
        }
    }
    try tty.color(.reset);
}

pub fn setProject(self: *Context, name: []const u8) void {
    if (self.project) |p| self.allocator.free(p);
    self.project = self.allocator.dupe(u8, name) catch null;
}

pub fn gitBranch(self: Context) ?[]const u8 {
    if (!self.is(.git)) return null;
    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &.{ "git", "branch", "--show-current" },
    }) catch return null;
    if (result.term == .Exited) {
        self.allocator.free(result.stderr);
        return result.stdout;
    }
    self.allocator.free(result.stderr);
    self.allocator.free(result.stdout);
    return null;
}

pub fn gitDirty(self: Context) bool {
    if (!self.is(.git)) return false;
    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &.{ "git", "diff", "--no-ext-diff", "--quiet", "--exit-code" },
    }) catch return false;
    self.allocator.free(result.stderr);
    self.allocator.free(result.stdout);
    return switch (result.term) {
        .Exited => |code| (code == 1),
        else => false,
    };
}

/// Scan parent directories to populate context
pub fn scanAll(self: *Context) !void {
    var dir = try self.cwd.openDir(".", .{ .iterate = true });
    defer dir.close();
    var depth: usize = 0;
    while (true) : (depth += 1) {
        if (depth == max_scan_depth) break;
        const path = try dir.realpathAlloc(self.allocator, ".");
        defer self.allocator.free(path);
        self.scanDirectory(&dir, std.fs.path.basename(path));
        const parent = try dir.openDir("../", .{ .iterate = true });
        dir.close();
        dir = parent;
        // Exit once root is reached

        if (eql(u8, path, "/")) break;
    }
    // Remove Node.js false positive
    if (self.is(.node)) {
        if (self.is(.bun) or self.is(.deno)) {
            _ = self.props.remove(.node);
        }
    }
}

/// Check all entries inside the open directory
pub fn scanDirectory(self: *Context, dir: *Dir, dir_name: []const u8) void {
    var iter = dir.iterate();
    while (iter.next()) |next| {
        if (next) |entry| self.scanEntry(entry, dir_name) else break;
    } else |_| return;
}

/// Check an individual directory entry
pub fn scanEntry(self: *Context, entry: Dir.Entry, dir_name: []const u8) void {
    const result: ?Prop = switch (entry.kind) {
        .directory => result: {
            if (eql(u8, entry.name, ".git")) {
                self.setProject(dir_name);
                break :result .git;
            } else if (eql(u8, entry.name, "node_modules")) {
                break :result .node;
            } else if (eql(u8, entry.name, "zig-out")) {
                break :result .zig;
            }
            break :result null;
        },
        .file, .sym_link => result: {
            const ext = extension(entry.name);
            if (eql(u8, entry.name, "bun.lock")) {
                break :result .bun;
            } else if (eql(u8, entry.name, "bun.lockb")) {
                break :result .bun;
            } else if (eql(u8, entry.name, "bunfig.toml")) {
                break :result .bun;
            } else if (eql(u8, entry.name, "Cargo.lock")) {
                break :result .rust;
            } else if (eql(u8, entry.name, "Cargo.toml")) {
                break :result .rust;
            } else if (eql(u8, entry.name, "deno.json")) {
                break :result .deno;
            } else if (eql(u8, entry.name, "deno.jsonc")) {
                break :result .deno;
            } else if (eql(u8, entry.name, "deno.lock")) {
                break :result .deno;
            } else if (eql(u8, entry.name, "docker-compose.yml")) {
                break :result .docker;
            } else if (eql(u8, entry.name, "package.json")) {
                break :result .node;
            } else if (eql(u8, ext, ".rs")) {
                break :result .rust;
            } else if (eql(u8, ext, ".zig")) {
                break :result .zig;
            }
            break :result null;
        },
        else => null,
    };
    if (result) |prop| {
        self.props.put(prop, {}) catch unreachable;
    }
}
