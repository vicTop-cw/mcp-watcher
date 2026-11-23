/// fs_nodes 行模型与 JSON 输出（vector-index-design §3.2 / §6.2）
pub struct Node {
  path : String
  rel_path : String
  parent : String?
  depth : Int
  node_type : String // "file" | "dir"
  size : Int64
  mtime : Int64
  ctime : Int64
  ext : String
}

/// JSON 对象（jsonl 每行一个；text 表按此字段子集展示）
pub fn node_to_json(n : Node) -> String {
  let parent = match n.parent {
    Some(p) => @json.Json::string(p)
    None => @json.Json::null()
  }
  let obj = @json.Json::object({
    "path": @json.Json::string(n.path),
    "rel_path": @json.Json::string(n.rel_path),
    "parent": parent,
    "depth": @json.Json::number(n.depth.to_double()),
    "type": @json.Json::string(n.node_type),
    "size": @json.Json::number(n.size.to_double()),
    "mtime": @json.Json::number(n.mtime.to_double()),
    "ctime": @json.Json::number(n.ctime.to_double()),
    "ext": @json.Json::string(n.ext),
  })
  obj.to_string()
}

/// 取路径末段（文件名/目录名）
pub fn path_leaf(p : String) -> String {
  let s = normalize_slash(p)
  let idx = s.rindex('/')
  match idx {
    Some(i) => s.substring(start=i + 1, end=s.length())
    None => s
  }
}

/// 规范化：反斜杠 -> 正斜杠、去除末尾斜杠（根 "/" 除外）
pub fn normalize_slash(p : String) -> String {
  var out = ""
  for c in p {
    if c == '\\' {
      out = out + "/"
    } else {
      out = out + c.to_string()
    }
  }
  // 去除末尾重复斜杠
  var end = out.length()
  while end > 1 && out.substring(start=end - 1, end=end) == "/" {
    end = end - 1
  }
  out.substring(start=0, end=end)
}

/// 计算深度（按 / 段数；根（不含前导盘符/根斜杠）为 0）
pub fn depth_of(p : String) -> Int {
  let s = normalize_slash(p)
  var depth = 0
  var i = 0
  while i < s.length() {
    if s[i] == '/' {
      depth = depth + 1
    }
    i = i + 1
  }
  depth
}
