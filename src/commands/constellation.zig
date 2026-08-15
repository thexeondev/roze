const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_CONSTELLATION_QUERY_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_CONSTELLATION_QUERY_RSP, @as(
        protobuf.gen.SC_Constellation_Query_Rsp,
        .init,
    ));
}
