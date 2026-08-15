const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_LETTER_ALL_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_LETTER_ALL_RSP, @as(
        protobuf.gen.SC_Letter_All_Rsp,
        .{ .has_opened_page = true },
    ));
}
