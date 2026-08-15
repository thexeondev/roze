const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_COMPENDIUM_GET_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_COMPENDIUM_GET_DATA, @as(
        protobuf.gen.SC_Compendium_Get_Data,
        .init,
    ));
}
