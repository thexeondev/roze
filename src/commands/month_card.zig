const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_MONTH_CARD_QUERY(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_MONTH_CARD_QUERY, @as(
        protobuf.gen.SC_Month_Card_Query,
        .{ .data = .init },
    ));
}
