const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_INTERACTSTATE_ALL_DATA_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_INTERACTSTATE_ALL_DATA_RSP, @as(
        protobuf.gen.SC_InteractState_All_Data_RSP,
        .init,
    ));
}
