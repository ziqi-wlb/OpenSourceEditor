"""Example owned plugin: reverse selected Unicode characters, preserving UTF16 safety."""

import sublime
import sublime_plugin


class ReverseSelectionCommand(sublime_plugin.TextCommand):
    def run(self, edit):
        for selection in reversed(list(self.view.sel())):
            if not selection.empty():
                self.view.replace(edit, selection, self.view.substr(selection)[::-1])
        sublime.status_message("Reversed local selections")


class PrefixSelectionCommand(sublime_plugin.TextCommand):
    def run(self, edit, prefix="> "):
        for selection in reversed(list(self.view.sel())):
            self.view.insert(edit, selection.begin(), prefix)
        sublime.status_message("Prefixed local selections")
