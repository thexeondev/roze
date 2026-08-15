const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_MAIL_GET_LIST(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_MAIL_GET_LIST, @as(
        protobuf.gen.SC_Mail_Get_List,
        .init,
    ));
}
