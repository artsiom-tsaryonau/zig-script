#!/usr/bin/env zs

//DEPS gh:Hejsil/zig-clap/0.12.0 AS clap

const clap = @import("clap");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\...
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "clap: help\n");
        return;
    }

    try std.Io.File.stdout().writeStreamingAll(init.io, "clap: ok\n");
}
