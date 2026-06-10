// Runtime value types — see SPEC.md §2
pub const Value = union(enum) {
    int: i64,
    float: f64,
    number, // TODO: software bignum
    bool_val: bool,
    null_val,
    string: []const u8,
    list: []const Value,
    record: []const Field,
    // func: *Closure,  TODO §4

    pub const Field = struct {
        key: []const u8,
        val: Value,
    };
};
