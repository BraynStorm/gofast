const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz");

const Gofast = @import("gofast.zig").Gofast;
const Tickets = @import("tickets.zig");
const SString = @import("smallstring.zig").ShortString;
const Giberish = @import("gibberish.zig");

const Allocator = std.mem.Allocator;
const StrLiteral = []const u8;

const Ticket = Tickets.Ticket;
const TicketStore = Tickets.Ticket;

pub const std_options = .{
    .log_level = switch (builtin.mode) {
        .Debug => std.log.Level.debug,
        else => std.log.Level.info,
    },
};

// TODO: Remove this at some point, start passing the allocator around.
var ALLOC: Allocator = undefined;

fn init_gofast(gofast: *Gofast) !void {
    if (gofast.tickets.max_key == 0 and gofast.tickets.name_priorities.items.len == 0) {
        std.log.info("Initializing Gofast from scratch.", .{});
        const alloc = gofast.tickets.alloc;
        try gofast.tickets.name_priorities.appendSlice(alloc, &[_]SString{
            try SString.fromSlice(alloc, "Immediate"),
            try SString.fromSlice(alloc, "Very Very High"),
            try SString.fromSlice(alloc, "Very High"),
            try SString.fromSlice(alloc, "High"),
            try SString.fromSlice(alloc, "Normal"),
            try SString.fromSlice(alloc, "Low"),
            try SString.fromSlice(alloc, "Tweak"),
            try SString.fromSlice(alloc, "Negligable"),
        });
        try gofast.tickets.name_types.appendSlice(alloc, &[_]SString{
            try SString.fromSlice(alloc, "Task"),
            try SString.fromSlice(alloc, "Bug"),
            try SString.fromSlice(alloc, "Feature"),
            try SString.fromSlice(alloc, "Milestone"),
        });
        try gofast.tickets.name_statuses.appendSlice(alloc, &[_]SString{
            try SString.fromSlice(alloc, "To Do"),
            try SString.fromSlice(alloc, "In Progress"),
            try SString.fromSlice(alloc, "Done"),
        });

        try Giberish.initGiberish(1000, 5, gofast, alloc);
        try gofast.save();
    }
    // Tickets.printChildrenGraph(&gofast.tickets, alloc);
}

pub fn main() !void {
    // ALLOC = std.heap.c_allocator;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    ALLOC = gpa.allocator();

    var gofast: Gofast = undefined;
    gofast = try Gofast.init(ALLOC, "persist.gfs");
    try init_gofast(&gofast);
    //TODO():
    //  Load these from a persistence file at some point.

    var server = try httpz.Server(*Gofast).init(ALLOC, .{
        .port = 20000,
        // .thread_pool = .{ .count = 4 },
        // .workers = .{ .count = 4 },
    }, &gofast);
    defer {
        server.stop();
        server.deinit();
    }

    var router = server.router(.{});

    //--------------------------------------------------------------------------
    // ENDPOINTS
    //

    //TODO:
    //  These should be merged as some central static file delivery method,
    //  similar to fastapi's StaticFiles "middle"ware.

    //TODO: Use @embedFile to have them as "DEFAULTS" but still allow HDD edits, fswatch and reload.
    simpleStaticFile(router, "/", "static/ui/index.html");
    simpleStaticFile(router, "/wasm", "zig-out/bin/gofast.wasm");

    simpleStaticFiles(router, "/static/*", "static");

    router.get("/api/tickets", apiGetTickets, .{});
    router.post("/api/init", apiGetInit, .{});
    router.post("/api/tickets", apiPostTicket, .{});
    router.delete("/api/ticket/:key", apiDeleteTicket, .{});
    router.patch("/api/ticket/:key", apiPatchTicket, .{});
    router.patch("/api/ticket/:key/work/:person", apiPatchTicketWork, .{});

    //
    // END OF ENDPOINTS
    //--------------------------------------------------------------------------

    std.log.info("GOFAST @ http://127.0.0.1:{}", .{server.config.port orelse 0});
    try server.listen();
}

fn simpleStaticFiles(router: anytype, comptime endpoint: StrLiteral, comptime relative_path: StrLiteral) void {
    // Invalid path...
    comptime std.debug.assert(relative_path[relative_path.len - 1] != '.');

    router.get(endpoint, struct {
        /// Go over the path and verify that there are not ".." string in it.
        fn ensureNoDotDot(path: []const u8) !void {
            if (path.len < 1) {
                return;
            }

            for (1..path.len) |i| {
                if (path[i - 1] == '.' and path[i] == '.') {
                    return error.DotDot;
                }
            }
        }
        fn debug(comptime log: anytype, s: anytype) void {
            const fields: []const std.builtin.Type.StructField = comptime std.meta.fields(@TypeOf(s));

            inline for (fields) |field| {
                // NOTE: Useful for debugging the compiletime stuff.
                //  std.debug.print("{}\n\n", .{@typeInfo(field.type)});
                //  std.debug.print("{}\n\n", .{@typeInfo(field.type).Pointer});
                const fmt = switch (@typeInfo(field.type)) {
                    .Pointer => |pp| switch (pp.size) {
                        .C => "{s}",
                        .One => "{s}",
                        .Slice => "{s}",
                        .Many => "{s}",
                    },
                    else => "{}",
                };
                log.debug(field.name ++ " = " ++ fmt, .{@field(s, field.name)});
            }
        }
        fn handler(_: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
            // Prefix, because the endpoint ends with a *, we need to strip it.
            // /static/* => /static/
            const log = std.log.scoped(.static);

            const url_prefix = endpoint[0 .. endpoint.len - 1];
            // debug(log, .{ .url_prefix = url_prefix });

            // => "/static/x/y/z.ext"
            const url_path = req.url.path;
            // debug(log, .{ .url_path = url_path });

            // => ./static/
            const path_prefix = switch (relative_path[0]) {
                '/', '\\' => relative_path[1..],
                else => relative_path[0..],
            };
            // debug(log, .{ .path_prefix = path_prefix });

            // Cut the prefix, "x/y/./z.ext"
            const relative = url_path[url_prefix.len..];
            // debug(log, .{ .relative = relative });

            try ensureNoDotDot(relative);

            // Reuse some spare space for path concatenation.
            var small_buf = std.heap.FixedBufferAllocator.init(req.spare);
            const small_alloc = small_buf.allocator();
            // log.debug("simpleStaticFiles: buffer size {}B", .{req.spare.len});

            const extra_slash: u1 = switch (path_prefix[path_prefix.len - 1]) {
                // Slash is already there?
                '/', '\\' => 0,
                // Nope, we have to add it
                else => 1,
            };

            // Construct the relative path here.
            // Ensure we have enough space, so add 1 for the slash in the switch.
            // We can use *AssumeCapacity methods afterwards.
            var path_buf = try std.ArrayListUnmanaged(u8).initCapacity(
                small_alloc,
                path_prefix.len + relative.len + extra_slash,
            );

            // == "./static" and maybe a sash at the end
            path_buf.appendSliceAssumeCapacity(path_prefix);

            // == "./static/" 100%
            if (extra_slash == 1) {
                path_buf.appendAssumeCapacity('/');
            }

            // == "./static/x/y/./z.ext"
            path_buf.appendSliceAssumeCapacity(relative);
            setContentType(path_buf.items, res);

            std.log.info("GET {s}", .{url_path});
            sendStaticFile(
                small_alloc,
                path_buf.items,
                res.writer(),
                small_buf.buffer.len - small_buf.end_index,
            ) catch |e| switch (e) {
                std.fs.File.OpenError.FileNotFound => {
                    res.status = 404;
                },
                std.mem.Allocator.Error.OutOfMemory => {
                    log.err(
                        "static | Failed to allocate file buffer.\nrequested={s}\nresolved ={s}",
                        .{ url_path, path_buf.items },
                    );
                    res.status = 500;
                },
                else => return e,
            };
            res.status = 200;
        }
    }.handler, .{});
}

fn simpleStaticFile(router: anytype, comptime endpoint: StrLiteral, comptime filepath: StrLiteral) void {
    router.get(endpoint, struct {
        fn handler(_: *Gofast, _: *httpz.Request, res: *httpz.Response) !void {
            setContentType(filepath, res);
            try sendStaticFile(ALLOC, filepath, res.writer(), null);
            res.status = 200;
            std.log.info("GET  " ++ endpoint ++ " | " ++ filepath, .{});
        }
    }.handler, .{});
}

fn sstringArrayToStringArray(alloc: Allocator, sstringArray: []const SString) ![][]const u8 {
    var arr = try alloc.alloc([]const u8, sstringArray.len);
    for (sstringArray, 0..) |desc, i| {
        arr[i] = desc.s;
    }
    return arr;
}
/// TODO: Think of a better name.
/// This function servers the name_* fields, and other such things that
/// the frontend needs and are small and rarely changing.
fn apiGetInit(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    const t_start = std.time.nanoTimestamp();

    const alloc = ALLOC;
    const tickets = gofast.tickets;
    const len = tickets.tickets.len;

    std.log.info("GET  /api/init", .{});
    const name_priorities = try sstringArrayToStringArray(alloc, tickets.name_priorities.items);
    defer alloc.free(name_priorities);

    const name_types = try sstringArrayToStringArray(alloc, tickets.name_types.items);
    defer alloc.free(name_types);

    const name_statuses = try sstringArrayToStringArray(alloc, tickets.name_statuses.items);
    defer alloc.free(name_statuses);

    gofast.lock.lockShared();
    defer gofast.lock.unlockShared();

    try res.json(.{
        // single items
        .count = len,
        .max_key = gofast.tickets.max_key,
        // static arrays
        .name_types = name_types,
        .name_priorities = name_priorities,
        .name_statuses = name_statuses,
    }, .{ .whitespace = .minified });
    res.status = 200;
    _ = req;
    const t_end = std.time.nanoTimestamp();
    const took = t_end - t_start;
    std.log.info("apiGetInit took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
}
fn apiGetTickets(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    const t_start = std.time.nanoTimestamp();

    const alloc = ALLOC;
    const tickets = gofast.tickets;
    const time_spent = tickets.ticket_time_spent;
    const ticket_slice = tickets.tickets.slice();
    const time_spent_slice = time_spent.slice();
    const len = tickets.tickets.len;

    std.log.info("GET  /api/tickets | {} ticket(s).", .{len});

    const titles = try sstringArrayToStringArray(alloc, ticket_slice.items(.title));
    defer alloc.free(titles);

    const descriptions = try sstringArrayToStringArray(alloc, ticket_slice.items(.description));
    defer alloc.free(descriptions);

    const types = try alloc.alloc(Ticket.Type, len);
    defer alloc.free(types);
    const statuses = try alloc.alloc(Ticket.Status, len);
    defer alloc.free(statuses);
    const priorities = try alloc.alloc(Ticket.Priority, len);
    defer alloc.free(priorities);
    const orders = try alloc.alloc(Ticket.Order, len);
    defer alloc.free(orders);
    for (tickets.tickets.items(.details), 0..) |d, i| {
        types[i] = d.type;
        statuses[i] = d.status;
        priorities[i] = d.priority;
        orders[i] = d.order;
    }

    const name_priorities = try sstringArrayToStringArray(alloc, tickets.name_priorities.items);
    defer alloc.free(name_priorities);

    const name_types = try sstringArrayToStringArray(alloc, tickets.name_types.items);
    defer alloc.free(name_types);

    const name_statuses = try sstringArrayToStringArray(alloc, tickets.name_statuses.items);
    defer alloc.free(name_statuses);

    const name_people = try sstringArrayToStringArray(alloc, tickets.name_people.items);
    defer alloc.free(name_people);

    var t_estimated = try alloc.alloc(Ticket.TimeSpent.Seconds, time_spent.len);
    defer alloc.free(t_estimated);
    var t_spent = try alloc.alloc(Ticket.TimeSpent.Seconds, time_spent.len);
    defer alloc.free(t_spent);
    for (time_spent_slice.items(.time), 0..) |tt, i| {
        t_estimated[i] = tt.estimate;
        t_spent[i] = tt.spent;
    }

    // comptime std.debug.assert(@sizeOf(Ticket.Details) == @sizeOf(u64));

    {
        gofast.lock.lockShared();
        defer gofast.lock.unlockShared();

        try res.json(.{
            // single items
            .count = len,
            .max_key = gofast.tickets.max_key,
            // static arrays
            .name_types = name_types,
            .name_priorities = name_priorities,
            .name_statuses = name_statuses,
            .name_people = name_people,
            // arrays
            .tickets = .{
                // .details = @as([*]u64, @ptrCast(ticket_slice.items(.details).ptr))[0..len],
                .keys = ticket_slice.items(.key),
                .parents = ticket_slice.items(.parent),
                .titles = titles,
                .descriptions = descriptions,
                //NOTE(bozho2): JSON treats slices of u8 as strings...
                .types = @as([*]i8, @ptrCast(types.ptr))[0..len],
                .statuses = @as([*]i8, @ptrCast(statuses.ptr))[0..len],
                .priorities = @as([*]i8, @ptrCast(priorities.ptr))[0..len],
                .orders = orders,
                .creators = ticket_slice.items(.creator),
                .created_on = ticket_slice.items(.created_on),
                .last_updated_by = ticket_slice.items(.last_updated_by),
                .last_updated_on = ticket_slice.items(.last_updated_on),
            },
            // multiple arrays
            .ticket_time = .{
                .tickets = time_spent_slice.items(.ticket),
                .people = time_spent_slice.items(.person),
                .estimates = t_estimated,
                .spent = t_spent,
            },
        }, .{
            .whitespace = .minified,
        });
    }

    res.status = 200;
    _ = req;
    const t_end = std.time.nanoTimestamp();
    const took = t_end - t_start;
    std.log.info("apiGetTickets took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
}
fn apiPostTicket(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    var maybe_json = try req.jsonObject();
    if (maybe_json) |*json| {
        defer json.deinit();
        const title = (json.get("title") orelse {
            return error.NoTitle;
        }).string;
        const description = (json.get("description") orelse {
            return error.NoDescription;
        }).string;
        const maybe_parent: ?Ticket.Key = if (json.get("parent")) |mpj|
            switch (mpj) {
                .integer => |s| @intCast(s),
                .null => null,
                else => return error.ParentMustBeIntOrNull,
            }
        else
            null;
        const priority_i64: i64 = (json.get("priority") orelse {
            return error.NoPriority;
        }).integer;
        const type_ = (json.get("type") orelse {
            return error.NoType;
        }).integer;
        const status = (json.get("status") orelse {
            return error.NoStatus;
        }).integer;

        std.log.info("POST /api/tickets | title={s}, description={s}, parent={?}", .{
            title,
            description,
            maybe_parent,
        });

        const new_key = blk: {
            gofast.lock.lock();
            defer gofast.lock.unlock();
            break :blk try gofast.createTicket(.{
                .title = title,
                .description = description,
                .parent = maybe_parent,
                .type_ = @intCast(type_),
                .status = @intCast(status),
                .priority = @intCast(priority_i64),
                // TODO: Add authentication
                .creator = 0,
            });
        };

        res.status = 200;
        try res.json(new_key, .{});
    } else {
        res.status = 400;
    }

    _ = .{ gofast, req, res };
}
fn apiDeleteTicket(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    _ = .{ gofast, req, res };
    if (req.param("key")) |key_str| {
        const key = try std.fmt.parseInt(Ticket.Key, key_str, 10);
        {
            gofast.lock.lock();
            defer gofast.lock.unlock();
            try gofast.deleteTicket(key);
        }
        res.status = 200;
    } else {
        res.status = 400;
        return error.NoKey;
    }
}
fn apiPatchTicket(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    const key_str = req.param("key") orelse return error.NoKey;
    const key: Ticket.Key = try std.fmt.parseInt(Ticket.Key, key_str, 10);

    var maybe_json = try req.jsonObject();
    if (maybe_json) |*json| {
        defer json.deinit();

        if (json.count() > 0) {
            gofast.lock.lock();
            defer gofast.lock.unlock();

            //TODO: Authentication :). For now just use a placeholder "person"
            const updater: Ticket.Person = 0;

            try gofast.updateTicket(key, updater, .{
                .title = if (json.get("title")) |v| switch (v) {
                    .string => |str| str,
                    else => return error.InvalidValue,
                } else null,
                .description = if (json.get("description")) |v| switch (v) {
                    .string => |str| str,
                    else => return error.InvalidValue,
                } else null,
                .parent = if (json.get("parent")) |v| switch (v) {
                    .integer => |int| @as(Ticket.Key, @intCast(int)),
                    else => return error.InvalidValue,
                } else null,
                .type = if (json.get("type")) |v| switch (v) {
                    .integer => |int| @intCast(int),
                    else => return error.InvalidValue,
                } else null,
                .priority = if (json.get("priority")) |v| switch (v) {
                    .integer => |int| @intCast(int),
                    else => return error.InvalidValue,
                } else null,
                .status = if (json.get("status")) |v| switch (v) {
                    .integer => |int| @intCast(int),
                    else => return error.InvalidValue,
                } else null,
                .order = if (json.get("order")) |v| switch (v) {
                    .float => |float| @floatCast(float),
                    .integer => |int| @floatFromInt(int),
                    else => {
                        return error.InvalidValue;
                    },
                } else null,
            });
            try gofast.save();
        }
        res.status = 200;
    }
}
fn apiPatchTicketWork(gofast: *Gofast, req: *httpz.Request, res: *httpz.Response) !void {
    const key_str = req.param("key") orelse return error.NoKey;
    const key: Ticket.Key = try std.fmt.parseInt(Ticket.Key, key_str, 10);
    const person_str = req.param("person") orelse return error.NoPerson;
    const person: Ticket.Person = try std.fmt.parseInt(Ticket.Person, person_str, 10);

    var maybe_json = try req.jsonObject();
    if (maybe_json) |*json| {
        const t_started = if (json.get("timestamp_started")) |s| s.integer else 0;
        const t_ended = if (json.get("timestamp_ended")) |s| s.integer else 0;

        try gofast.logWork(key, person, t_started, t_ended);
        try gofast.save();
        res.status = 200;
    } else {
        res.status = 400;
    }
}
// =============================================================================
// Helpers
// =============================================================================

/// Set the response "Content-Type" based on the filepath's extension.
fn setContentType(path: []const u8, res: *httpz.Response) void {
    const last_dot_index = std.mem.lastIndexOfScalar(u8, path, '.') orelse 0;
    const path_extension = path[last_dot_index + 1 ..];

    //TODO:
    //  Support more mime-types.
    //
    //  PERF:
    //    Use a hashmap or something similar here.
    if (std.mem.eql(u8, "wasm", path_extension)) {
        res.header("Content-Type", "application/wasm");
    } else if (std.mem.eql(u8, "png", path_extension)) {
        res.header("Content-Type", "image/png");
    } else if (std.mem.eql(u8, "apng", path_extension)) {
        res.header("Content-Type", "image/apng");
    } else if (std.mem.eql(u8, "svg", path_extension)) {
        res.header("Content-Type", "image/svg+xml");
    } else if (std.mem.eql(u8, "css", path_extension)) {
        res.header("Content-Type", "text/css");
    } else if (std.mem.eql(u8, "js", path_extension) or std.mem.eql(u8, "mjs", path_extension)) {
        res.header("Content-Type", "application/javascript");
    }
}

/// Batch read-and-send a file from a relative path.
fn sendStaticFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    writer: httpz.Response.Writer.IOWriter,
    maybe_buffer: ?usize,
) !void {
    const buffer = maybe_buffer orelse 64000;
    const file = blk: {
        // Allocate the file_path only for open, free it immediately.
        const file_path = try std.fs.realpathAlloc(alloc, path);
        defer alloc.free(file_path);
        break :blk try std.fs.openFileAbsolute(file_path, .{});
    };
    defer file.close();

    const unaligned_rbuf = try alloc.alloc(u8, buffer);
    defer alloc.free(unaligned_rbuf);

    const aligned_rbuf_ptrint = std.mem.alignForward(usize, @intFromPtr(unaligned_rbuf.ptr), 64);
    const aligned_rbuf_ptr: [*]u8 = @ptrFromInt(aligned_rbuf_ptrint);
    const wasted_bytes: usize = @intFromPtr(aligned_rbuf_ptr) - @intFromPtr(unaligned_rbuf.ptr);
    const rbuf = aligned_rbuf_ptr[0 .. unaligned_rbuf.len - wasted_bytes];

    while (true) {
        const read_bytes = try file.readAll(rbuf);

        try writer.writeAll(rbuf[0..read_bytes]);

        if (read_bytes != rbuf.len) {
            // Reached the end.
            break;
        }
    }
}

test {
    // Run the tests for Gofast.
    _ = Gofast;
    _ = Tickets;
}
