// ============================================================================
// config · 配置加载与校验单元测试
// ============================================================================

///|
/// 有效配置解析
test "valid_config: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-watch-1\",\"watch_dir\":\".\",\"recursive\":true,\"debounce_ms\":100,\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\",\"modify\"],\"patterns\":[\"**/*.txt\"],\"exclude\":[],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hello\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      assert_eq(cfg.schema_version, 1)
      assert_eq(cfg.watch_id, "test-watch-1")
      assert_eq(cfg.watch_dir, ".")
      assert_eq(cfg.rules.length(), 1)
      let rule = cfg.rules[0]
      assert_eq(rule.id, "rule-1")
      assert_eq(rule.events.length(), 2)
      assert_eq(rule.patterns.length(), 1)
      assert_eq(rule.actions.length(), 1)
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 缺少 watch_id 应报错
test "missing_watch_id: 报错" {
  let json = "{\"schema_version\":1,\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("watch_id 不能为空"))
  }
}

///|
/// 空 watch_id 应报错
test "empty_watch_id: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("watch_id 不能为空"))
  }
}

///|
/// 缺少 watch_dir 应报错
test "missing_watch_dir: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("watch_dir 不能为空"))
  }
}

///|
/// schema_version < 1 应报错
test "invalid_schema_version: 报错" {
  let json = "{\"schema_version\":0,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("schema_version 必须 >= 1"))
  }
}

///|
/// 缺少规则应报错
test "missing_rules: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\"}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("至少需要一条规则"))
  }
}

///|
/// 规则缺少 id 应报错
test "rule_missing_id: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("规则缺少 id"))
  }
}

///|
/// 规则缺少 events 应报错
test "rule_missing_events: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("缺少 events"))
  }
}

///|
/// 规则缺少 patterns 应报错
test "rule_missing_patterns: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("缺少 patterns"))
  }
}

///|
/// 规则缺少 actions 应报错
test "rule_missing_actions: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("缺少 actions"))
  }
}

///|
/// 规则 id 重复应报错
test "duplicate_rule_id: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-1\",\"events\":[\"modify\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("规则 id 重复"))
  }
}

///|
/// 累积式校验 - 多个错误一次性报告
test "cumulative_validation: 多错误报告" {
  let json = "{\"schema_version\":0,\"watch_id\":\"\",\"watch_dir\":\"\",\"rules\":[]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => {
      assert_true(err.contains("schema_version 必须 >= 1"))
      assert_true(err.contains("watch_id 不能为空"))
      assert_true(err.contains("watch_dir 不能为空"))
      assert_true(err.contains("至少需要一条规则"))
    }
  }
}

///|
/// debounce_ms 为负数应报错
test "negative_debounce_ms: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"debounce_ms\":-1,\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("debounce_ms 不能为负"))
  }
}

///|
/// 默认 schema_version 为 1
test "default_schema_version: 默认为1" {
  let json = "{\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.schema_version, 1)
    Err(_) => assert_true(false)
  }
}

///|
/// 默认 recursive 为 true
test "default_recursive: 默认为true" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.recursive, true)
    Err(_) => assert_true(false)
  }
}

///|
/// 默认 debounce_ms 为 0
test "default_debounce_ms: 默认为0" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.debounce_ms, 0)
    Err(_) => assert_true(false)
  }
}

///|
/// validate 函数公开入口
test "validate_function: 公开入口" {
  let cfg = @config.Config::default()
  match @config.validate(cfg) {
    Ok(_) => assert_true(false)
    Err(err) => {
      assert_true(err.contains("watch_id 不能为空"))
      assert_true(err.contains("watch_dir 不能为空"))
      assert_true(err.contains("至少需要一条规则"))
    }
  }
}

///|
/// 带条件的规则解析
test "rule_with_condition: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"condition\":{\"kind\":\"size_gt\",\"expr\":\"1024\"},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"large\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      let rule = cfg.rules[0]
      match rule.condition {
        Some(cond) => {
          assert_eq(cond.kind, "size_gt")
          assert_eq(cond.expr, "1024")
        }
        None => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 带 exclude 的规则解析
test "rule_with_exclude: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"exclude\":[\"**/node_modules/**\",\"**/.git/**\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules[0].exclude.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// stop_after 字段解析
test "rule_with_stop_after: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"stop_after\":true,\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules[0].stop_after, true)
    Err(_) => assert_true(false)
  }
}

///|
/// 多动作规则解析
test "rule_with_multiple_actions: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"first\"]},{\"kind\":\"command\",\"argv\":[\"echo\",\"second\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules[0].actions.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// JSON 解析失败
test "invalid_json: 报错" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\""
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(err) => assert_true(err.contains("JSON 解析失败"))
  }
}

///|
/// extensions 字段解析
test "extensions_field: 解析成功" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"extensions\":[\"ext1\",\"ext2\"],\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.extensions.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// watch_dir 存在性在加载时不做校验（运行时由 watch 后端检查）
test "watch_dir_existence_at_runtime: 加载时通过" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\"/nonexistent/path/that/does/not/exist\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
}

///|
/// 规则冲突检测：模式重叠
test "rule_conflict_detection: pattern_overlap" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      // 配置应成功加载，但应输出警告
      assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// 规则冲突检测：无冲突
test "rule_conflict_detection: no_conflict" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/*.md\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// 规则冲突检测：优先级提示
test "rule_conflict_detection: priority_warning" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"priority\":10,\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"priority\":5,\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// 日志配置：默认启用
test "logging_config: default_enabled" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      assert_eq(cfg.logging.enabled, true)
      assert_eq(cfg.logging.log_file, "mcp-watcher.log")
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 日志配置：禁用日志
test "logging_config: disabled" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"logging\":{\"enabled\":false},\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.logging.enabled, false)
    Err(_) => assert_true(false)
  }
}

///|
/// 日志配置：自定义日志目录和文件名
test "logging_config: custom_dir_and_file" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"logging\":{\"enabled\":true,\"log_dir\":\"/var/log\",\"log_file\":\"mywatcher.log\"},\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      assert_eq(cfg.logging.enabled, true)
      assert_eq(cfg.logging.log_dir, "/var/log")
      assert_eq(cfg.logging.log_file, "mywatcher.log")
    }
    Err(_) => assert_true(false)
  }
}

///|
/// 优先级级别：Critical
test "priority_level: critical" {
  assert_eq(@config.PriorityLevel::from_priority(100).to_string(), "Critical")
  assert_eq(@config.PriorityLevel::from_priority(150).to_string(), "Critical")
}

///|
/// 优先级级别：High
test "priority_level: high" {
  assert_eq(@config.PriorityLevel::from_priority(50).to_string(), "High")
  assert_eq(@config.PriorityLevel::from_priority(99).to_string(), "High")
}

///|
/// 优先级级别：Medium
test "priority_level: medium" {
  assert_eq(@config.PriorityLevel::from_priority(0).to_string(), "Medium")
  assert_eq(@config.PriorityLevel::from_priority(49).to_string(), "Medium")
}

///|
/// 优先级级别：Low
test "priority_level: low" {
  assert_eq(@config.PriorityLevel::from_priority(-1).to_string(), "Low")
  assert_eq(@config.PriorityLevel::from_priority(-50).to_string(), "Low")
}

///|
/// 优先级级别：Debug
test "priority_level: debug" {
  assert_eq(@config.PriorityLevel::from_priority(-100).to_string(), "Debug")
  assert_eq(@config.PriorityLevel::from_priority(-200).to_string(), "Debug")
}

///|
/// 规则冲突检测：事件类型冲突
test "rule_conflict_detection: event_type_conflict" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/*.log\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// 规则冲突检测：动作冲突
test "rule_conflict_detection: action_conflict" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

///|
/// 规则冲突检测：exclude 冲突
test "rule_conflict_detection: exclude_conflict" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*.txt\"],\"exclude\":[\"**/temp/**\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test1\"]}]},{\"id\":\"rule-2\",\"events\":[\"create\"],\"patterns\":[\"**/temp/**/*.txt\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"test2\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 2)
    Err(_) => assert_true(false)
  }
}

// ============================================================================
// config · 验收门（schema v1.1 · PLAN-gates.md §一）解析与 fail-closed
// ============================================================================

///|
/// acceptance：全字段解析
test "acceptance: full field parse" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"agent-cli\",\"--run\"],\"acceptance\":{\"expect_exit\":0,\"stdout_contains\":[\"DONE\"],\"stdout_not_contains\":[\"ERROR\",\"Traceback\"],\"stderr_not_contains\":[\"panic\"],\"artifact_glob\":\"output/*.json\"}}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].actions[0].acceptance {
        Some(acc) => {
          assert_eq(acc.expect_exit, 0)
          assert_eq(acc.stdout_contains, ["DONE"])
          assert_eq(acc.stdout_not_contains, ["ERROR", "Traceback"])
          assert_eq(acc.stderr_not_contains, ["panic"])
          match acc.artifact_glob {
            Some(g) => assert_eq(g, "output/*.json")
            None => assert_true(false)
          }
        }
        None => assert_true(false)
      }
    Err(e) => assert_true(false)
  }
}

///|
/// acceptance：空对象 = 全缺省（expect_exit=0、数组空、无 artifact_glob）
test "acceptance: empty object defaults" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"],\"acceptance\":{}}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].actions[0].acceptance {
        Some(acc) => {
          assert_eq(acc.expect_exit, 0)
          assert_eq(acc.stdout_contains.length(), 0)
          assert_eq(acc.stdout_not_contains.length(), 0)
          assert_eq(acc.stderr_not_contains.length(), 0)
          match acc.artifact_glob {
            Some(_) => assert_true(false)
            None => ()
          }
        }
        None => assert_true(false)
      }
    Err(_) => assert_true(false)
  }
}

///|
/// 验收用例5：未知 acceptance 字段 → schema 错（fail-closed）
test "acceptance: unknown field fails closed" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"],\"acceptance\":{\"bogus_field\":1}}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("acceptance"))
  }
}

///|
/// acceptance：字段类型错 → schema 错（fail-closed）
test "acceptance: wrong type fails closed" {
  let json1 = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"],\"acceptance\":{\"expect_exit\":\"zero\"}}]}]}"
  match @config.Config::from_json(json1) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("acceptance"))
  }
  let json2 = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"],\"acceptance\":{\"stdout_contains\":\"DONE\"}}]}]}"
  match @config.Config::from_json(json2) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("acceptance"))
  }
}

///|
/// 非 command 动作携带 acceptance → 报错（该字段只对 command 有语义）
test "acceptance: non-command action rejected" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"webhook\",\"target\":\"http://x\",\"acceptance\":{\"stdout_contains\":[\"x\"]}}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("acceptance"))
  }
}

///|
/// 验收用例4：无 acceptance 字段 → 行为与 v1.0 完全一致（向后兼容锁）
test "acceptance: absent field backward compatible" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].actions[0].acceptance {
        Some(_) => assert_true(false)
        None => ()
      }
    Err(_) => assert_true(false)
  }
}

// ============================================================================
// config · 守卫门（schema v1.1 · PLAN-gates.md §二）解析与 fail-closed
// ============================================================================

///|
/// guard：全字段解析
test "guard: full field parse" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"test\",\"-z\",\"{{workdir}}/.agent.lock\"],\"on_fail\":\"skip\"},\"actions\":[{\"kind\":\"command\",\"argv\":[\"agent-cli\",\"--run\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].guard_spec {
        Some(g) => {
          assert_eq(g.argv, ["test", "-z", "{{workdir}}/.agent.lock"])
          assert_eq(g.on_fail, "skip")
        }
        None => assert_true(false)
      }
    Err(e) => assert_true(false)
  }
}

///|
/// guard：on_fail 缺省 → "skip"
test "guard: on_fail defaults to skip" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"test\",\"-z\",\"x\"]},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].guard_spec {
        Some(g) => assert_eq(g.on_fail, "skip")
        None => assert_true(false)
      }
    Err(_) => assert_true(false)
  }
}

///|
/// guard：on_fail=stop 解析
test "guard: on_fail stop parses" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"test\",\"-z\",\"x\"],\"on_fail\":\"stop\"},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].guard_spec {
        Some(g) => assert_eq(g.on_fail, "stop")
        None => assert_true(false)
      }
    Err(_) => assert_true(false)
  }
}

///|
/// guard：on_fail 非法值 → schema 错（fail-closed）
test "guard: invalid on_fail fails closed" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"test\"],\"on_fail\":\"crash\"},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("guard"))
  }
}

///|
/// guard：未知字段 → schema 错（fail-closed）
test "guard: unknown field fails closed" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"test\"],\"bogus\":1},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("guard"))
  }
}

///|
/// guard：空 argv → schema 错（fail-closed）
test "guard: empty argv fails closed" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[]},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("guard"))
  }
}

///|
/// 守卫验收用例4：无 guard 字段 → v1.0 行为不变（向后兼容锁）
test "guard: absent field backward compatible" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) =>
      match cfg.rules[0].guard_spec {
        Some(_) => assert_true(false)
        None => ()
      }
    Err(_) => assert_true(false)
  }
}

///|
/// 守卫验收用例3（加载期侧）：guard 程序不在白名单 → 加载成功（警告级，不阻断）
test "guard: program not in whitelist loads with warning" {
  let json = "{\"schema_version\":1,\"watch_id\":\"test-1\",\"watch_dir\":\".\",\"allowed_programs\":[],\"rules\":[{\"id\":\"rule-1\",\"events\":[\"create\"],\"patterns\":[\"**/*\"],\"guard\":{\"argv\":[\"agent-cli\",\"--probe\"],\"on_fail\":\"skip\"},\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => assert_eq(cfg.rules.length(), 1)
    Err(_) => assert_true(false)
  }
}
