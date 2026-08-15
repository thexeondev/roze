const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_CASE_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_CASE_DATA, @as(
        protobuf.gen.SC_Case_Data,
        .init,
    ));
}
