const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_REQ_REDPOINT_LIST(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_REDPOINT_LIST, @as(
        protobuf.gen.SC_RedPoint_List,
        .init,
    ));
}
