const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_HUNT_BOOK_QUERY_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_HUNT_BOOK_QUERY_RSP, @as(
        protobuf.gen.SC_Hunt_Book_Query_Rsp,
        .{ .book = .init },
    ));
}
