const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_BATTLE_PASS_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_BATTLE_PASS_DATA, @as(
        protobuf.gen.SC_Battle_Pass_Data,
        .init,
    ));
}
