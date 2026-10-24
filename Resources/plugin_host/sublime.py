"""Independent, bounded snapshot editor SDK. Offsets are UTF16, not Python indices."""

from array import array
from bisect import bisect_left
from contextlib import contextmanager
import copy
import re


MAX_TEXT_UNITS = 4 * 1024 * 1024
_current_view = None


def _integer(value, label):
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{label} must be an integer")
    return value


def _text(value):
    if not isinstance(value, str):
        raise ValueError("text must be a string")
    if any(0xD800 <= ord(c) <= 0xDFFF for c in value):
        raise ValueError("text contains an unpaired surrogate")
    units = len(value.encode("utf-16-le")) // 2
    if units > MAX_TEXT_UNITS:
        raise ValueError("text exceeds the snapshot UTF16 capacity")
    return units


class Region:
    def __init__(self, a, b=None, xpos=-1):
        self.a = _integer(a, "region.a")
        self.b = self.a if b is None else _integer(b, "region.b")
        self.xpos = xpos

    def begin(self):
        return min(self.a, self.b)

    def end(self):
        return max(self.a, self.b)

    def empty(self):
        return self.a == self.b

    def size(self):
        return abs(self.b - self.a)

    def contains(self, value):
        if isinstance(value, Region):
            return self.begin() <= value.begin() <= value.end() <= self.end()
        return self.begin() <= value <= self.end()

    def intersects(self, other):
        return self == other or max(self.begin(), other.begin()) < min(self.end(), other.end())

    def cover(self, other):
        bounds = (min(self.begin(), other.begin()), max(self.end(), other.end()))
        return Region(*bounds if self.a <= self.b else reversed(bounds))

    def intersection(self, other):
        start, end = max(self.begin(), other.begin()), min(self.end(), other.end())
        return Region(start, end) if start < end else Region(0)

    def to_tuple(self):
        return self.a, self.b

    def __len__(self):
        return self.size()

    def __iter__(self):
        return iter((self.a, self.b))

    def __eq__(self, other):
        return isinstance(other, Region) and self.a == other.a and self.b == other.b

    def __lt__(self, other):
        return (self.begin(), self.end()) < (other.begin(), other.end())

    def __repr__(self):
        return f"Region({self.a}, {self.b})"


class Settings:
    def __init__(self, values=None):
        self._values = copy.deepcopy(values or {})

    def get(self, name, default=None):
        return copy.deepcopy(self._values.get(name, default))

    def set(self, name, value):
        self._values[name] = copy.deepcopy(value)

    def erase(self, name):
        self._values.pop(name, None)

    def has(self, name):
        return name in self._values

    def __getitem__(self, name):
        return copy.deepcopy(self._values[name])

    def __setitem__(self, name, value):
        self.set(name, value)


class Selection:
    """Snapshot iteration; overlap merges, touching disjoint ranges do not merge."""

    def __init__(self, view):
        self._view = view
        self._regions = []

    def __iter__(self):
        return iter([Region(r.a, r.b, r.xpos) for r in self._regions])

    def __len__(self):
        return len(self._regions)

    def __getitem__(self, index):
        r = self._regions[index]
        return Region(r.a, r.b, r.xpos)

    def __delitem__(self, index):
        del self._regions[index]

    def clear(self):
        self._regions.clear()

    def add(self, region):
        if not isinstance(region, Region):
            region = Region(region)
        self.add_all([region])

    def add_all(self, regions):
        items = list(self._regions)
        for region in regions:
            if not isinstance(region, Region):
                region = Region(region)
            self._view._index(region.a)
            self._view._index(region.b)
            items.append(Region(region.a, region.b, region.xpos))
        merged = []
        for region in sorted(items):
            if merged:
                old = merged[-1]
                overlap = max(region.begin(), old.begin()) < min(region.end(), old.end())
                point_overlap = (
                    (region.empty() and old.begin() <= region.a <= old.end()) or
                    (old.empty() and region.begin() <= old.a <= region.end())
                )
                if overlap or point_overlap:
                    merged[-1] = old.cover(region)
                    continue
            merged.append(region)
        self._regions = merged

    def subtract(self, region):
        start, end = region.begin(), region.end()
        self._view._index(start)
        self._view._index(end)
        kept = []
        for old in self._regions:
            if old.empty():
                if not start <= old.a <= end:
                    kept.append(old)
            elif start == end or old.end() <= start or old.begin() >= end:
                kept.append(old)
            else:
                for a, b in [(old.begin(), min(start, old.end())), (max(end, old.begin()), old.end())]:
                    if a < b:
                        kept.append(Region(b, a) if old.a > old.b else Region(a, b))
        self._regions = sorted(kept)

    def contains(self, region):
        return any(r.contains(region) for r in self._regions)

    def has_empty_region(self):
        return any(r.empty() for r in self._regions)

    def has_non_empty_region(self):
        return any(not r.empty() for r in self._regions)


class Edit:
    def __init__(self, view):
        self._view = view
        self.edit_token = 1


class View:
    def __init__(self, text, selections, settings=None):
        _text(text)
        self._text = text
        self._boundaries = None
        self._edit = None
        self._settings = Settings(settings)
        self._selection = Selection(self)
        self._status = ""
        self._selection.add_all(Region(loc, loc + length) for loc, length in selections)

    def _map(self):
        if self._boundaries is None:
            boundaries = array("I", [0])
            total = 0
            for c in self._text:
                total += 2 if ord(c) > 0xFFFF else 1
                boundaries.append(total)
            self._boundaries = boundaries
        return self._boundaries

    def _index(self, offset):
        offset = _integer(offset, "UTF16 offset")
        bounds = self._map()
        index = bisect_left(bounds, offset)
        if index >= len(bounds) or bounds[index] != offset:
            raise ValueError("UTF16 offset is out of range or splits a surrogate pair")
        return index

    def _offset(self, index):
        return self._map()[index]

    @contextmanager
    def _edit_scope(self):
        owned = self._edit is None
        if owned:
            self._edit = Edit(self)
        edit = self._edit
        try:
            yield edit
        finally:
            if owned:
                edit.edit_token = 0
                self._edit = None

    def _valid_edit(self, edit):
        if edit is None or edit is not self._edit or not edit.edit_token or edit._view is not self:
            raise ValueError("Edit is not active for this snapshot view")

    def size(self):
        return self._map()[-1]

    def sel(self):
        return self._selection

    def settings(self):
        return self._settings

    def substr(self, region):
        if isinstance(region, Region):
            return self._text[self._index(region.begin()):self._index(region.end())]
        index = self._index(region)
        return self._text[index:index + 1]

    def replace(self, edit, region, text):
        self._valid_edit(edit)
        if not isinstance(region, Region):
            raise ValueError("replace requires Region")
        start, end = region.begin(), region.end()
        a, b = self._index(start), self._index(end)
        added = _text(text)
        if self.size() - (end - start) + added > MAX_TEXT_UNITS:
            raise ValueError("replacement exceeds the snapshot UTF16 capacity")
        delta = added - (end - start)

        def moved(point):
            if point < start:
                return point
            if point > end:
                return point + delta
            if point == start and start != end:
                return start
            return start + added

        regions = [Region(moved(r.a), moved(r.b), r.xpos) for r in self._selection]
        self._text = self._text[:a] + text + self._text[b:]
        self._boundaries = None
        self._selection.clear()
        self._selection.add_all(regions)

    def insert(self, edit, point, text):
        self.replace(edit, Region(point), text)
        return len(text.encode("utf-16-le")) // 2

    def erase(self, edit, region):
        self.replace(edit, region, "")

    def word(self, region):
        point = region.b if isinstance(region, Region) else region
        index = self._index(point)
        for match in re.finditer(r"\w+", self._text):
            if match.start() <= index < match.end() or index == match.end():
                return Region(self._offset(match.start()), self._offset(match.end()))
        return Region(point)

    def _line_span(self, region, full):
        if not isinstance(region, Region):
            region = Region(region)
        start, end = self._index(region.begin()), self._index(region.end())
        first = self._text.rfind("\n", 0, start) + 1
        if end > start and self._text[end - 1:end] == "\n":
            end -= 1
        newline = self._text.find("\n", end)
        last = len(self._text) if newline < 0 else newline
        if full and newline >= 0:
            last += 1
        elif not full and last > first and self._text[last - 1:last] == "\r":
            last -= 1
        return Region(self._offset(first), self._offset(last))

    def line(self, region):
        return self._line_span(region, False)

    def full_line(self, region):
        return self._line_span(region, True)

    def window(self):
        return Window(self)

    def run_command(self, command, args=None):
        args = args or {}
        if not isinstance(args, dict):
            raise ValueError("command args must be an object")
        with self._edit_scope() as edit:
            if command == "append":
                self.insert(edit, self.size(), args["characters"])
            elif command == "insert":
                value = args["characters"]
                added = _text(value)
                original = list(self.sel())
                carets = []
                for region in reversed(original):
                    self.replace(edit, region, value)
                shift = 0
                for region in original:
                    carets.append(Region(region.begin() + shift + added))
                    shift += added - region.size()
                self.sel().clear()
                self.sel().add_all(carets)
            elif command in {"upper_case", "lower_case"}:
                method = str.upper if command == "upper_case" else str.lower
                for region in reversed(list(self.sel())):
                    target = self.word(region) if region.empty() else region
                    self.replace(edit, target, method(self.substr(target)))
            else:
                raise NotImplementedError(f"unsupported snapshot builtin command: {command}")

    def _snapshot(self):
        return {"text": self._text, "selections": [[r.begin(), r.size()] for r in self.sel()], "status": self._status}


class Window:
    def __init__(self, view):
        self._view = view

    def active_view(self):
        return self._view

    def views(self):
        return [self._view]

    def run_command(self, command, args=None):
        return self._view.run_command(command, args)


def active_window():
    if _current_view is None:
        return None
    return Window(_current_view)


def status_message(message):
    if not isinstance(message, str):
        raise ValueError("status must be a string")
    if _current_view is not None:
        _current_view._status = message


def set_timeout(callback, delay=0):
    if delay != 0:
        raise NotImplementedError("snapshot SDK supports only synchronous set_timeout(callback, 0)")
    if not callable(callback):
        raise ValueError("callback must be callable")
    callback()
