"""Web smoke test: the exported web build must load and keep running in a real (headless) Chromium.

Checks:
  1. the engine starts (the loader finishes) and frames keep coming,
  2. the start screen opens the menu, Play starts a session,
  4. settings and the report overlay (F8) open, the Dutch screens render,
  5. no page errors were thrown.

Usage: python -I tools/web_smoke.py build/web [screenshot_dir]
"""
import functools
import hashlib
import http.server
import os
import socketserver
import sys
import threading

from playwright.sync_api import sync_playwright


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass


def serve(directory: str) -> tuple[socketserver.TCPServer, int]:
    handler = functools.partial(QuietHandler, directory=directory)
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def canvas_hash(page) -> str:
    return hashlib.sha256(page.screenshot()).hexdigest()



def main() -> int:
    build = sys.argv[1]
    shots = sys.argv[2] if len(sys.argv) > 2 else None
    httpd, port = serve(build)
    errors: list[str] = []
    failures: list[str] = []
    base = f"http://127.0.0.1:{port}/index.html"

    def shot(page, name):
        if shots:
            page.screenshot(path=f"{shots}/{name}.png")

    with sync_playwright() as p:
        # SMOKE_CHANNEL=chrome uses the installed Chrome (local); CI uses Playwright's own Chromium.
        browser = p.chromium.launch(channel=os.environ.get("SMOKE_CHANNEL") or None,
                                    args=["--mute-audio", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
        page = browser.new_page(viewport={"width": 1280, "height": 720})
        page.on("pageerror", lambda e: errors.append(str(e)))

        def load(url, what):
            page.goto(url)
            try:
                page.wait_for_selector("#loader.done", state="attached", timeout=60000)
            except Exception:
                failures.append(f"{what}: engine did not start within 60 s")

        load(base, "boot")
        page.wait_for_timeout(1500)
        shot(page, "web-boot")
        hashes = set()
        for _ in range(4):
            hashes.add(canvas_hash(page))
            page.wait_for_timeout(400)
        if len(hashes) < 2:
            failures.append("canvas did not change for 1.6 s: frames are not coming")

        page.mouse.click(640, 360)  # start screen -> menu
        page.wait_for_timeout(1200)
        shot(page, "web-menu")
        before = canvas_hash(page)
        page.mouse.click(640, 393)  # Play, the big orange button (under the character button)
        page.wait_for_timeout(2500)
        if canvas_hash(page) == before:
            failures.append("Play did not open the game screen")

        # the match itself: walk a bit, act, and look at it after a few seconds of bots playing
        load(f"{base}?scene=game&seed=777", "game")
        page.wait_for_timeout(1500)
        page.keyboard.down("d")
        page.wait_for_timeout(1500)
        page.keyboard.up("d")
        page.keyboard.press("Space")
        page.wait_for_timeout(6000)
        shot(page, "web-game-play")

        load(f"{base}?scene=settings", "settings")
        page.wait_for_timeout(2000)
        shot(page, "web-settings")
        top = {"x": 0, "y": 0, "width": 1280, "height": 420}
        before = hashlib.sha256(page.screenshot(clip=top)).hexdigest()
        page.keyboard.press("F8")
        page.wait_for_timeout(1200)
        shot(page, "web-report")
        if hashlib.sha256(page.screenshot(clip=top)).hexdigest() == before:
            failures.append("F8 did not open the report overlay")

        # Dutch: texts are ~30 % longer, the layouts must still fit (checked by eye in the contact sheet)
        for scene, extra, name in [("menu", "&lang=nl", "web-menu-nl"), ("settings", "&lang=nl", "web-settings-nl"),
                                   ("settings", "&lang=nl&dialog=privacy", "web-privacy-nl"),
                                   ("game", "&lang=nl", "web-game-nl"), ("online", "&lang=nl", "web-online-nl")]:
            load(f"{base}?scene={scene}{extra}", name)
            page.wait_for_timeout(2500)
            shot(page, name)
        browser.close()
    httpd.shutdown()

    for e in errors:
        failures.append("page error: " + e)
    for f in failures:
        print("FAIL:", f)
    print("web smoke:", "OK" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
