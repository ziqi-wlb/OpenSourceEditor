#define UNICODE
#define _UNICODE
#include <windows.h>
#include <algorithm>
#include <commctrl.h>
#include <commdlg.h>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <richedit.h>
#include <shlobj.h>
#include <stdexcept>
#include <string>
#include <vector>
#include <windowsx.h>

namespace fs = std::filesystem;
struct Document {
  std::wstring path, text;
  std::string disk;
  bool dirty = false;
  int encoding = 0, width = 4;
  bool spaces = false, crlf = true;
};
struct Node {
  fs::path path;
  bool directory;
  bool loaded = false;
};
static HWND frame, tabs, edit, tree, status, findBox;
static HFONT font;
static bool internalChange = false, dark = true;
static size_t active = 0;
static std::vector<Document> docs;
static std::vector<std::unique_ptr<Node>> nodes;
static fs::path project;
static HBRUSH darkBrush;
enum {
  New = 101,
  Open,
  Save,
  SaveAs,
  SaveAll,
  Close,
  OpenFolder,
  Exit,
  Undo,
  Redo,
  Cut,
  Copy,
  Paste,
  SelectAll,
  Find,
  FindNext,
  Dark,
  Light,
  CopyPath,
  CopyRelative,
  CopyName,
  Reveal,
  CloseOthers,
  CloseRight,
  Utf8,
  Utf8Bom,
  Utf16,
  Tabs,
  Spaces,
  Width2,
  Width4,
  Width8,
  Lf,
  CrLf
};
static std::wstring text(HWND control) {
  int n = GetWindowTextLengthW(control);
  std::wstring s(n + 1, L'\0');
  GetWindowTextW(control, s.data(), n + 1);
  s.resize(n);
  return s;
}
static std::string read(const fs::path &p) {
  std::ifstream f(p, std::ios::binary);
  if (!f)
    throw std::runtime_error("Unable to read file");
  return std::string(std::istreambuf_iterator<char>(f), {});
}
static std::wstring decode(const std::string &bytes, int &encoding) {
  encoding = 0;
  size_t start = 0;
  if (bytes.size() >= 2 && (unsigned char)bytes[0] == 255 &&
      (unsigned char)bytes[1] == 254) {
    encoding = 2;
    if ((bytes.size() - 2) % 2)
      throw std::runtime_error("Invalid UTF-16 file");
    std::wstring s;
    for (size_t i = 2; i < bytes.size(); i += 2)
      s.push_back((unsigned char)bytes[i] | ((unsigned char)bytes[i + 1] << 8));
    return s;
  }
  if (bytes.substr(0, 3) == "\xef\xbb\xbf") {
    encoding = 1;
    start = 3;
  }
  if (bytes.size() == start)
    return L"";
  int n =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data() + start,
                          (int)(bytes.size() - start), nullptr, 0);
  if (!n)
    throw std::runtime_error("File is not valid UTF-8 or UTF-16 LE with BOM");
  std::wstring s(n, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data() + start,
                      (int)(bytes.size() - start), s.data(), n);
  return s;
}
static std::string encode(const Document &d) {
  std::wstring s;
  for (size_t i = 0; i < d.text.size(); i++) {
    wchar_t c = d.text[i];
    if (c == L'\r') {
      if (i + 1 < d.text.size() && d.text[i + 1] == L'\n')
        i++;
      c = L'\n';
    }
    if (c == L'\n' && d.crlf)
      s += L'\r';
    s += c;
  }
  if (d.encoding == 2) {
    std::string out = "\xff\xfe";
    for (wchar_t c : s) {
      out += (char)(c & 255);
      out += (char)(c >> 8);
    }
    return out;
  }
  if (s.empty())
    return d.encoding == 1 ? "\xef\xbb\xbf" : "";
  int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(),
                              (int)s.size(), nullptr, 0, nullptr, nullptr);
  if (!n)
    throw std::runtime_error("Invalid Unicode text");
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(),
                      out.data(), n, nullptr, nullptr);
  return (d.encoding == 1 ? "\xef\xbb\xbf" : "") + out;
}
static void error(const char *message) {
  std::wstring s(message, message + strlen(message));
  MessageBoxW(frame, s.c_str(), L"Source Editor", MB_OK | MB_ICONERROR);
}
static void clipboard(const std::wstring &s) {
  if (!OpenClipboard(frame))
    return;
  HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
  if (data) {
    void *p = GlobalLock(data);
    if (p) {
      memcpy(p, s.c_str(), (s.size() + 1) * sizeof(wchar_t));
      GlobalUnlock(data);
      EmptyClipboard();
      if (!SetClipboardData(CF_UNICODETEXT, data))
        GlobalFree(data);
    } else
      GlobalFree(data);
  }
  CloseClipboard();
}
static void checkpoint() {
  if (!docs.empty() && !internalChange)
    docs[active].text = text(edit);
}
static void update() {
  if (docs.empty())
    return;
  auto &d = docs[active];
  std::wstring name =
      d.path.empty() ? L"Untitled" : fs::path(d.path).filename().wstring();
  SetWindowTextW(
      frame, (name + (d.dirty ? L" *" : L"") + L" — Source Editor").c_str());
  std::wstring label = (d.encoding == 2   ? L"UTF-16 LE"
                        : d.encoding == 1 ? L"UTF-8 BOM"
                                          : L"UTF-8");
  label += d.crlf ? L"  CRLF" : L"  LF";
  label += d.spaces ? L"  Spaces: " : L"  Tab Size: ";
  label += std::to_wstring(d.width);
  SendMessageW(status, SB_SETTEXTW, 0, (LPARAM)label.c_str());
}
static void retab() {
  TabCtrl_DeleteAllItems(tabs);
  for (auto &d : docs) {
    std::wstring s =
        (d.dirty ? L"* " : L"") +
        (d.path.empty() ? L"Untitled" : fs::path(d.path).filename().wstring());
    TCITEMW item{};
    item.mask = TCIF_TEXT;
    item.pszText = s.data();
    TabCtrl_InsertItem(tabs, (int)(&d - docs.data()), &item);
  }
  TabCtrl_SetCurSel(tabs, (int)active);
  update();
}
static void theme() {
  SendMessageW(edit, EM_SETBKGNDCOLOR, 0,
               dark ? RGB(19, 22, 28) : RGB(250, 250, 250));
  CHARFORMAT2W f{};
  f.cbSize = sizeof(f);
  f.dwMask = CFM_COLOR;
  f.crTextColor = dark ? RGB(220, 230, 242) : RGB(28, 28, 28);
  SendMessageW(edit, EM_SETCHARFORMAT, SCF_ALL, (LPARAM)&f);
  TreeView_SetBkColor(tree, dark ? RGB(26, 30, 38) : RGB(240, 240, 240));
  TreeView_SetTextColor(tree, dark ? RGB(220, 230, 242) : RGB(28, 28, 28));
  InvalidateRect(frame, nullptr, TRUE);
}
static void select(size_t index, bool capture = true) {
  if (index >= docs.size())
    return;
  if (capture)
    checkpoint();
  active = index;
  internalChange = true;
  SetWindowTextW(edit, docs[active].text.c_str());
  SendMessageW(edit, EM_EMPTYUNDOBUFFER, 0, 0);
  PARAFORMAT2 p{};
  p.cbSize = sizeof(p);
  p.dwMask = PFM_TABSTOPS;
  p.cTabCount = MAX_TAB_STOPS;
  for (int i = 0; i < MAX_TAB_STOPS; i++)
    p.rgxTabs[i] = (i + 1) * docs[active].width * 120;
  SendMessageW(edit, EM_SETPARAFORMAT, 0, (LPARAM)&p);
  theme();
  internalChange = false;
  retab();
  SetFocus(edit);
}
static std::wstring chooseFile(bool saving) {
  wchar_t path[32768]{};
  if (saving && !docs[active].path.empty())
    wcsncpy(path, docs[active].path.c_str(), 32767);
  OPENFILENAMEW o{};
  o.lStructSize = sizeof(o);
  o.hwndOwner = frame;
  o.lpstrFile = path;
  o.nMaxFile = 32768;
  o.lpstrFilter = L"Text and source files\0*.*\0";
  o.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR |
            (saving ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
  if (saving ? GetSaveFileNameW(&o) : GetOpenFileNameW(&o))
    return path;
  return L"";
}
static bool save(size_t index, bool saveAs = false) {
  checkpoint();
  auto &d = docs[index];
  std::wstring path = d.path;
  if (path.empty() || saveAs) {
    size_t old = active;
    active = index;
    path = chooseFile(true);
    active = old;
    if (path.empty())
      return false;
  }
  try {
    if (path == d.path && !d.path.empty() && read(path) != d.disk) {
      error("File changed on disk. Save As to keep both versions.");
      return false;
    }
    std::string bytes = encode(d);
    fs::path tmp = fs::path(path).wstring() + L".source-editor-" +
                   std::to_wstring(GetCurrentProcessId()) + L".tmp";
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE)
      throw std::runtime_error("Unable to create save transaction");
    DWORD written = 0;
    bool ok =
        WriteFile(h, bytes.data(), (DWORD)bytes.size(), &written, nullptr) &&
        written == bytes.size() && FlushFileBuffers(h);
    CloseHandle(h);
    if (!ok ||
        !MoveFileExW(tmp.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      DeleteFileW(tmp.c_str());
      throw std::runtime_error("Unable to save file");
    }
    d.path = path;
    d.disk = bytes;
    d.dirty = false;
    retab();
    return true;
  } catch (const std::exception &e) {
    error(e.what());
    return false;
  }
}
static bool close(size_t i) {
  if (i >= docs.size())
    return true;
  checkpoint();
  if (docs[i].dirty) {
    std::wstring caption =
        L"Save changes to " +
        (docs[i].path.empty() ? L"Untitled"
                              : fs::path(docs[i].path).filename().wstring()) +
        L"?";
    int choice = MessageBoxW(frame, caption.c_str(), L"Source Editor",
                             MB_YESNOCANCEL | MB_ICONQUESTION);
    if (choice == IDCANCEL || choice == IDYES && !save(i))
      return false;
  }
  docs.erase(docs.begin() + i);
  if (i < active)
    active--;
  if (docs.empty())
    docs.push_back({});
  active = std::min(active, docs.size() - 1);
  select(active, false);
  return true;
}
static void open(const fs::path &path) {
  try {
    fs::path full = fs::weakly_canonical(path);
    for (size_t i = 0; i < docs.size(); i++)
      if (docs[i].path == full.wstring()) {
        select(i);
        return;
      }
    Document d;
    d.path = full.wstring();
    d.disk = read(full);
    d.text = decode(d.disk, d.encoding);
    d.crlf = d.text.find(L"\r\n") != std::wstring::npos;
    checkpoint();
    docs.push_back(d);
    select(docs.size() - 1);
  } catch (const std::exception &e) {
    error(e.what());
  }
}
static Node *node(HTREEITEM item) {
  TVITEMW t{};
  t.mask = TVIF_PARAM;
  t.hItem = item;
  TreeView_GetItem(tree, &t);
  return (Node *)t.lParam;
}
static HTREEITEM insert(const fs::path &path, bool directory,
                        HTREEITEM parent) {
  auto n = std::make_unique<Node>();
  n->path = path;
  n->directory = directory;
  TVINSERTSTRUCTW t{};
  t.hParent = parent;
  t.hInsertAfter = TVI_LAST;
  t.item.mask = TVIF_TEXT | TVIF_PARAM | TVIF_CHILDREN;
  std::wstring label = path.filename().wstring();
  if (label.empty())
    label = path.wstring();
  t.item.pszText = label.data();
  t.item.lParam = (LPARAM)n.get();
  t.item.cChildren = directory ? 1 : 0;
  nodes.push_back(std::move(n));
  return TreeView_InsertItem(tree, &t);
}
static void expand(HTREEITEM item) {
  Node *n = node(item);
  if (!n || !n->directory || n->loaded)
    return;
  try {
    std::vector<fs::directory_entry> entries;
    for (auto &e : fs::directory_iterator(n->path))
      entries.push_back(e);
    std::sort(entries.begin(), entries.end(), [](auto &a, auto &b) {
      if (a.is_directory() != b.is_directory())
        return a.is_directory();
      return a.path().filename() < b.path().filename();
    });
    for (auto &e : entries)
      insert(e.path(), e.is_directory(), item);
    n->loaded = true;
  } catch (const std::exception &e) {
    error(e.what());
  }
}
static void folder() {
  IFileOpenDialog *dialog = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                 CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&dialog)))) {
    DWORD flags;
    dialog->GetOptions(&flags);
    dialog->SetOptions(flags | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    if (SUCCEEDED(dialog->Show(frame))) {
      IShellItem *item = nullptr;
      if (SUCCEEDED(dialog->GetResult(&item))) {
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
          project = path;
          CoTaskMemFree(path);
          TreeView_DeleteAllItems(tree);
          nodes.clear();
          auto root = insert(project, true, TVI_ROOT);
          TreeView_Expand(tree, root, TVE_EXPAND);
        }
        item->Release();
      }
    }
    dialog->Release();
  }
}
static void findNext() {
  std::wstring query = text(findBox);
  if (query.empty())
    return;
  CHARRANGE selection{};
  SendMessageW(edit, EM_EXGETSEL, 0, (LPARAM)&selection);
  FINDTEXTEXW f{};
  f.chrg.cpMin = selection.cpMax;
  f.chrg.cpMax = -1;
  f.lpstrText = query.data();
  LRESULT found = SendMessageW(edit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&f);
  if (found < 0) {
    f.chrg.cpMin = 0;
    found = SendMessageW(edit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&f);
  }
  if (found >= 0) {
    SendMessageW(edit, EM_EXSETSEL, 0, (LPARAM)&f.chrgText);
    SendMessageW(edit, EM_SCROLLCARET, 0, 0);
    SetFocus(edit);
  }
}
static void command(int id, size_t target) {
  if (target >= docs.size())
    return;
  switch (id) {
  case New:
    checkpoint();
    docs.push_back({});
    select(docs.size() - 1);
    break;
  case Open: {
    auto p = chooseFile(false);
    if (!p.empty())
      open(p);
    break;
  }
  case Save:
    save(target);
    break;
  case SaveAs:
    save(target, true);
    break;
  case SaveAll:
    for (size_t i = 0; i < docs.size(); i++)
      if (docs[i].dirty && !save(i))
        break;
    break;
  case Close:
    close(target);
    break;
  case CloseOthers:
  case CloseRight:
    for (size_t i = docs.size(); i-- > 0;)
      if (i != target && (id == CloseOthers || i > target)) {
        if (!close(i))
          break;
        if (i < target)
          target--;
      }
    select(std::min(target, docs.size() - 1));
    break;
  case OpenFolder:
    folder();
    break;
  case Exit:
    SendMessageW(frame, WM_CLOSE, 0, 0);
    break;
  case Undo:
    SendMessageW(edit, EM_UNDO, 0, 0);
    break;
  case Redo:
    SendMessageW(edit, EM_REDO, 0, 0);
    break;
  case Cut:
    SendMessageW(edit, WM_CUT, 0, 0);
    break;
  case Copy:
    SendMessageW(edit, WM_COPY, 0, 0);
    break;
  case Paste:
    SendMessageW(edit, WM_PASTE, 0, 0);
    break;
  case SelectAll:
    SendMessageW(edit, EM_SETSEL, 0, -1);
    break;
  case Find:
    ShowWindow(findBox, SW_SHOW);
    SetFocus(findBox);
    break;
  case FindNext:
    findNext();
    break;
  case Dark:
  case Light:
    dark = id == Dark;
    theme();
    break;
  case CopyPath:
    if (!docs[target].path.empty())
      clipboard(docs[target].path);
    break;
  case CopyName:
    if (!docs[target].path.empty())
      clipboard(fs::path(docs[target].path).filename().wstring());
    break;
  case CopyRelative:
    if (!project.empty() && !docs[target].path.empty()) {
      auto rel = fs::path(docs[target].path).lexically_relative(project);
      if (!rel.empty() && *rel.begin() != L"..")
        clipboard(rel.wstring());
    }
    break;
  case Reveal:
    if (!docs[target].path.empty()) {
      std::wstring args = L"/select,\"" + docs[target].path + L"\"";
      ShellExecuteW(frame, L"open", L"explorer.exe", args.c_str(), nullptr,
                    SW_SHOWNORMAL);
    }
    break;
  default: {
    auto &d = docs[active];
    if (id >= Utf8 && id <= Utf16) {
      d.encoding = id - Utf8;
      d.dirty = true;
    }
    if (id == Lf || id == CrLf) {
      d.crlf = id == CrLf;
      d.dirty = true;
    }
    if (id == Tabs || id == Spaces)
      d.spaces = id == Spaces;
    if (id == Width2 || id == Width4 || id == Width8) {
      d.width = id == Width2 ? 2 : id == Width8 ? 8 : 4;
      select(active);
    }
    retab();
    break;
  }
  }
  update();
}
static HMENU menu() {
  HMENU m = CreateMenu(), file = CreatePopupMenu(), editing = CreatePopupMenu(),
        view = CreatePopupMenu();
  for (auto pair : {std::pair<int, const wchar_t *>{New, L"New\tCtrl+N"},
                    {Open, L"Open…\tCtrl+O"},
                    {OpenFolder, L"Open OpenFolder…"},
                    {Save, L"Save\tCtrl+S"},
                    {SaveAs, L"Save As…"},
                    {SaveAll, L"Save All"},
                    {Close, L"Close Tab\tCtrl+W"},
                    {Exit, L"Exit"}})
    AppendMenuW(file, MF_STRING, pair.first, pair.second);
  for (auto pair : {std::pair<int, const wchar_t *>{Undo, L"Undo\tCtrl+Z"},
                    {Redo, L"Redo\tCtrl+Y"},
                    {Cut, L"Cut\tCtrl+X"},
                    {Copy, L"Copy\tCtrl+C"},
                    {Paste, L"Paste\tCtrl+V"},
                    {SelectAll, L"Select All\tCtrl+A"},
                    {Find, L"Find\tCtrl+F"},
                    {FindNext, L"Find Next\tF3"}})
    AppendMenuW(editing, MF_STRING, pair.first, pair.second);
  AppendMenuW(view, MF_STRING, Dark, L"Dark");
  AppendMenuW(view, MF_STRING, Light, L"Light");
  AppendMenuW(m, MF_POPUP, (UINT_PTR)file, L"File");
  AppendMenuW(m, MF_POPUP, (UINT_PTR)editing, L"Edit");
  AppendMenuW(m, MF_POPUP, (UINT_PTR)view, L"View");
  return m;
}
static LRESULT CALLBACK editorProc(HWND w, UINT msg, WPARAM wp, LPARAM lp,
                                   UINT_PTR, DWORD_PTR) {
  if (msg == WM_KEYDOWN && wp == VK_TAB && docs[active].spaces) {
    CHARRANGE r{};
    SendMessageW(edit, EM_EXGETSEL, 0, (LPARAM)&r);
    LONG line = SendMessageW(edit, EM_LINEFROMCHAR, r.cpMin, 0),
         start = SendMessageW(edit, EM_LINEINDEX, line, 0);
    std::wstring spaces(
        docs[active].width - (r.cpMin - start) % docs[active].width, L' ');
    SendMessageW(edit, EM_REPLACESEL, TRUE, (LPARAM)spaces.c_str());
    return 0;
  }
  return DefSubclassProc(w, msg, wp, lp);
}
static LRESULT CALLBACK procedure(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_SIZE: {
    RECT r;
    GetClientRect(w, &r);
    MoveWindow(tree, 0, 0, 220, r.bottom - 26, TRUE);
    MoveWindow(tabs, 220, 0, r.right - 220, 28, TRUE);
    MoveWindow(findBox, 220, 30, r.right - 220, 25, TRUE);
    MoveWindow(edit, 220, 58, r.right - 220, r.bottom - 84, TRUE);
    SendMessageW(status, WM_SIZE, 0, 0);
    return 0;
  }
  case WM_COMMAND:
    if ((HWND)lp == edit && HIWORD(wp) == EN_CHANGE && !internalChange) {
      docs[active].dirty = true;
      update();
      return 0;
    }
    if ((HWND)lp == findBox)
      return 0;
    command(LOWORD(wp), active);
    return 0;
  case WM_NOTIFY: {
    auto n = (NMHDR *)lp;
    if (n->hwndFrom == tabs && n->code == TCN_SELCHANGE)
      select(TabCtrl_GetCurSel(tabs));
    if (n->hwndFrom == tree && n->code == TVN_ITEMEXPANDINGW)
      expand(((NMTREEVIEWW *)lp)->itemNew.hItem);
    if (n->hwndFrom == tree && n->code == NM_DBLCLK) {
      Node *p = node(TreeView_GetSelection(tree));
      if (p && !p->directory)
        open(p->path);
    }
    break;
  }
  case WM_CONTEXTMENU: {
    POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    if (point.x == -1) {
      GetCursorPos(&point);
    }
    size_t target = active;
    bool fileMenu = (HWND)wp == tabs;
    if (fileMenu) {
      POINT local = point;
      ScreenToClient(tabs, &local);
      TCHITTESTINFO hit{};
      hit.pt = local;
      int i = TabCtrl_HitTest(tabs, &hit);
      if (i < 0)
        return 0;
      target = i;
    }
    if ((HWND)wp == tree) {
      POINT local = point;
      ScreenToClient(tree, &local);
      TVHITTESTINFO h{};
      h.pt = local;
      HTREEITEM item = TreeView_HitTest(tree, &h);
      Node *p = item ? node(item) : nullptr;
      if (!p)
        return 0;
      HMENU m = CreatePopupMenu();
      AppendMenuW(m, MF_STRING, CopyPath, L"Copy Path");
      AppendMenuW(m, MF_STRING, Open, L"Open");
      int id = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x,
                              point.y, 0, w, nullptr);
      if (id == CopyPath)
        clipboard(p->path.wstring());
      if (id == Open && !p->directory)
        open(p->path);
      DestroyMenu(m);
      return 0;
    }
    HMENU m = CreatePopupMenu();
    if (fileMenu) {
      for (auto pair :
           {std::pair<int, const wchar_t *>{CopyPath, L"Copy File Path"},
            {CopyRelative, L"Copy Relative File Path"},
            {CopyName, L"Copy File Name"},
            {Reveal, L"Show in Explorer"},
            {Save, L"Save"},
            {SaveAs, L"Save As…"},
            {Close, L"Close Tab"},
            {CloseOthers, L"Close Other Tabs"},
            {CloseRight, L"Close Tabs to the Right"}})
        AppendMenuW(m, MF_STRING, pair.first, pair.second);
    } else if ((HWND)wp == status) {
      for (auto pair : {std::pair<int, const wchar_t *>{Utf8, L"UTF-8"},
                        {Utf8Bom, L"UTF-8 with BOM"},
                        {Utf16, L"UTF-16 LE"},
                        {Lf, L"LF"},
                        {CrLf, L"CRLF"},
                        {Tabs, L"Indent Using Tabs"},
                        {Spaces, L"Indent Using Spaces"},
                        {Width2, L"Tab Width: 2"},
                        {Width4, L"Tab Width: 4"},
                        {Width8, L"Tab Width: 8"}})
        AppendMenuW(m, MF_STRING, pair.first, pair.second);
    } else {
      for (auto pair : {std::pair<int, const wchar_t *>{Undo, L"Undo"},
                        {Redo, L"Redo"},
                        {Cut, L"Cut"},
                        {Copy, L"Copy"},
                        {Paste, L"Paste"},
                        {SelectAll, L"Select All"},
                        {CopyPath, L"Copy File Path"}})
        AppendMenuW(m, MF_STRING, pair.first, pair.second);
    }
    int id = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x,
                            point.y, 0, w, nullptr);
    DestroyMenu(m);
    if (id)
      command(id, target);
    return 0;
  }
  case WM_CLOSE:
    for (size_t i = docs.size(); i-- > 0;)
      if (!close(i))
        return 0;
    DestroyWindow(w);
    return 0;
  case WM_DESTROY:
    PostQuitMessage(0);
    return 0;
  case WM_CTLCOLORSTATIC:
    SetTextColor((HDC)wp, dark ? RGB(225, 230, 240) : RGB(25, 25, 25));
    SetBkColor((HDC)wp, dark ? RGB(26, 30, 38) : RGB(240, 240, 240));
    return (LRESULT)(dark ? darkBrush : GetStockObject(WHITE_BRUSH));
  }
  return DefWindowProcW(w, msg, wp, lp);
}
#ifdef EDITOR_TESTS
#include "tests.cpp"
#endif
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
#ifdef EDITOR_TESTS
  if (std::wstring(GetCommandLineW()).find(L"--self-test") !=
      std::wstring::npos)
    return selfTest();
#endif
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  LoadLibraryW(L"Msftedit.dll");
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_TAB_CLASSES |
                                                      ICC_TREEVIEW_CLASSES |
                                                      ICC_BAR_CLASSES};
  InitCommonControlsEx(&controls);
  darkBrush = CreateSolidBrush(RGB(26, 30, 38));
  WNDCLASSW cls{};
  cls.hInstance = instance;
  cls.lpfnWndProc = procedure;
  cls.lpszClassName = L"SourceEditorWindow";
  cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  cls.hbrBackground = darkBrush;
  RegisterClassW(&cls);
  frame = CreateWindowW(cls.lpszClassName, L"Source Editor",
                        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1200,
                        800, nullptr, menu(), instance, nullptr);
  tree = CreateWindowExW(0, WC_TREEVIEWW, L"",
                         WS_CHILD | WS_VISIBLE | WS_BORDER | TVS_HASLINES |
                             TVS_HASBUTTONS | TVS_LINESATROOT,
                         0, 0, 0, 0, frame, nullptr, instance, nullptr);
  tabs = CreateWindowW(WC_TABCONTROLW, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
                       frame, nullptr, instance, nullptr);
  edit = CreateWindowExW(WS_EX_CLIENTEDGE, MSFTEDIT_CLASS, L"",
                         WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_HSCROLL |
                             ES_MULTILINE | ES_WANTRETURN | ES_NOHIDESEL,
                         0, 0, 0, 0, frame, nullptr, instance, nullptr);
  SendMessageW(edit, EM_SETTEXTMODE, TM_PLAINTEXT, 0);
  SendMessageW(edit, EM_EXLIMITTEXT, 0, 0x7fffffff);
  SendMessageW(edit, EM_SETEVENTMASK, 0, ENM_CHANGE);
  SetWindowSubclass(edit, editorProc, 1, 0);
  findBox = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 0, 0, 0, 0,
                            frame, nullptr, instance, nullptr);
  status = CreateWindowW(STATUSCLASSNAMEW, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0,
                         0, frame, nullptr, instance, nullptr);
  font = CreateFontW(-16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, FIXED_PITCH, L"Consolas");
  SendMessageW(edit, WM_SETFONT, (WPARAM)font, TRUE);
  docs.push_back({});
  int count = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &count);
  for (int i = 1; i < count; i++)
    open(argv[i]);
  LocalFree(argv);
  select(active);
  ShowWindow(frame, show);
  SendMessageW(frame, WM_SIZE, 0, 0);
  ACCEL keys[] = {
      {FVIRTKEY | FCONTROL, 'N', New},  {FVIRTKEY | FCONTROL, 'O', Open},
      {FVIRTKEY | FCONTROL, 'S', Save}, {FVIRTKEY | FCONTROL, 'W', Close},
      {FVIRTKEY | FCONTROL, 'F', Find}, {FVIRTKEY, VK_F3, FindNext}};
  HACCEL accelerators =
      CreateAcceleratorTableW(keys, sizeof(keys) / sizeof(keys[0]));
  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (!TranslateAcceleratorW(frame, accelerators, &message)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  DestroyAcceleratorTable(accelerators);
  DeleteObject(font);
  DeleteObject(darkBrush);
  CoUninitialize();
  return 0;
}
