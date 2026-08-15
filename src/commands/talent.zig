const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_TALENT_QUERY(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_TALENT_QUERY, @as(
        protobuf.gen.SC_Talent_Query,
        .init,
    ));
}
