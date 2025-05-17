const std = @import("std");
const Gofast = @import("gofast.zig").Gofast;
const Ticket = Gofast.Ticket;
const SString = @import("SmallString.zig");

const Allocator = std.mem.Allocator;

const RandomStringGenOptions = struct {
    min_word_len: usize = 1,
    max_word_len: usize = 18,
    min_words: usize = 1,
    max_words: usize,
};
fn RandomStringGen(o: RandomStringGenOptions) type {
    const randInt = std.Random.intRangeAtMost;
    const CharBuf = std.ArrayList(u8);
    return struct {
        const Self = @This();
        const RNG = std.Random;

        const polish_chars = [_]struct {
            c: u21,
            C: u21,
            weight: f32,
        }{
            .{ .c = std.unicode.utf8Decode("a") catch unreachable, .C = std.unicode.utf8Decode("A") catch unreachable, .weight = 0.837 },
            .{ .c = std.unicode.utf8Decode("ą") catch unreachable, .C = std.unicode.utf8Decode("Ą") catch unreachable, .weight = 0.079 },
            .{ .c = std.unicode.utf8Decode("b") catch unreachable, .C = std.unicode.utf8Decode("B") catch unreachable, .weight = 0.193 },
            .{ .c = std.unicode.utf8Decode("c") catch unreachable, .C = std.unicode.utf8Decode("C") catch unreachable, .weight = 0.389 },
            .{ .c = std.unicode.utf8Decode("ć") catch unreachable, .C = std.unicode.utf8Decode("Ć") catch unreachable, .weight = 0.060 },
            .{ .c = std.unicode.utf8Decode("d") catch unreachable, .C = std.unicode.utf8Decode("D") catch unreachable, .weight = 0.335 },
            .{ .c = std.unicode.utf8Decode("e") catch unreachable, .C = std.unicode.utf8Decode("E") catch unreachable, .weight = 0.868 },
            .{ .c = std.unicode.utf8Decode("ę") catch unreachable, .C = std.unicode.utf8Decode("Ę") catch unreachable, .weight = 0.113 },
            .{ .c = std.unicode.utf8Decode("f") catch unreachable, .C = std.unicode.utf8Decode("F") catch unreachable, .weight = 0.026 },
            .{ .c = std.unicode.utf8Decode("g") catch unreachable, .C = std.unicode.utf8Decode("G") catch unreachable, .weight = 0.146 },
            .{ .c = std.unicode.utf8Decode("h") catch unreachable, .C = std.unicode.utf8Decode("H") catch unreachable, .weight = 0.125 },
            .{ .c = std.unicode.utf8Decode("i") catch unreachable, .C = std.unicode.utf8Decode("I") catch unreachable, .weight = 0.883 },
            .{ .c = std.unicode.utf8Decode("j") catch unreachable, .C = std.unicode.utf8Decode("J") catch unreachable, .weight = 0.228 },
            .{ .c = std.unicode.utf8Decode("k") catch unreachable, .C = std.unicode.utf8Decode("K") catch unreachable, .weight = 0.301 },
            .{ .c = std.unicode.utf8Decode("l") catch unreachable, .C = std.unicode.utf8Decode("L") catch unreachable, .weight = 0.224 },
            .{ .c = std.unicode.utf8Decode("ł") catch unreachable, .C = std.unicode.utf8Decode("Ł") catch unreachable, .weight = 0.238 },
            .{ .c = std.unicode.utf8Decode("m") catch unreachable, .C = std.unicode.utf8Decode("M") catch unreachable, .weight = 0.281 },
            .{ .c = std.unicode.utf8Decode("n") catch unreachable, .C = std.unicode.utf8Decode("N") catch unreachable, .weight = 0.569 },
            .{ .c = std.unicode.utf8Decode("ń") catch unreachable, .C = std.unicode.utf8Decode("Ń") catch unreachable, .weight = 0.016 },
            .{ .c = std.unicode.utf8Decode("o") catch unreachable, .C = std.unicode.utf8Decode("O") catch unreachable, .weight = 0.753 },
            .{ .c = std.unicode.utf8Decode("ó") catch unreachable, .C = std.unicode.utf8Decode("Ó") catch unreachable, .weight = 0.079 },
            .{ .c = std.unicode.utf8Decode("p") catch unreachable, .C = std.unicode.utf8Decode("P") catch unreachable, .weight = 0.287 },
            .{ .c = std.unicode.utf8Decode("r") catch unreachable, .C = std.unicode.utf8Decode("R") catch unreachable, .weight = 0.415 },
            .{ .c = std.unicode.utf8Decode("s") catch unreachable, .C = std.unicode.utf8Decode("S") catch unreachable, .weight = 0.413 },
            .{ .c = std.unicode.utf8Decode("ś") catch unreachable, .C = std.unicode.utf8Decode("Ś") catch unreachable, .weight = 0.072 },
            .{ .c = std.unicode.utf8Decode("t") catch unreachable, .C = std.unicode.utf8Decode("T") catch unreachable, .weight = 0.385 },
            .{ .c = std.unicode.utf8Decode("u") catch unreachable, .C = std.unicode.utf8Decode("U") catch unreachable, .weight = 0.206 },
            .{ .c = std.unicode.utf8Decode("w") catch unreachable, .C = std.unicode.utf8Decode("W") catch unreachable, .weight = 0.411 },
            .{ .c = std.unicode.utf8Decode("y") catch unreachable, .C = std.unicode.utf8Decode("Y") catch unreachable, .weight = 0.403 },
            .{ .c = std.unicode.utf8Decode("z") catch unreachable, .C = std.unicode.utf8Decode("Z") catch unreachable, .weight = 0.533 },
            .{ .c = std.unicode.utf8Decode("ź") catch unreachable, .C = std.unicode.utf8Decode("Ź") catch unreachable, .weight = 0.008 },
            .{ .c = std.unicode.utf8Decode("ż") catch unreachable, .C = std.unicode.utf8Decode("Ż") catch unreachable, .weight = 0.093 },
        };

        var weight_sum = blk: {
            var sum: f32 = 0;
            for (polish_chars) |pc| {
                sum += pc.weight;
            }
            break :blk sum;
        };

        /// Because why the fuck not
        fn randomPolishChar(prng: RNG, upper: bool) u21 {
            var r = std.Random.float(prng, f32) * weight_sum;
            for (polish_chars) |pc| {
                if (r < pc.weight) {
                    return if (upper) pc.C else pc.c;
                } else {
                    r -= pc.weight;
                }
            }
            unreachable;
        }

        fn generateWord(
            prng: RNG,
            buf: []u8,
        ) usize {
            const n = randInt(prng, usize, 1, buf.len);
            var i: usize = 0;
            for (0..n) |j| {
                const chosen_u21 = randomPolishChar(prng, j == 0);
                var char_buf: [6]u8 = undefined;
                const n_bytes = std.unicode.utf8Encode(chosen_u21, &char_buf) catch unreachable;
                if (i + n_bytes < buf.len) {
                    std.mem.copyForwards(u8, buf[i .. i + n_bytes], char_buf[0..n_bytes]);
                    i += n_bytes;
                } else {
                    break;
                }
            }

            return i;
        }
        fn randEndSentence(prng: RNG, cb: *CharBuf) void {
            const ends = [_]u8{ '.', '.', '.', '!', '?' };
            const idx = randInt(prng, usize, 0, ends.len);
            if (idx == 0) return;
            cb.appendAssumeCapacity(ends[idx - 1]);
        }
        fn randWordSep(prng: RNG, cb: *CharBuf) void {
            const seps = [_][]const u8{
                " ",
                " ",
                " ",
                " ",
                " ",
                " ",
                "\n\n",
                ",",
                ", ",
                ", ",
                ";",
                "; ",
                ":",
                ": ",
                ".",
                ". ",
                "!",
                "! ",
                "?",
                "? ",
            };
            const idx = randInt(prng, usize, 0, seps.len - 1);
            cb.appendSliceAssumeCapacity(seps[idx]);
        }
        pub fn generateWords(prng: RNG, alloc: Allocator) !SString {
            var word_buf = comptime [_]u8{0} ** o.max_word_len;
            const n_words = randInt(prng, usize, o.min_words, o.max_words);

            var string_buf = std.ArrayList(u8).init(alloc);
            try string_buf.ensureTotalCapacity(o.max_words * (o.max_word_len + 2));

            for (0..n_words) |i| {
                const word_len = generateWord(prng, &word_buf);

                if (i == 0) {
                    // At least have the dignity to start with a non-lowercase character.
                    word_buf[0] = std.ascii.toUpper(word_buf[0]);
                }

                string_buf.appendSliceAssumeCapacity(word_buf[0..word_len]);
                if (i == n_words - 1) {
                    randEndSentence(prng, &string_buf);
                } else {
                    randWordSep(prng, &string_buf);
                }
            }

            // Strip the last space
            if (string_buf.items[string_buf.items.len - 1] == ' ') {
                string_buf.shrinkAndFree(string_buf.items.len - 1);
            } else {
                string_buf.shrinkAndFree(string_buf.items.len);
            }

            return SString.fromOwnedSlice(string_buf.items);
        }
    };
}

/// WARNING!: Assumes no cycles in the graph.
///
/// Naive child recursive searcher.
fn isChildRecursive(
    alloc: Allocator,
    gofast: *Gofast,
    me: Ticket.Key,
    needle: Ticket.Key,
) bool {
    //TODO:
    //  This doesn't actually need to allocate, we could just iterate over the children,
    //  but this is much easier to implement right now, as I don't have a good
    //  way of accessing JUST the children, and have to manually walk the
    //  MultiArrayList... Later I will fix this.
    const children = gofast.ticketChildrenAlloc(me, alloc, 4) catch unreachable;
    defer alloc.free(children);

    // Do I even HAVE children?
    if (children.len == 0) return false;

    // Okay, is it one of them?
    if (std.mem.indexOfScalar(Ticket.Key, children, needle)) |_| return true;

    // Okay, is it a grand-child?
    for (children) |child| {
        if (isChildRecursive(alloc, gofast, child, needle)) {
            return true;
        }
    }

    // Sorry, needle is not my child/grand-child.
    return false;
}

/// Init some gibberish in the Gofast ticket system.
/// Used for DX improvement.
pub fn initGibberish(
    comptime n_tickets: usize,
    comptime n_people: usize,
    gofast: *Gofast,
    alloc: Allocator,
) !void {
    var prng = comptime std.Random.DefaultPrng.init(12344321 - 20);
    const random = prng.random();
    const t_start = std.time.nanoTimestamp();

    const title_gen = RandomStringGen(.{ .max_words = 12 });
    const description_gen = RandomStringGen(.{ .max_words = 105 });

    _ = try gofast.createPerson(.{ .name = "Asen Asenov" });
    _ = try gofast.createPerson(.{ .name = "Bozhidar Stoyanov" });
    _ = try gofast.createPerson(.{ .name = "Kaloyan Mitev" });

    try gofast.tickets.ensureTotalCapacity(gofast.alloc, n_tickets);

    const years_2 = 365 * std.time.ms_per_day;
    const now_end = Gofast.timestamp();
    const now_start = now_end - years_2;

    for (0..n_tickets) |_| {
        const max_type: Gofast.Ticket.Type = @intCast(gofast.names.types.items.len - 1);
        const max_priority: Gofast.Ticket.Priority = @intCast(gofast.names.priorities.items.len - 1);
        const max_status: Gofast.Ticket.Status = @intCast(gofast.names.statuses.items.len - 1);
        const max_person: Gofast.Person = @intCast(gofast.names.people.items.len - 1);

        var rand_title = try title_gen.generateWords(random, alloc);
        defer rand_title.deinit(alloc);
        var rand_description = try description_gen.generateWords(random, alloc);
        defer rand_description.deinit(alloc);

        const rand_type = std.Random.intRangeAtMost(random, Gofast.Ticket.Type, 0, max_type);
        const rand_priority = std.Random.intRangeAtMost(random, Gofast.Ticket.Priority, 0, max_priority);
        const rand_status = std.Random.intRangeAtMost(random, Gofast.Ticket.Status, 0, max_status);
        const rand_creator = std.Random.intRangeAtMost(random, Gofast.Person, 0, max_person);
        const rand_create = std.Random.intRangeAtMost(random, i64, now_start, now_end);

        const ticket = gofast.createTicket(rand_creator, rand_create, .{
            .title = rand_title.s,
            .description = rand_description.s,
            .parent = null,
            .type_ = rand_type,
            .priority = rand_priority,
            .status = rand_status,
        }) catch unreachable;

        const rand_update = std.Random.intRangeAtMost(random, i64, rand_create, now_end);
        const rand_updater = std.Random.intRangeAtMost(random, Gofast.Person, 0, max_person);

        // TODO: Make this actually generate history events.
        gofast.tickets.items(.last_updated_on)[ticket - 1] = rand_update;
        gofast.tickets.items(.last_updated_by)[ticket - 1] = rand_updater;
    }

    // Set random parents.

    //BUG:
    //  This can produce cycles,

    for (0..n_tickets) |me_usize| {
        if (std.Random.int(random, u8) <= (180)) {
            const me: Ticket.Key = @intCast(1 + me_usize);
            while (true) {
                const parent = std.Random.intRangeAtMost(random, Ticket.Key, 1, n_tickets);

                // Am I my own parent (weird)?
                if (parent == me) continue;

                // Is my parent my child/grandchild (cursed)?
                if (isChildRecursive(alloc, gofast, me, parent)) continue;

                // Okay, we can safely set this ticket as my  parent.
                try gofast.setParent(me, parent);
                break;
            }
        }
    }

    for (0..n_tickets) |ticket_i| {
        if (std.Random.int(random, u8) <= (255 / 2)) {
            const key: Ticket.Key = @intCast(1 + ticket_i);
            const person: Gofast.Person = std.Random.intRangeAtMost(
                random,
                Gofast.Person,
                1,
                n_people,
            );

            // Generate them in minutes so we don't have to deal with seconds
            const estimated = std.Random.intRangeAtMost(random, Gofast.TicketTime.Seconds, 1, 60 * 60) * 60;
            const worktime = std.Random.intRangeAtMost(random, Gofast.TicketTime.Seconds, 1, 60 * 60) * 60;
            const time_started = std.Random.intRangeAtMost(random, i64, 1727000000, std.time.timestamp());

            try gofast.setEstimate(key, person, estimated);
            try gofast.logWork(key, person, time_started, time_started + worktime);
        }
    }

    const t_end = std.time.nanoTimestamp();
    const took = t_end - t_start;
    std.log.info("initGibberish took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
}
