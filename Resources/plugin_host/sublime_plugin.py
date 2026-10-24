"""Independent command interfaces for explicit, one-shot local plugins."""

import sublime
import inspect


class Command:
    def name(self):
        characters = self.__class__.__name__
        parts = [characters[0].lower()]
        previous_upper = False
        for character in characters[1:]:
            upper = character.isupper()
            parts.append("_" + character.lower() if upper and not previous_upper else character)
            previous_upper = upper
        name = "".join(parts)
        return name[:-8] if name.endswith("_command") else name

    def want_event(self):
        return False

    def filter_args(self, args):
        values = dict(args or {})
        if not self.want_event():
            values.pop("event", None)
        return values

    def is_enabled(self, **args):
        return True

    def is_visible(self, **args):
        return True

    def is_checked(self, **args):
        return False

    def is_enabled_(self, args):
        values = self.filter_args(args)
        try:
            inspect.signature(self.is_enabled).bind(**values)
        except TypeError:
            result = self.is_enabled()
        else:
            result = self.is_enabled(**values)
        if not isinstance(result, bool):
            raise ValueError("is_enabled must return bool")
        return result


class TextCommand(Command):
    def __init__(self, view):
        self.view = view

    def run_(self, edit_token, args):
        with self.view._edit_scope() as edit:
            return self.run(edit, **self.filter_args(args))


class WindowCommand(Command):
    def __init__(self, window):
        self.window = window

    def run_(self, edit_token, args):
        return self.run(**self.filter_args(args))


class ApplicationCommand(Command):
    def run_(self, edit_token, args):
        return self.run(**self.filter_args(args))
