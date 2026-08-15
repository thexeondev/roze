const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_MULTI_SHOP_GOODS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_MULTI_SHOP_GOODS, @as(
        protobuf.gen.SC_Multi_Shop_Goods,
        .init,
    ));
}
