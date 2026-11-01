#!/usr/bin/env python3
"""Exit 0 when the X display has a window whose title matches a regex.

usage: x11_window.py <regex>

The CI's Flatpak image (the Freedesktop SDK, no package manager) has no
xdotool, so the smoke test of the installed bundle uses this instead: it
walks the window tree of $DISPLAY with libX11 and reads every WM_NAME.
"""
import ctypes
import re
import sys

x11 = ctypes.CDLL("libX11.so.6")
Window = ctypes.c_ulong
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XDefaultRootWindow.restype = Window
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x11.XFetchName.argtypes = [ctypes.c_void_p, Window, ctypes.POINTER(ctypes.c_char_p)]
x11.XQueryTree.argtypes = [
    ctypes.c_void_p, Window, ctypes.POINTER(Window), ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)), ctypes.POINTER(ctypes.c_uint),
]

display = x11.XOpenDisplay(None)
if not display:
    sys.exit("cannot open the X display")
pattern = re.compile(sys.argv[1])


def matches(window):
    name = ctypes.c_char_p()
    if x11.XFetchName(display, window, ctypes.byref(name)) and name.value:
        title = name.value.decode("utf-8", "replace")
        if pattern.search(title):
            print(f"window 0x{window:x}: {title}")
            return True
    root, parent = Window(), Window()
    children, count = ctypes.POINTER(Window)(), ctypes.c_uint()
    if x11.XQueryTree(display, window, ctypes.byref(root), ctypes.byref(parent),
                      ctypes.byref(children), ctypes.byref(count)):
        return any(matches(children[i]) for i in range(count.value))
    return False


sys.exit(0 if matches(x11.XDefaultRootWindow(display)) else 1)
