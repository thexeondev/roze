const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_TASK_ACCEPT_INFO_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_TASK_ACCEPT_INFO_RSP, @as(
        protobuf.gen.SC_Task_Accept_Info_Rsp,
        .init,
    ));
}

pub fn CS_REQ_TASK_LIST(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_TASK_LIST, @as(
        protobuf.gen.SC_Task_List,
        .{ .task_data = .init },
    ));
}
