const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_LIMIT_GROUP_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_LIMIT_GROUP_RES, @as(
        protobuf.gen.SC_Limit_Group_Res,
        .init,
    ));
}
