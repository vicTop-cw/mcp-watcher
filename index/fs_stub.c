// fs_stub.c —— index 包 native 目录枚举 / stat FFI 实现
// 平台：Windows (MSVC) / POSIX (gcc/clang)
// 由 MoonBit 工具链 native-stub 自动编译
// 返回 JSON：
//   moonbit_index_list_dir(dir)  -> ["a.txt","sub/",...]（目录带 "/" 后缀；空 = 失败）
//   moonbit_index_stat(path)     -> {"ok":1,"is_dir":0,"size":123,"mtime":456,"ctime":789} 或 {"ok":0}
//   moonbit_index_mkdir(path)    -> {"ok":1} 或 {"ok":0}

#include <moonbit.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifdef _WIN32
  #include <windows.h>
  #define PLATFORM_WINDOWS 1
  #define PLATFORM_POSIX   0
#else
  #include <sys/stat.h>
  #include <dirent.h>
  #include <unistd.h>
  #include <sys/time.h>
  #define PLATFORM_WINDOWS 0
  #define PLATFORM_POSIX   1
#endif

#define JSON_CAP 262144

static moonbit_bytes_t make_json(const char *s, int len) {
  moonbit_bytes_t bytes = moonbit_make_bytes(len, 0);
  if (bytes) {
    memcpy(bytes, s, len);
  }
  return bytes;
}

// 追加 JSON 字符串条目（最小转义：处理 " 与 \）
static void append_entry(
  char *json, int *json_len, int *first,
  const char *name, int name_len, int is_dir
) {
  if (*json_len > JSON_CAP - 256) return;
  if (!*first) json[(*json_len)++] = ',';
  *first = 0;
  json[(*json_len)++] = '"';
  int i;
  for (i = 0; i < name_len; i++) {
    char c = name[i];
    if (c == '"' || c == '\\') json[(*json_len)++] = '\\';
    json[(*json_len)++] = c;
  }
  if (is_dir) json[(*json_len)++] = '/';
  json[(*json_len)++] = '"';
}

// moonbit_index_list_dir: 列目录下全部条目（排除 . 与 ..），目录带 "/" 后缀
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_index_list_dir(moonbit_bytes_t dir) {
  const char *dir_str = (const char *)dir;
  int32_t dir_len = Moonbit_array_length(dir);
  char dir_path[1024];
  static char json[JSON_CAP];
  int json_len = 1;
  int first = 1;

  if (!dir_str || dir_len <= 0 || dir_len >= 1000) {
    return moonbit_make_bytes(0, 0);
  }
  memcpy(dir_path, dir_str, dir_len);
  dir_path[dir_len] = '\0';
  json[0] = '[';

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, NULL, 0);
  if (wide_len <= 0) return moonbit_make_bytes(0, 0);
  wchar_t *wide_dir = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_dir) return moonbit_make_bytes(0, 0);
  MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, wide_dir, wide_len);

  wchar_t search_path[1024];
  swprintf(search_path, 1024, L"%s\\*", wide_dir);
  WIN32_FIND_DATAW find_data;
  HANDLE hFind = FindFirstFileW(search_path, &find_data);
  if (hFind == INVALID_HANDLE_VALUE) {
    free(wide_dir);
    return moonbit_make_bytes(0, 0);
  }
  char utf8_name[512];
  int utf8_len, is_dir;
  do {
    const wchar_t *fname = find_data.cFileName;
    if (wcscmp(fname, L".") == 0 || wcscmp(fname, L"..") == 0) continue;
    utf8_len = WideCharToMultiByte(CP_UTF8, 0, fname, -1, utf8_name, 511, NULL, NULL);
    if (utf8_len <= 1) continue;
    utf8_name[utf8_len - 1] = '\0';
    is_dir = (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    append_entry(json, &json_len, &first, utf8_name, utf8_len - 1, is_dir);
  } while (FindNextFileW(hFind, &find_data));
  FindClose(hFind);
  free(wide_dir);
#else
  DIR *dirp = opendir(dir_path);
  if (!dirp) return moonbit_make_bytes(0, 0);
  struct dirent *entry;
  struct stat st;
  int fname_len, is_dir;
  while ((entry = readdir(dirp)) != NULL) {
    const char *fname = entry->d_name;
    fname_len = (int)strlen(fname);
    if (fname_len == 0) continue;
    if (fname_len == 1 && fname[0] == '.') continue;
    if (fname_len == 2 && fname[0] == '.' && fname[1] == '.') continue;
    is_dir = 0;
    {
      char full[1200];
      int plen = (int)strlen(dir_path);
      if (plen + 1 + fname_len < 1200) {
        memcpy(full, dir_path, plen);
        if (plen > 0 && dir_path[plen - 1] != '/' && dir_path[plen - 1] != '\\') {
          full[plen++] = '/';
        }
        memcpy(full + plen, fname, fname_len);
        full[plen + fname_len] = '\0';
        if (stat(full, &st) == 0) is_dir = S_ISDIR(st.st_mode);
      }
    }
    append_entry(json, &json_len, &first, fname, fname_len, is_dir);
  }
  closedir(dirp);
#endif

  json[json_len++] = ']';
  json[json_len] = '\0';
  return make_json(json, json_len);
}

// moonbit_index_stat: 返回 JSON 对象（Unix 秒时间戳）
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_index_stat(moonbit_bytes_t path) {
  const char *p = (const char *)path;
  int32_t plen = Moonbit_array_length(path);
  char pp[1024];
  static char json[256];
  if (!p || plen <= 0 || plen >= 1000) {
    return make_json("{\"ok\":0}", 7);
  }
  memcpy(pp, p, plen);
  pp[plen] = '\0';

#if PLATFORM_WINDOWS
  WIN32_FILE_ATTRIBUTE_DATA info;
  if (!GetFileAttributesExA(pp, GetFileExInfoStandard, &info)) {
    return make_json("{\"ok\":0}", 7);
  }
  int is_dir = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  // FILETIME: 100ns since 1601-01-01 -> unix 秒
  ULONGLONG mtime = ((ULONGLONG)info.ftLastWriteTime.dwHighDateTime << 32)
                  | info.ftLastWriteTime.dwLowDateTime;
  ULONGLONG ctime = ((ULONGLONG)info.ftCreationTime.dwHighDateTime << 32)
                  | info.ftCreationTime.dwLowDateTime;
  unsigned long long size = ((unsigned long long)info.nFileSizeHigh << 32)
                          | info.nFileSizeLow;
  long long mt = (long long)(mtime / 10000000ULL - 11644473600ULL);
  long long ct = (long long)(ctime / 10000000ULL - 11644473600ULL);
  snprintf(json, sizeof(json),
    "{\"ok\":1,\"is_dir\":%d,\"size\":%llu,\"mtime\":%lld,\"ctime\":%lld}",
    is_dir ? 1 : 0, size, mt, ct);
#else
  struct stat st;
  if (stat(pp, &st) != 0) return make_json("{\"ok\":0}", 7);
  snprintf(json, sizeof(json),
    "{\"ok\":1,\"is_dir\":%d,\"size\":%lld,\"mtime\":%lld,\"ctime\":%lld}",
    S_ISDIR(st.st_mode) ? 1 : 0,
    (long long)st.st_size, (long long)st.st_mtime, (long long)st.st_ctime);
#endif
  return make_json(json, (int)strlen(json));
}

// moonbit_index_mkdir: 递归创建目录（含父级）
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_index_mkdir(moonbit_bytes_t path) {
  const char *p = (const char *)path;
  int32_t plen = Moonbit_array_length(path);
  char pp[1024];
  if (!p || plen <= 0 || plen >= 1000) return make_json("{\"ok\":0}", 7);
  memcpy(pp, p, plen);
  pp[plen] = '\0';

#if PLATFORM_WINDOWS
  // 逐级创建
  int n = plen;
  for (int i = 0; i < n; i++) {
    if (pp[i] == '/' || pp[i] == '\\') {
      char save = pp[i];
      pp[i] = '\0';
      if (pp[0] != '\0') CreateDirectoryA(pp, NULL);
      pp[i] = save;
    }
  }
  if (CreateDirectoryA(pp, NULL)) {
    return make_json("{\"ok\":1}", 7);
  } else {
    DWORD err = GetLastError();
    if (err == ERROR_ALREADY_EXISTS) return make_json("{\"ok\":1}", 7);
    return make_json("{\"ok\":0}", 7);
  }
#else
  int n = plen;
  for (int i = 1; i < n; i++) {
    if (pp[i] == '/') {
      char save = pp[i];
      pp[i] = '\0';
      mkdir(pp, 0755);
      pp[i] = save;
    }
  }
  if (mkdir(pp, 0755) == 0) return make_json("{\"ok\":1}", 7);
  if (errno == EEXIST) return make_json("{\"ok\":1}", 7);
  return make_json("{\"ok\":0}", 7);
#endif
}
