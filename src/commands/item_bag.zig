const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_ITEM_BAG_GET_LIST(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_ITEM_BAG_GET_LIST, @as(
        protobuf.gen.SC_Item_Bag_Get_List,
        .init,
    ));
}
