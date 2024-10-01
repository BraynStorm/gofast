const std = @import("std");
const Gofast = @import("gofast.zig").Gofast;
const Ticket = Gofast.Ticket;
const SString = @import("smallstring.zig").ShortString;

const Allocator = std.mem.Allocator;

const RandomStringGenOptions = struct {
    min_word_len: usize = 1,
    max_word_len: usize = 18,
    min_words: usize = 1,
    max_words: usize,
};
fn RandomStringGen(o: RandomStringGenOptions) type {
    const randInt = std.rand.intRangeAtMost;
    const CharBuf = std.ArrayList(u8);
    return struct {
        const Self = @This();
        const RNG = std.rand.Random;

        fn generateWord(
            prng: RNG,
            buf: []u8,
        ) usize {
            const n = randInt(prng, usize, 1, buf.len);
            var valid_len: usize = 0;
            while (true) {
                // PERF:
                //  This is inefficient, it would be better if we just generate a buffer
                //  of characters, and start copying them back if they are 'valid' in
                //  the destination.
                std.rand.bytes(prng, buf[valid_len..n]);

                for (buf[valid_len..n], valid_len..) |char, i| {
                    buf[i] = std.ascii.toLower(buf[i]);
                    if (std.ascii.isWhitespace(char) or
                        !std.ascii.isAlphabetic(char))
                    {
                        valid_len = i;
                        break;
                    }
                } else {
                    // We didn't break, break out of the outer loop.
                    break;
                }

                // Okay, we've stopped somewhere, regenerate the bytes after valid_len,
                // to generate valid bytes...
            }

            return n;
        }
        fn randEndSentence(prng: RNG, cb: *CharBuf) void {
            const ends = [_]u8{ '.', '!', '?' };
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
                "\n",
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

/// Init some giberrish in the Gofast ticket system.
/// Used for DX improvement.
pub fn initGiberish(
    comptime n_tickets: usize,
    comptime n_people: usize,
    gofast: *Gofast,
    alloc: Allocator,
) !void {
    var prng = comptime std.rand.DefaultPrng.init(12344321 - 20);
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
        const max_type: Gofast.Ticket.Type = @intCast(gofast.name_types.items.len - 1);
        const max_priority: Gofast.Ticket.Priority = @intCast(gofast.name_priorities.items.len - 1);
        const max_status: Gofast.Ticket.Status = @intCast(gofast.name_statuses.items.len - 1);
        const max_person: Gofast.Person = @intCast(gofast.name_people.items.len - 1);

        var rand_title = try title_gen.generateWords(random, alloc);
        defer rand_title.deinit(alloc);
        var rand_description = try description_gen.generateWords(random, alloc);
        defer rand_description.deinit(alloc);

        const rand_type = std.rand.intRangeAtMost(random, Gofast.Ticket.Type, 0, max_type);
        const rand_priority = std.rand.intRangeAtMost(random, Gofast.Ticket.Priority, 0, max_priority);
        const rand_status = std.rand.intRangeAtMost(random, Gofast.Ticket.Status, 0, max_status);
        const rand_creator = std.rand.intRangeAtMost(random, Gofast.Person, 0, max_person);

        const rand_create = std.rand.intRangeAtMost(random, i64, now_start, now_end);
        const rand_update = std.rand.intRangeAtMost(random, i64, rand_create, now_end);
        const rand_updater = std.rand.intRangeAtMost(random, Gofast.Person, 0, max_person);

        const ticket = gofast.createTicket(rand_creator, .{
            .title = rand_title.s,
            .description = rand_description.s,
            .parent = null,
            .type_ = rand_type,
            .priority = rand_priority,
            .status = rand_status,
        }) catch unreachable;

        gofast.tickets.items(.created_on)[ticket - 1] = rand_create;
        gofast.tickets.items(.last_updated_on)[ticket - 1] = rand_update;
        gofast.tickets.items(.last_updated_by)[ticket - 1] = rand_updater;
    }

    // Set random parents.

    //BUG:
    //  This can produce cycles,

    for (0..n_tickets) |me_usize| {
        if (std.rand.int(random, u8) <= (180)) {
            const me: Ticket.Key = @intCast(1 + me_usize);
            while (true) {
                const parent = std.rand.intRangeAtMost(random, Ticket.Key, 1, n_tickets);

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
        if (std.rand.int(random, u8) <= (255 / 2)) {
            const key: Ticket.Key = @intCast(1 + ticket_i);
            const person: Gofast.Person = std.rand.intRangeAtMost(
                random,
                Gofast.Person,
                1,
                n_people,
            );

            // Generate them in minutes so we don't have to deal with seconds
            const estimated = std.rand.intRangeAtMost(random, Gofast.TimeSpent.Seconds, 1, 60 * 60) * 60;
            const worktime = std.rand.intRangeAtMost(random, Gofast.TimeSpent.Seconds, 1, 60 * 60) * 60;
            const time_started = std.rand.intRangeAtMost(random, i64, 1727000000, std.time.timestamp());

            try gofast.setEstimate(key, person, estimated);
            try gofast.logWork(key, person, time_started, time_started + worktime);
        }
    }

    const t_end = std.time.nanoTimestamp();
    const took = t_end - t_start;
    std.log.info("initGiberish took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
}
