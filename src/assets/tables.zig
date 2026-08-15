pub const character: []const P_Character = @import("p_charactertable");
pub const level_up_template: []const P_LevelUpTemplate = @import("p_leveluptemplatetable");
pub const develop_attribute: []const P_DevelopAttribute = @import("p_developattributetable");
pub const battle_attribute: []const C_BattleAttribute = @import("c_battleattributetable");
pub const guide: []const C_Guide = @import("c_guidetable");
pub const guide_platform: []const P_GuidePlatform = @import("p_guideplatformtable");

pub const P_Character = struct {
    /// 角色ID
    id: u32,
    /// 角色身份（枚举）
    identity_type: i32,
    /// 元素类型（枚举）
    element_type: i32,
    /// 稀有度（枚举）
    rare_type: i32,
    /// 基础属性组，索引到 P_DevelopAttributeTable
    develop_attribute_id: u32,
    /// 固有属性组，索引到FixedAttributeTable
    fixed_attribute_id: u32,
    /// 突破模板
    break_up_template_id: u32,
    /// 同卡命座道具
    awaken_item_id: u32,
    /// 初始液银生物
    init_silver_creature: ?u32 = null,
};

pub const P_LevelUpTemplate = struct {
    /// 唯一主键列
    id: u32,
    /// 突破等级
    break_level: u32,
    /// 等级
    level: u32,
    /// 最大生命值增幅比例（万分比）
    scale_maxhp: u32,
    /// 攻击力增幅比例（万分比）
    scale_atk: u32,
    /// 防御力增幅比例（万分比）
    scale_def: u32,
};

pub const P_DevelopAttribute = struct {
    /// 基础属性组ID
    id: u32,
    /// 生命值最终值
    maxhp: i32,
    /// 攻击力变化量
    atk: i32,
    /// 防御力变化量
    def: i32,
    /// 暴击率(万分比)
    atk_critical_chance: i32,
    /// 暴击伤害(万分比)
    atk_critical_damage: i32,
    /// 暴击伤害抵抗
    def_critical_damage_res: i32,
    /// 液滴获取效率
    blood_absorption_efficiency: i32,
    /// 治疗加成
    atk_heal_add_rate: i32,
    /// 受治疗加成
    def_heal_add_rate: i32,
    /// 无视防御力
    atk_ignore_target_defence: i32,
    /// 斩击精通
    atk_slash_spec: i32,
    /// 打击精通
    atk_strike_spec: i32,
    /// 穿刺精通
    atk_pierce_spec: i32,
    /// 火焰元素精通
    atk_fire_spec: i32,
    /// 冰元素精通
    atk_ice_spec: i32,
    /// 雷元素精通
    atk_thunder_spec: i32,
    /// 重力元素精通
    atk_gravity_spec: i32,
    /// 辐射元素精通
    atk_radiation_spec: i32,
    /// 血液反应精通
    atk_burst_spec: i32,
    /// 部位破坏效果
    atk_body_part_break_add_rate: i32,
    /// 击破增势
    atk_pursue_break_def: i32,
    /// 蓄势效能
    atk_pursue_catalyst: i32,
    /// 谐振爆发
    atk_abn_elem_master: i32,
    /// 火增伤
    atk_fire_damage_add_rate: i32,
    /// 冰增伤
    atk_ice_damage_add_rate: i32,
    /// 雷增伤
    atk_thunder_damage_add_rate: i32,
    /// 重力增伤
    atk_gravity_damage_add_rate: i32,
    /// 辐射增伤
    atk_radiation_damage_add_rate: i32,
    /// 奇技增伤
    atk_silver_damage_add_rate: i32,
    /// 锈蚀增伤
    atk_black_iron_damage_add_rate: i32,
    /// 充能效率
    liquid_absorb_rate: i32,
    /// 异常累积效率
    atk_abn_elem_accum_efficiency: i32,
    /// 眩晕增伤
    atk_non_break_damage: i32,
    /// 多重概率
    atk_abn_critical_chance: i32,
    /// 多重倍率
    atk_abn_critical_damage: i32,
    /// 飞马体力消耗倍率
    horse_stamina_cost_modifier: i32,
};

pub const C_BattleAttribute = struct {
    /// 属性ID
    id: u32,
    /// 属性名称
    attr_enum: i32,
    /// 是否角色专有
    allow_character_only: bool,
    /// 是否怪物专有
    allow_monster_only: bool,
    /// 是否万分制填写
    allow_permyriad: bool,
    /// 属性最大值
    maximum: i32,
    /// 属性最小值
    minimum: i32,
    /// 默认值
    default: i32,
};

pub const C_Guide = struct {
    /// ID
    id: u32,
    /// 子表ID
    sub_id: u32,
    /// 执行顺序（越小越靠前）
    order: u32,
};

pub const P_GuidePlatform = struct {
    /// 引导总ID
    id: u32,
    /// 引导激活序列
    guide_active_sequence: ?u32 = null,
    /// 键鼠初始引导步骤ID
    guide_id_pc: u32,
    /// 移动端初始引导步骤ID
    guide_id_mobile: ?u32 = null,
    /// 手柄初始引导步骤ID
    guide_id_gamepad: ?u32 = null,
    /// 被动触发
    is_passively: u32,
    /// 存本地
    is_save_local: u32,
    /// 关键引导(所有步骤不会超时)
    is_key_guide: ?u32 = null,
    /// 要求判断启用的系统(默认为空）
    enable_system_function_type: ?u32 = null,
    /// 依赖的系统(默认为空）
    dependent_group: []const []const u8,
    /// 引导delay时间
    delay_time: f32,
    /// 条件解锁类型
    guide_unlock_type: i32,
    /// 触发条件1
    event_type1: ?i32 = null,
    /// 触发条件参数1
    event_args1: ?[]const u8 = null,
    /// 触发条件2
    event_type2: ?i32 = null,
    /// 触发条件参数2
    event_args2: ?[]const u8 = null,
    /// 触发条件3
    event_type3: ?i32 = null,
    /// 触发条件参数3
    event_args3: ?[]const u8 = null,
};
