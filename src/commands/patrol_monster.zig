const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_PATROL_MONSTER_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_PATROL_MONSTER_RES, @as(
        protobuf.gen.SC_Patrol_Monster_Res,
        .init,
    ));
}
