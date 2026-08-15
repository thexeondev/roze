const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_BUFF_SYNC(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_BUFF_SYNC, @as(
        protobuf.gen.SC_Buff_Sync,
        .init,
    ));
}
