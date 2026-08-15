const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_EQUIPMENT_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_EQUIPMENT_DATA, @as(
        protobuf.gen.SC_Equipment_Data,
        .init,
    ));
}
