#!/usr/bin/env python3
"""Run one explicit local plugin command against one JSON editor snapshot."""

from contextlib import redirect_stdout
import importlib.util
import json
from pathlib import Path
import sys


MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_SELECTIONS = 100_000
SDK_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SDK_DIRECTORY))
import sublime
import sublime_plugin


def decode_json(data):
    def invalid_number(value):
        raise ValueError(f"non-JSON numeric value: {value}")
    return json.loads(data, parse_constant=invalid_number)


def parse_input():
    raw = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError("snapshot JSON exceeds 8 MiB")
    data = decode_json(raw)
    if not isinstance(data, dict):
        raise ValueError("snapshot must be an object")
    if set(data) - {"text", "selections", "args", "settings"}:
        raise ValueError("snapshot has unsupported fields")
    sublime._text(data.get("text"))
    selections = data.get("selections")
    if not isinstance(selections, list) or len(selections) > MAX_SELECTIONS:
        raise ValueError("selections must be an array with at most 100000 ranges")
    for selection in selections:
        if not isinstance(selection, list) or len(selection) != 2:
            raise ValueError("each selection must be [location,length]")
        loc = sublime._integer(selection[0], "selection location")
        length = sublime._integer(selection[1], "selection length")
        if loc < 0 or length < 0:
            raise ValueError("selection location and length must be nonnegative")
    for field in ("args", "settings"):
        if field not in data:
            data[field] = {}
        if not isinstance(data[field], dict):
            raise ValueError(f"{field} must be an object")
    if len(sys.argv) == 4:
        data["args"] = decode_json(sys.argv[3])
        if not isinstance(data["args"], dict):
            raise ValueError("CLI ARGS_JSON must be an object")
    return data


def invoke(data):
    if len(sys.argv) not in (3, 4):
        raise ValueError("usage: python3 -I host.py ABSOLUTE_PLUGIN_FILE COMMAND [ARGS_JSON]")
    plugin_path = Path(sys.argv[1])
    if not plugin_path.is_absolute() or not plugin_path.is_file():
        raise ValueError("PLUGIN_FILE must be an explicit absolute regular file")
    command_name = sys.argv[2]
    if not command_name:
        raise ValueError("COMMAND must be nonempty")
    view = sublime.View(data["text"], data["selections"], data["settings"])
    sublime._current_view = view
    # SDK imports above win over caller siblings called sublime.py or sublime_plugin.py.
    sys.path.insert(1, str(plugin_path.resolve().parent))
    module_name = "_rea_explicit_snapshot_plugin"
    spec = importlib.util.spec_from_file_location(module_name, plugin_path)
    if spec is None or spec.loader is None:
        raise ValueError("PLUGIN_FILE must be a Python source module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    registry = {}
    seen_classes = set()
    for value in vars(module).values():
        if not isinstance(value, type) or value.__module__ != module_name:
            continue
        if value in seen_classes:
            continue
        seen_classes.add(value)
        if issubclass(value, sublime_plugin.TextCommand):
            command = value(view)
        elif issubclass(value, sublime_plugin.WindowCommand):
            command = value(sublime.Window(view))
        elif issubclass(value, sublime_plugin.ApplicationCommand):
            command = value()
        else:
            continue
        name = command.name()
        if name in registry:
            raise ValueError(f"duplicate local plugin command: {name}")
        registry[name] = command
    if command_name not in registry:
        raise NotImplementedError(f"plugin does not register command: {command_name}")
    command = registry[command_name]
    arguments = command.filter_args(data["args"])
    if command.is_enabled_(arguments) is not True:
        raise ValueError(f"plugin command is disabled: {command_name}")
    with view._edit_scope():
        command.run_(1, arguments)
    return {"ok": True, **view._snapshot()}


def main():
    output = sys.stdout
    data = None
    try:
        data = parse_input()
        with redirect_stdout(sys.stderr):
            result = invoke(data)
        encoded = json.dumps(result, ensure_ascii=False, allow_nan=False)
        if len(encoded.encode("utf-8")) > MAX_JSON_BYTES:
            raise ValueError("result JSON exceeds 8 MiB")
    except BaseException as error:
        message = str(error).encode("utf-8", errors="replace").decode("utf-8")[:4096]
        result = {"ok": False, "error": {"type": type(error).__name__, "message": message}}
        if data is not None:
            result.update(text=data["text"], selections=data["selections"])
        encoded = json.dumps(result, ensure_ascii=False, allow_nan=False)
    output.write(encoded + "\n")
    output.flush()


if __name__ == "__main__":
    main()
