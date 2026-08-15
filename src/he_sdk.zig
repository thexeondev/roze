pub const Account = @import("he_sdk/Account.zig");
pub const crypto = @import("he_sdk/crypto.zig");
pub const Bind = @import("he_sdk/Bind.zig");

test {
    _ = Account;
    _ = crypto;
    _ = Bind;
}

pub const AnyResponse = struct {
    code: i32,
    message: []const u8,
    ret: ?[]const u8,
};

pub const SafeLoginParam = struct {
    platform: []const u8,
    channelName: []const u8,
    subChannelName: []const u8,
    appId: []const u8,
    udid: []const u8,
    serverNode: []const u8,
    extraParams: [:0]u8,
    channelUid: []const u8,
    channelToken: []const u8,
    deviceModel: []const u8,
    deviceBrand: []const u8,

    pub const Extra = struct {
        account: []const u8,
        password: []const u8,
    };
};

pub const SafeLoginRet = struct {
    channelToken: []const u8,
    channelUid: []const u8,
    expireTime: u64,
    heiToken: []const u8,
    passportId: u64,
    privacyAgreementStatus: u8,
    sdkUid: []const u8,
    subChannelName: []const u8,
    unionid: []const u8,
};

pub const CheckAccountRet = struct {
    accountStatus: u32,
    area: []const u8,
    firstBinding: bool,
    matching: bool,
};

pub const FetchCurrentTokenParam = struct {
    platform: []const u8,
    channelName: []const u8,
    subChannelName: []const u8,
    appId: []const u8,
    udid: []const u8,
    serverNode: []const u8,
    heiToken: []const u8,
    channelToken: []const u8,
    avatarPermission: []const u8,
};

pub const FetchCurrentTokenRet = struct {
    channelToken: []const u8,
    channelUid: []const u8,
    expireTime: u64,
    heiToken: []const u8,
    passportId: u64,
    sdkUid: []const u8,
    type: []const u8,
};
