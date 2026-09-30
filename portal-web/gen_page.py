#!/usr/bin/env python3
"""Regenerate StreamScribe/StreamScribe/Services/Portal/PortalPage.swift from portal.html.

Usage (from the repo root):  python3 portal-web/gen_page.py
"""
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "portal.html")
dst = os.path.join(here, "..", "StreamScribe", "StreamScribe", "Services", "Portal", "PortalPage.swift")

html = open(src, encoding="utf-8").read()
# The page is embedded in a Swift raw string literal (#"""…"""#). These two
# sequences are the only ones that could end it early or start interpolation.
if '"""#' in html or '\\#' in html:
    sys.exit("portal.html contains a raw-string delimiter sequence; rephrase it")

out = '''import Foundation

// MARK: - StreamScribe Web Portal — the page
//
// GENERATED from portal-web/portal.html by portal-web/gen_page.py — edit the
// HTML and regenerate rather than editing this string by hand.
//
// One self-contained page (no external scripts, fonts or CDNs, so it works
// behind strict corporate proxies and under the server's Content-Security-
// Policy). Stored as a Swift RAW string literal (#"""…"""#) so backslashes in
// the JavaScript reach the browser verbatim — no double-escaping layer.

nonisolated enum PortalPage {
    static let html: String = #"""
''' + html.rstrip("\n") + '''
"""#
}
'''
open(dst, "w", encoding="utf-8").write(out)
print("wrote", os.path.normpath(dst), len(out), "bytes")
