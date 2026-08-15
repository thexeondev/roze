const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_WANTED_TALENT_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_WANTED_TALENT_RSP, @as(
        protobuf.gen.SC_Wanted_Talent_Rsp,
        .init,
    ));
}
