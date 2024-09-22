pub const lib = @cImport({
    @cInclude("sqlite3.h");
});

pub const PreparedStatement = struct {};
pub const Database = struct {
    sqlite: lib.sqlite3,

    const Self = @This();
    const Error = error{CantOpen};
    pub fn init(file: []const u8) Error!Self {
        var s: lib.sqlite3 = undefined;
        const status = lib.sqlite3_open(file, &s);
        if (status == 0) {
            return error.CantLoad;
        }
        return Database{ .sqlite = s.? };
    }
    pub fn deinit(self: *Self) void {
        lib.sqlite3_close(self.sqlite);
    }
};
