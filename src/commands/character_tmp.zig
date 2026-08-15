const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_TMP_CHARACTER_LIST_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_TMP_CHARACTER_LIST_RSP, @as(
        protobuf.gen.SC_TmpCharacter_List_Rsp,
        .init,
    ));
}
