const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_ACTIVITY_LIST_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_ACTIVITY_LIST_RES, @as(
        protobuf.gen.SC_Activity_List_Res,
        .init,
    ));
}
