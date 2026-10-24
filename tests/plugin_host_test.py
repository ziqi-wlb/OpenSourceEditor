"""Public one-shot SDK CLI checks; all plugins and edits are owned test fixtures."""

import json
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SDK = Path(__file__).resolve().parents[1] / "Resources" / "plugin_host"
HOST = SDK / "host.py"
DEMO = SDK / "demo_plugin.py"


class PluginHostTests(unittest.TestCase):
    def invoke(self, plugin, command, data, cli_args=None):
        argv = [sys.executable, "-I", str(HOST), str(plugin), command]
        if cli_args is not None:
            argv.append(json.dumps(cli_args))
        process = subprocess.run(argv, input=json.dumps(data), text=True, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(len(process.stdout.splitlines()), 1, process.stdout)
        return json.loads(process.stdout), process.stderr

    def fixture(self, source):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / "plugin.py"
        path.write_text(source)
        return path

    def test_demo_reverse_emoji_is_utf16_safe(self):
        result, _ = self.invoke(DEMO, "reverse_selection", {"text": "a😀b", "selections": [[0, 4]]})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "b😀a")
        self.assertEqual(result["selections"], [[0, 4]])

    def test_demo_prefix_multiselection_and_explicit_args(self):
        result, _ = self.invoke(DEMO, "prefix_selection", {
            "text": "😀 dog cat", "selections": [[3, 3], [7, 3]], "args": {"prefix": "ignored"},
        }, {"prefix": "!"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "😀 !dog !cat")
        self.assertEqual(result["selections"], [[4, 3], [9, 3]])

    def test_reject_selection_cutting_surrogate_pair(self):
        result, _ = self.invoke(DEMO, "reverse_selection", {"text": "a😀b", "selections": [[2, 0]]})
        self.assertFalse(result["ok"])
        self.assertIn("surrogate", result["error"]["message"])
        self.assertEqual(result["text"], "a😀b")

    def test_region_direction_and_line_helpers(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class InspectCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  self.view.sel().clear()
  self.view.sel().add(sublime.Region(4, 1))
  assert self.view.substr(self.view.sel()[0]) == "😀b"
  assert self.view.sel()[0].a == 4 and self.view.sel()[0].b == 1
  assert self.view.substr(self.view.line(1)) == "a😀b"
  assert self.view.substr(self.view.full_line(1)) == "a😀b\\r\\n"
  assert self.view.substr(self.view.word(7)) == "word"
  sublime.status_message("checked")
''')
        result, _ = self.invoke(plugin, "inspect", {"text": "a😀b\r\nword", "selections": [[0, 0]]})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["selections"], [[1, 3]])
        self.assertEqual(result["status"], "checked")

    def test_builtin_insert_multicursor(self):
        plugin = self.fixture('''import sublime_plugin
class InsertTestCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  self.view.run_command("insert", {"characters":"!"})
''')
        result, _ = self.invoke(plugin, "insert_test", {"text": "😀 X 😀", "selections": [[0, 2], [5, 2]]})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "! X !")
        self.assertEqual(result["selections"], [[1, 0], [5, 0]])

    def test_failed_plugin_rolls_back_and_prints_do_not_pollute_json(self):
        plugin = self.fixture('''import sublime, sublime_plugin
print("import noise")
class FailCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  self.view.replace(edit, sublime.Region(0, 3), "changed")
  print("run noise")
  raise RuntimeError("owned test failure")
''')
        result, stderr = self.invoke(plugin, "fail", {"text": "abc", "selections": [[0, 3]]})
        self.assertFalse(result["ok"])
        self.assertEqual(result["text"], "abc")
        self.assertEqual(result["selections"], [[0, 3]])
        self.assertEqual(result["error"]["type"], "RuntimeError")
        self.assertIn("import noise", stderr)
        self.assertIn("run noise", stderr)

    def test_invalid_edit_identity_is_rejected(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class InvalidEditCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  self.view.insert(sublime.Edit(self.view), 0, "bad")
''')
        result, _ = self.invoke(plugin, "invalid_edit", {"text": "abc", "selections": [[0, 0]]})
        self.assertFalse(result["ok"])
        self.assertIn("not active", result["error"]["message"])

    def test_synchronous_callback_and_settings(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class CallbackCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  value = self.view.settings().get("prefix")
  sublime.set_timeout(lambda: self.view.insert(edit, 0, value), 0)
  self.view.settings().set("temporary", True)
  assert self.view.settings().has("temporary")
  self.view.settings().erase("temporary")
  assert not self.view.settings().has("temporary")
''')
        result, _ = self.invoke(plugin, "callback", {"text": "abc", "selections": [[0, 0]], "settings": {"prefix": "!"}})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "!abc")

    def test_unsupported_async_and_undo_are_explicit(self):
        for operation in ['sublime.set_timeout(lambda: None, 1)', 'self.view.run_command("undo")']:
            plugin = self.fixture('import sublime, sublime_plugin\nclass UnsupportedCommand(sublime_plugin.TextCommand):\n def run(self, edit):\n  ' + operation + '\n')
            result, _ = self.invoke(plugin, "unsupported", {"text": "abc", "selections": [[0, 0]]})
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["type"], "NotImplementedError")

    def test_acronym_command_name(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class HTTPServerCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  sublime.status_message(self.name())
''')
        result, _ = self.invoke(plugin, "h_tTPServer", {"text": "", "selections": []})
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "h_tTPServer")

    def test_window_and_application_commands(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class WindowAppendCommand(sublime_plugin.WindowCommand):
 def run(self, suffix="!"):
  self.window.active_view().run_command("append", {"characters":suffix})
class ApplicationAppendCommand(sublime_plugin.ApplicationCommand):
 def run(self):
  sublime.active_window().run_command("append", {"characters":"?"})
''')
        for name, expected in [("window_append", "abc!"), ("application_append", "abc?")]:
            result, _ = self.invoke(plugin, name, {"text": "abc", "selections": [[0, 0]]})
            self.assertTrue(result["ok"])
            self.assertEqual(result["text"], expected)

    def test_caller_sublime_module_does_not_override_sdk(self):
        plugin = self.fixture('''import sublime, sublime_plugin
class CheckSdkCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  sublime.status_message("sdk")
''')
        (plugin.parent / "sublime.py").write_text('raise RuntimeError("caller shadow module was loaded")\n')
        result, _ = self.invoke(plugin, "check_sdk", {"text": "", "selections": []})
        self.assertTrue(result["ok"], result)

    def test_strict_input_is_rejected_before_loading_plugin(self):
        plugin = self.fixture('raise RuntimeError("plugin must not load")\n')
        cases = [
            {"text": "abc", "selections": [[True, 0]]},
            {"text": "abc", "selections": [[0, -1]]},
            {"text": "abc", "selections": [], "args": []},
            {"text": "abc", "selections": [], "unexpected": True},
            {"text": "\ud800", "selections": []},
        ]
        for data in cases:
            result, _ = self.invoke(plugin, "anything", data)
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["type"], "ValueError")
            self.assertNotIn("plugin must not load", result["error"]["message"])

    def test_non_json_numbers_are_rejected(self):
        result, _ = self.invoke(DEMO, "reverse_selection", {"text": "abc", "selections": [], "args": {"x": float("nan")}})
        self.assertFalse(result["ok"])
        self.assertIn("non-JSON", result["error"]["message"])

    def test_argument_free_enable_hook_and_same_class_alias(self):
        plugin = self.fixture('''import sublime_plugin
class EnabledCommand(sublime_plugin.TextCommand):
 def is_enabled(self):
  return True
 def run(self, edit, suffix):
  self.view.insert(edit, self.view.size(), suffix)
Alias = EnabledCommand
''')
        result, _ = self.invoke(plugin, "enabled", {"text": "abc", "selections": [], "args": {"suffix": "!"}})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["text"], "abc!")

    def test_disable_hook_and_invalid_builtin_offset_do_not_commit(self):
        disabled = self.fixture('''import sublime_plugin
class DisabledCommand(sublime_plugin.TextCommand):
 def is_enabled(self):
  return False
 def run(self, edit):
  raise RuntimeError("disabled command must not run")
''')
        result, _ = self.invoke(disabled, "disabled", {"text": "abc", "selections": []})
        self.assertFalse(result["ok"])
        self.assertIn("disabled", result["error"]["message"])
        broken = self.fixture('''import sublime_plugin
class BrokenCommand(sublime_plugin.TextCommand):
 def run(self, edit):
  self.view.insert(edit, 2, "bad")
''')
        result, _ = self.invoke(broken, "broken", {"text": "a😀b", "selections": []})
        self.assertFalse(result["ok"])
        self.assertEqual(result["text"], "a😀b")

    def test_edit_scope_expiration_after_success_and_failure(self):
        spec = importlib.util.spec_from_file_location("_owned_test_snapshot_sdk", SDK / "sublime.py")
        sdk = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sdk)
        view = sdk.View("abc", [])
        with view._edit_scope() as edit:
            view.insert(edit, 0, "!")
        self.assertEqual(edit.edit_token, 0)
        with self.assertRaises(ValueError):
            view.insert(edit, 0, "bad")
        with self.assertRaises(RuntimeError):
            with view._edit_scope() as failed_edit:
                raise RuntimeError("owned scope failure")
        self.assertEqual(failed_edit.edit_token, 0)
        with self.assertRaises(ValueError):
            view.insert(None, 0, "bad")


if __name__ == "__main__":
    unittest.main()
