#!/usr/bin/env zs

const std = @import("std");

pub fn main() !void {
    try std.io.getStdOut().writer().print("Hello from Zig!\n", .{});
}
