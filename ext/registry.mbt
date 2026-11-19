// ============================================================================
// ext · 扩展位注册表（EP-01~EP-12）
//
// 可插拔登记：动作 / 条件 / 后端。v1.0 仅建立注册表骨架；extensions 配置键
// 当前为占位（设计见 design-spec 扩展位章节），动态加载能力待 MoonBit 成熟。
// ============================================================================

///|
/// 扩展位注册表
pub struct ExtensionRegistry {
  /// 已注册动作：动作名 → 实现 id
  actions : Map[String, String]
  /// 已注册条件：条件名 → 实现 id
  conditions : Map[String, String]
  /// 已注册后端：后端名 → 实现 id
  backends : Map[String, String]
}

///|
/// 新建空注册表
pub fn ExtensionRegistry::new() -> ExtensionRegistry {
  {
    actions: Map([], capacity=0),
    conditions: Map([], capacity=0),
    backends: Map([], capacity=0),
  }
}

///|
/// 注册动作实现
pub fn ExtensionRegistry::register_action(
  self : ExtensionRegistry,
  name : String,
  impl_id : String,
) -> ExtensionRegistry {
  let actions = self.actions.copy()
  actions[name] = impl_id
  { ..self, actions, }
}

///|
/// 注册条件实现
pub fn ExtensionRegistry::register_condition(
  self : ExtensionRegistry,
  name : String,
  impl_id : String,
) -> ExtensionRegistry {
  let conditions = self.conditions.copy()
  conditions[name] = impl_id
  { ..self, conditions, }
}

///|
/// 注册后端实现
pub fn ExtensionRegistry::register_backend(
  self : ExtensionRegistry,
  name : String,
  impl_id : String,
) -> ExtensionRegistry {
  let backends = self.backends.copy()
  backends[name] = impl_id
  { ..self, backends, }
}

///|
/// 查询动作实现 id
pub fn ExtensionRegistry::get_action(
  self : ExtensionRegistry,
  name : String,
) -> String? {
  self.actions.get(name)
}
