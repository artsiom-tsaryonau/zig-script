#!/usr/bin/env zs

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const cwd_ptr = std.c.getenv("ZS_CWD");
    const cwd = if (cwd_ptr) |p| std.mem.span(p) else ".";

    var path_buf: [1024]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&path_buf, "{s}/config.json", .{cwd});

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, init.gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No config.json found at {s}. Creating sample JSON object...\n", .{config_path});
            try std.Io.File.stdout().writeStreamingAll(init.io, "{\"runner\":\"zs\",\"version\":1}\n");
            return;
        },
        else => return err,
    };
    defer init.gpa.free(contents);

    try std.Io.File.stdout().writeStreamingAll(init.io, contents);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
