// fs_list_stub.c —— action 包 native 目录枚举 FFI 实现（验收门 artifact_glob）
// 平台：Windows (MSVC cl.exe) / POSIX (gcc/clang)
// 编译：由 MoonBit 工具链通过 native-stub 自动编译
//
// 返回 JSON 数组：["file1.txt", "subdir/", ...]——目录带 "/" 后缀；
// 空字节 = 枚举失败（目录不存在等）。
//
// 注意：moonbit_bytes_t 是 uint8_t*，直接指向数据；
// 长度通过 Moonbit_array_length 宏从对象头获取。

#include <moonbit.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 平台检测
// ---------------------------------------------------------------------------
#ifdef _WIN32
  #include <windows.h>
  #define PLATFORM_WINDOWS 1
  #define PLATFORM_POSIX   0
#else
  #include <sys/stat.h>
  #include <dirent.h>
  #include <unistd.h>
  #define PLATFORM_WINDOWS 0
  #define PLATFORM_POSIX   1
#endif

#define LIST_JSON_CAP 131072

// ---------------------------------------------------------------------------
// 追加一个 JSON 字符串条目（最小转义：处理 " 与 \）
// ---------------------------------------------------------------------------
static void append_entry(
  char *json,
  int *json_len,
  int *first,
  const char *name,
  int name_len,
  int is_dir
) {
  if (*json_len > LIST_JSON_CAP - 256) return;
  if (!*first) {
    json[(*json_len)++] = ',';
  }
  *first = 0;
  json[(*json_len)++] = '"';
  int i;
  for (i = 0; i < name_len; i++) {
    char c = name[i];
    if (c == '"' || c == '\\') {
      json[(*json_len)++] = '\\';
    }
    json[(*json_len)++] = c;
  }
  if (is_dir) {
    json[(*json_len)++] = '/';
  }
  json[(*json_len)++] = '"';
}

// ---------------------------------------------------------------------------
// moonbit_watcher_list_dir: 列目录下全部条目（排除 . 与 ..），目录带 "/" 后缀
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_watcher_list_dir(moonbit_bytes_t dir) {
  const char *dir_str = (const char *)dir;
  int32_t dir_len = Moonbit_array_length(dir);
  char dir_path[1024];
  static char json[LIST_JSON_CAP];
  int json_len = 1;
  int first = 1;

  if (!dir_str || dir_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  if (dir_len >= 1000) {
    return moonbit_make_bytes(0, 0);
  }
  memcpy(dir_path, dir_str, dir_len);
  dir_path[dir_len] = '\0';

  json[0] = '[';

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, NULL, 0);
  if (wide_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wide_dir = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_dir) {
    return moonbit_make_bytes(0, 0);
  }
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
  int utf8_len;
  int is_dir;

  do {
    const wchar_t *fname = find_data.cFileName;
    if (wcscmp(fname, L".") == 0 || wcscmp(fname, L"..") == 0) continue;
    utf8_len = WideCharToMultiByte(
      CP_UTF8, 0, fname, -1, utf8_name, 511, NULL, NULL
    );
    if (utf8_len <= 1) continue;
    utf8_name[utf8_len - 1] = '\0';
    is_dir = (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    append_entry(json, &json_len, &first, utf8_name, utf8_len - 1, is_dir);
  } while (FindNextFileW(hFind, &find_data));

  FindClose(hFind);
  free(wide_dir);
#else
  DIR *dirp = opendir(dir_path);
  if (!dirp) {
    return moonbit_make_bytes(0, 0);
  }

  struct dirent *entry;
  struct stat st;
  int fname_len;
  int is_dir;

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
        if (stat(full, &st) == 0) {
          is_dir = S_ISDIR(st.st_mode);
        }
      }
    }
    append_entry(json, &json_len, &first, fname, fname_len, is_dir);
  }

  closedir(dirp);
#endif

  json[json_len++] = ']';
  json[json_len] = '\0';

  moonbit_bytes_t bytes = moonbit_make_bytes(json_len, 0);
  if (bytes) {
    memcpy(bytes, json, json_len);
  }
  return bytes;
}
