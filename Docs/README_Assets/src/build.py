"""Builds the README images from HTML, rendered by the installed Google Chrome through Playwright.

    Docs/README_Assets/src/build.sh [target …] # runs this; targets are the function names below

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts. Braid's palette and
         sheet styles (Braid/README_Assets/src/build.py), so the two READMEs read as one family.
Outputs: hero.png, stack.png, join-guide.png, thread-search.png, sewn-turn.png, seam-wire.png in argv[1].
"""

import html
import math
import os
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# Braid's palette (Braid/README_Assets/src/build.py), so the two READMEs read as one family.
BG, FG, DIM, MUTED, BORDER, WHITE = "#141414", "#E6E2D8", "#8A8A8A", "#6E6E6E", "#3A3A3A", "#F4F4F4"
BLUE, GREEN, ORANGE, GOLD, RED = "#4C8DF5", "#2EB67D", "#F0883E", "#D4AF37", "#E5484D"
HERO_BLUE, HERO_GREEN, HERO_ORANGE, HERO_GOLD, HERO_LINE = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0"

SANS = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "Menlo, 'SF Mono', monospace"


def shoot(browser, page_html, path, selector=None, viewport=(1200, 800), scale=2):
    """Writes `page_html` beside the inputs (so relative URLs resolve) and screenshots it."""
    with tempfile.NamedTemporaryFile("w", suffix=".html", dir=HERE, delete=False, encoding="utf-8") as f:
        f.write(page_html)
        name = f.name
    try:
        page = browser.new_page(device_scale_factor=scale, viewport={"width": viewport[0], "height": viewport[1]})
        page.goto("file://" + name)
        page.wait_for_timeout(150)
        if selector:
            page.locator(selector).screenshot(path=path)
        else:
            page.screenshot(path=path, full_page=True)
        page.close()
    finally:
        os.unlink(name)


# MARK: The hero

# The hero reads left to right: each lane starts as its own row of graph nodes, joined to the other
# lanes by shared entities; the rows unravel into strands, the strands braid, and the braid tightens
# into the one beam that ends in the index.
# Every block's first ink sits on the leading edge of the title's "A" (x 54.5).
BAND_Y, BAND_X0, BAND_X1, INDEX_X = 469, 60.5, 695.5, 1102
LANES_HERO = [(HERO_BLUE, -50, math.pi * 0.62), (HERO_GREEN, 0, math.pi * 1.95), (HERO_ORANGE, 50, math.pi * 1.28)]


def smoothstep(a, b, t):
    t = min(1, max(0, (t - a) / (b - a)))
    return t * t * (3 - 2 * t)


def strand_y(x, row, phase, amplitude=46, period=250):
    """A lane's row while it is still graph, then its share of the braid, then the beam."""
    t = (x - BAND_X0) / (BAND_X1 - BAND_X0)
    apart = 1 - smoothstep(0.1, 0.55, t)
    wobble = 7 * math.sin(x / 31 + row / 9) * apart
    weave = amplitude * smoothstep(0.05, 0.4, t) * (1 - t) ** 1.1
    return BAND_Y + (row + wobble) * apart + weave * math.sin(2 * math.pi * (x - BAND_X0) / period + phase)


def strand_path(row, phase):
    points, x = [], BAND_X0
    while x <= BAND_X1:
        points.append((x, strand_y(x, row, phase)))
        x += 3
    return "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in points)


# Entities on each lane's row, (x, weight); they shrink and fade as the row becomes strand.
NODE_XS = [[(x - 24.5, w) for x, w in lane] for lane in [
    [(85, 1.15), (139, .8), (196, 1.0), (247, .75), (309, .9), (352, .7)],
    [(97, .85), (168, 1.2), (219, .8), (281, .95), (331, .7)],
    [(90, .95), (126, .7), (183, .9), (238, 1.1), (296, .8), (358, .7)]]]
# Relationships across lanes: (lane, node) to (lane, node).
CROSS = [((0, 0), (1, 0)), ((1, 0), (2, 1)), ((0, 1), (2, 2)), ((1, 1), (0, 2)), ((2, 3), (1, 2)), ((0, 3), (1, 3)),
         ((2, 4), (1, 3))]
# Entities merged across lanes (one device, one graph): (x, y offset from the band, the lane nodes they join).
SHARED = [(93.5, -24, [(0, 1), (1, 0)]), (181.5, 26, [(1, 2), (2, 2), (2, 3)]), (237.5, -27, [(0, 3), (1, 2), (0, 4)])]


def hero_graph():
    nodes = []
    for lane, (colour, row, phase) in enumerate(LANES_HERO):
        nodes.append([])
        for x, weight in NODE_XS[lane]:
            t = (x - BAND_X0) / (BAND_X1 - BAND_X0)
            nodes[lane].append((x, strand_y(x, row, phase), max(2.2, 6.2 * weight * (1 - 1.4 * t)), max(0.35, 1 - 1.3 * t), colour))

    def line(xa, ya, xb, yb, opacity):
        return (f'<line x1="{xa:.1f}" y1="{ya:.1f}" x2="{xb:.1f}" y2="{yb:.1f}" stroke="#6a6862" stroke-width="1.3" '
                f'opacity="{opacity:.2f}"/>')

    edges, shared = [], []
    for (la, ia), (lb, ib) in CROSS:
        xa, ya, _, oa, _ = nodes[la][ia]
        xb, yb, _, ob, _ = nodes[lb][ib]
        edges.append(line(xa, ya, xb, yb, min(oa, ob) * 0.85))
    for x, dy, joins in SHARED:
        y = BAND_Y + dy
        o = max(0.35, 1 - 1.3 * (x - BAND_X0) / (BAND_X1 - BAND_X0))
        for lane, index in joins:
            nx, ny, *_ = nodes[lane][index]
            edges.append(line(x, y, nx, ny, o * 0.85))
        shared.append(f'<circle cx="{x}" cy="{y}" r="4.2" fill="#9b9991" stroke="#151513" stroke-width="2" opacity="{o:.2f}"/>')
    dots = "".join(
        f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{c}" stroke="#151513" stroke-width="2" opacity="{o:.2f}"/>'
        for lane in nodes for x, y, r, o, c in lane)
    return "".join(edges), dots + "".join(shared)


def hero(browser):
    strands = "".join(
        f'<path d="{strand_path(row, phase)}" fill="none" stroke="{colour}" stroke-width="3.6" stroke-linecap="round"/>'
        for colour, row, phase in LANES_HERO)
    edges, dots = hero_graph()
    hx, hy = INDEX_X, BAND_Y
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 46px; top: 52px; width: 72px; }}
.caption {{ position: absolute; left: 132px; top: 72px; letter-spacing: .3em; font-size: 16.5px; color: #8b8a84; font-variant-numeric: lining-nums; }}
.title {{ position: absolute; left: 34px; top: 112px; padding-left: 40px; font-size: 220px; line-height: 1; font-weight: 500; letter-spacing: .02em;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; padding-right: 30px; }}
.sub {{ position: absolute; left: 53.5px; top: 334px; font-size: 45px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.legend {{ position: absolute; left: 54.5px; top: 543px; width: 1061.5px; display: flex; gap: 32px; align-items: baseline; font-size: 24px; color: #8b8a84; }}
.legend b {{ font-weight: 400; color: #e9e7e0; }}
.dot {{ display: inline-block; width: 13px; height: 13px; border-radius: 50%; margin-right: 10px; transform: translateY(-1px); }}
.tag {{ margin-left: auto; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · AMBIENT INTELLIGENCE INDEX</div>
<svg width="1200" height="630">{edges}{strands}{dots}
  <line x1="{BAND_X1}" y1="{hy}" x2="{hx - 10}" y2="{hy}" stroke="{HERO_LINE}" stroke-width="3" stroke-linecap="round"/>
  <circle cx="{hx}" cy="{hy}" r="9.5" fill="#161614" stroke="{HERO_GOLD}" stroke-width="2.4"/>
  <circle cx="{hx}" cy="{hy}" r="4" fill="{HERO_GOLD}"/>
</svg>
<div class="title">AII</div>
<div class="sub">one index, a lane for every app</div>
<div class="legend">
  <span><i class="dot" style="background:{HERO_BLUE}"></i><b>Ambient</b> · text</span>
  <span><i class="dot" style="background:{HERO_GREEN}"></i><b>Craft</b> · code</span>
  <span><i class="dot" style="background:{HERO_ORANGE}"></i><b>Veil</b> · visuals</span>
  <span class="tag">graph and vectors, on-device, one install</span>
</div>
</body></html>"""
    shoot(browser, page, os.path.join(OUT, "hero.png"), viewport=(1200, 630))


# MARK: Shared sheet styles (Braid's legend and CLI guide)

REGION = ["#b197fc", "#4dabf7", "#69db7c", "#ffd43b", "#ff8787", "#38d9a9", "#ffa94d", "#91a7ff", "#c0eb75", "#f783ac"]

SHEET_CSS = f"""
html, body {{ margin: 0; background: {BG}; color: {FG}; font-family: {SANS}; }}
.sheet {{ padding: 36px 70px 40px 70px; width: 1150px; box-sizing: content-box; }}
h1 {{ font-size: 30px; margin: 0 0 4px 0; color: {WHITE}; font-weight: 700; }}
.lede {{ color: {DIM}; font-size: 17px; margin-bottom: 28px; }}
code, .mono {{ font-family: {MONO}; }}
.badge {{ position: absolute; width: 26px; height: 26px; border-radius: 50%; color: #111; font: normal 700 14px/26px {SANS}; text-align: center; z-index: 3; }}
.cols {{ display: flex; gap: 60px; margin-top: 34px; border-top: 1px solid #2a2a2a; padding-top: 26px; }}
.cols > div {{ flex: 1; }}
h2 {{ font-size: 21px; color: {WHITE}; margin: 0 0 16px 0; }}
ul {{ list-style: none; margin: 0; padding: 0; }}
.regions li {{ display: flex; gap: 14px; margin-bottom: 13px; }}
.regions i {{ flex: 0 0 26px; height: 26px; border-radius: 50%; color: #111; font: normal 700 14px/26px {SANS}; text-align: center; }}
.regions b {{ display: block; font-size: 17px; }}
.regions span, .marks span {{ color: #b9b6ae; font-size: 14.5px; line-height: 1.4; }}
.marks li {{ margin-bottom: 13px; }}
.marks .ex {{ display: block; font-family: {MONO}; font-size: 15px; margin-bottom: 3px; white-space: pre; }}
"""


def legend_columns(regions, marks, marks_title="Marks"):
    """Braid's two legend columns: numbered regions on the left, marks on the right."""
    left = "".join(
        f'<li><i style="background:{REGION[n - 1]}">{n}</i><div><b style="color:{REGION[n - 1]}">{html.escape(t)}</b>'
        f'<span>{d}</span></div></li>' for n, t, d in regions)
    right = "".join(f'<li><span class="ex">{example}</span><span>{meaning}</span></li>' for example, meaning in marks)
    return (f'<div class="cols"><div class="regions"><h2>Regions</h2><ul>{left}</ul></div>'
            f'<div class="marks"><h2>{marks_title}</h2><ul>{right}</ul></div></div>')


def badge(n, x, y):
    return f'<div class="badge" style="background:{REGION[n - 1]};left:{x}px;top:{y}px">{n}</div>'


# MARK: The stack

LANES = [("Ambient", "ambient", HERO_BLUE, "text"), ("Craft", "craft", HERO_GREEN, "code"), ("Veil", "veil", HERO_ORANGE, "visuals")]

STACK_REGIONS = [
    (1, "Apps", "each links <code>AII</code> by URL with <code>traits: []</code> and holds one <code>AIISupervisor</code>, "
                "or an <code>AIIInstance</code> that holds it; the first app up starts the stack, the rest adopt it"),
    (2, "The wire", "loopback only; every HTTP request and gRPC call carries the app's secret, and the secret that "
                    "matches names the caller and its lane"),
    (3, "AIIServer", "one binary, two roles, installed once per Mac: your own build (<code>aii install</code>) when "
                     "there is one, which every app keeps; else the newest app bundle's"),
    (4, "Sewn", "the models: chat and completions on device through MLX, retrieval from your lane, the personal layer, accounts"),
    (5, "Seam", "the gRPC contract between them: Thread registers with Sewn, Sewn queries Thread"),
    (6, "Thread", "the index: vectors and a knowledge graph in one store, one lane per app"),
    (7, "~/.rao", "the contract on disk: secrets, the device key, the lane registry, the binary, the data, the leases"),
    (8, "Models", "one copy of every pinned model for every app (<code>AIIModels</code>)"),
]

STACK_MARKS = [
    (f'<span style="color:{FG}">───</span> <span style="color:{DIM}">HTTP · WS</span>   '
     f'<span style="color:{FG}">─ ─</span> <span style="color:{DIM}">gRPC</span>',
     "how a call travels: Sewn answers HTTP and WebSocket, Thread answers gRPC (and HTTP for health and stats)"),
    ("".join(f'<i style="display:inline-block;width:34px;height:8px;border-radius:4px;background:{c};margin-right:8px"></i>'
             for c in (HERO_BLUE, HERO_GREEN, HERO_ORANGE))
     + '<i style="display:inline-block;width:34px;border-top:3px dashed #8a8a8a;transform:translateY(-3px)"></i>',
     "a lane per app: Ambient, Craft and Veil today; a dashed lane is the next app to join"),
    (f'<span style="color:{GOLD}">◉ proof</span>',
     "a launcher's challenge: the server answers an HMAC of a nonce, never the secret itself"),
    (f'<span style="color:{WHITE}">47080</span> <span style="color:{DIM}">/</span> <span style="color:{WHITE}">47091</span>   '
     f'<span style="color:{WHITE}">47081</span> <span style="color:{DIM}">/</span> <span style="color:{WHITE}">47090</span>',
     "Sewn HTTP / gRPC, Thread HTTP / gRPC: the same for every app (<code>AIIPortPlan</code>)"),
]


def stack(browser):
    apps = []
    for i, (name, _, colour, kind) in enumerate(LANES + [("Your app", "", MUTED, "next")]):
        x = i * 262
        dashed = "border-style:dashed;" if kind == "next" else ""
        role = "its own lane" if kind == "next" else kind
        holds = "AIIInstance" if kind == "next" else "AIISupervisor · Seam"
        apps.append(f'<div class="app" style="left:{x}px;--c:{colour};{dashed}"><b>{name}</b><em>{role}</em>'
                    f'<code>{holds}</code></div>'
                    f'<div class="drop" style="left:{x + 116}px"></div>')
    lanes = "".join(
        f'<div class="lane" style="--c:{c}"><span>{lane}</span><i></i></div>' for _, lane, c, _ in LANES)
    lanes += f'<div class="lane next"><span>your app</span><i></i></div>'
    chips = "".join(f'<span class="chip">{html.escape(c)}</span>' for c in [
        "secrets/", "keys/device.key", "aii/lanes.json", "aii/bin/", "aii/thread/db", "aii/sewn/db", "aii/leases/"])
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{SHEET_CSS}
.diagram {{ position: relative; width: 1010px; height: 640px; }}
.app {{ position: absolute; top: 0; width: 226px; height: 92px; box-sizing: border-box; border: 1px solid #2a2a2a; border-left: 4px solid var(--c);
        border-radius: 6px; background: #181818; padding: 12px 14px; }}
.app b {{ color: var(--c); font-size: 19px; }}
.app em {{ font-style: normal; color: {DIM}; font-size: 14px; margin-left: 8px; }}
.app code {{ display: block; margin-top: 16px; font-size: 13px; color: #b9b6ae; }}
.drop {{ position: absolute; top: 92px; width: 2px; height: 42px; background: #4a4a4a; }}
.bus {{ position: absolute; left: 0; top: 134px; width: 1010px; height: 36px; box-sizing: border-box; border: 1px solid #3a3a3a; border-radius: 18px;
        background: #191919; font: 13.5px/34px {MONO}; color: #b9b6ae; text-align: center; }}
.bus b {{ color: {WHITE}; font-weight: 400; }}
.frame {{ position: absolute; left: 0; top: 214px; width: 1010px; height: 250px; box-sizing: border-box; border: 1px dashed #3d3d3d; border-radius: 8px; }}
.frame > .label {{ position: absolute; left: 300px; top: -10px; background: {BG}; padding: 0 8px; font: 13.5px {MONO}; color: {DIM}; }}
.frame > .label b {{ color: {WHITE}; font-weight: 400; }}
.server {{ position: absolute; top: 30px; width: 400px; height: 196px; box-sizing: border-box; border: 1px solid #2a2a2a; border-radius: 6px; background: #181818; padding: 14px 18px; }}
.server h3 {{ margin: 0; font-size: 21px; color: {WHITE}; display: flex; align-items: baseline; gap: 12px; }}
.server h3 small {{ font: 13px {MONO}; color: {DIM}; }}
.server ul {{ margin-top: 12px; }}
.server li {{ font-size: 14.5px; color: #c9c6be; margin-bottom: 7px; }}
.server li code {{ font-size: 13px; color: {WHITE}; }}
.lane {{ display: flex; align-items: center; gap: 10px; margin: 0 0 7px 0; font: 13px {MONO}; color: #b9b6ae; }}
.lane span {{ width: 64px; }}
.lane i {{ flex: 1; height: 8px; border-radius: 4px; background: var(--c); opacity: .85; }}
.lane.next i {{ height: 0; background: none; border-top: 3px dashed #8a8a8a; opacity: 1; }}
.seam {{ position: absolute; left: 418px; top: 70px; width: 174px; text-align: center; font: 12.5px/1.45 {MONO}; color: #b9b6ae; }}
.seam b {{ display: block; font: 700 17px {SANS}; color: {WHITE}; margin-bottom: 6px; }}
.seam .arrow {{ display: block; color: {FG}; font-size: 15px; }}
.wire {{ position: absolute; top: 170px; width: 0; height: 74px; border-left: 2px solid #8a877f; }}
.wire.grpc {{ border-left-style: dashed; }}
.wire em {{ position: absolute; left: 10px; top: 22px; white-space: nowrap; font: 12.5px {MONO}; font-style: normal; color: {DIM}; }}
.home {{ position: absolute; left: 0; top: 504px; width: 1010px; height: 92px; box-sizing: border-box; border: 1px solid #2a2a2a; border-radius: 8px; background: #171717; padding: 14px 18px; }}
.home h3 {{ margin: 0 0 10px 0; font-size: 17px; color: {WHITE}; }}
.home h3 small {{ font: 13px {MONO}; color: {DIM}; margin-left: 10px; font-weight: 400; }}
.chip {{ display: inline-block; font: 12.5px {MONO}; color: #c9c6be; border: 1px solid #333; border-radius: 4px; padding: 3px 7px; margin: 0 5px 0 0; }}
.chip.models {{ border-color: {REGION[7]}; color: {REGION[7]}; margin-left: 30px; position: relative; }}
.chip.models .badge {{ left: -32px; top: -1px; }}
.down {{ position: absolute; left: 504px; top: 464px; height: 40px; border-left: 2px dotted #5a5a5a; }}
.diagram {{ height: 596px; }}
</style></head><body><div class="sheet" id="sheet">
<h1>The AII stack</h1>
<div class="lede">One install per Mac. Every app supervises the same two servers and reads and writes its own lane of one index.</div>
<div class="diagram">
  {"".join(apps)}
  <div class="bus">127.0.0.1 only · <b>X-Ambient-Secret</b> on every request and call · <span style="color:{GOLD}">◉</span> health is a challenge, never a secret</div>
  <div class="wire" style="left:208px"><em>HTTP · WS</em></div>
  <div class="wire grpc" style="left:800px"><em>gRPC</em></div>
  <div class="frame"><span class="label"><b>AIIServer</b> · one binary, two roles</span>
    <div class="server" style="left:18px">
      <h3>Sewn <small>HTTP/WS 47080 · gRPC 47091</small></h3>
      <ul>
        <li>chat and completions, OpenAI-shaped, streamed</li>
        <li>on-device MLX through SinatraHarness; Mistral or Tinker with a key</li>
        <li>the personal layer: memory, recap, a per-person steer</li>
        <li>vision, accounts, the Rao Verified records</li>
      </ul>
    </div>
    <div class="seam"><b>Seam</b><span class="arrow">◀──────</span>Thread registers<span class="arrow" style="margin-top:8px">──────▶</span>Sewn asks Thread</div>
    <div class="server" style="left:590px">
      <h3>Thread <small>HTTP 47081 · gRPC 47090</small></h3>
      <ul style="margin-bottom:12px">
        <li>vectors and a knowledge graph, one store</li>
      </ul>
      {lanes}
    </div>
  </div>
  <div class="down"></div>
  <div class="home"><h3>~/.rao <small>contract 1 · AIIHome</small></h3>{chips}<span class="chip models"><div class="badge" style="background:{REGION[7]}">8</div>models/huggingface/</span></div>
  {badge(1, -13, -13)}{badge(2, -13, 139)}{badge(3, 262, 201)}{badge(4, 5, 231)}{badge(5, 492, 260)}{badge(6, 577, 231)}{badge(7, -13, 491)}
</div>
{legend_columns(STACK_REGIONS, STACK_MARKS, "Marks")}
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "stack.png"), selector="#sheet", viewport=(1300, 1500), scale=2)


# MARK: The join guide (Braid's CLI guide)

JOIN_STEPS = [
    ("#b197fc", "Depend", "once, by URL, servers off",
     [('.package(url: "…/AII.git", branch: "main", traits: [])', "no MLX and no server code in your build"),
      ('.product(name: "AII", package: "AII")', "the foundation and the Join layer; Seam and gRPC come with it")]),
    ("#4dabf7", "Describe your lane", "AIIAppDescriptor, on a type of yours",
     [('static let app: AIIApp = "notes"', "any name of a-z and 0-9; the first app to register it owns it"),
      ("secrets/notes · aii/lanes.json · apps/notes/", "written by join(); the running servers admit it at once")]),
    ("#69db7c", "Describe your record", "AIIRecordable, on your own model",
     [("struct Note: AIIRecordable", "a kind, a group, an id, a title and the text to search; the rest is yours"),
      ("aii-record/1", "the envelope every lane files; your value rides in it and comes back whole")]),
    ("#ffd43b", "Join", "one AIIInstance per process",
     [("let aii = AIIInstance(Notes.self)", "the supervisor, the client and the wire, in one actor"),
      ("try await aii.join()", "registers the lane, installs a bundled helper, adopts or starts the stack, waits for proof")]),
    ("#ff8787", "Remember and recall", "Thread · gRPC 47090 · your lane",
     [("try await aii.remember(notes)", "filed under local-notes; searchable when it returns"),
      ("try await aii.recall(question, as: Note.self)", "the graph gates, vectors rank; your Notes come back as Notes")]),
    ("#38d9a9", "Ask", "Sewn · HTTP 47080 · on device or your key",
     [("for try await event in aii.ask(question)", "grounded in your lane and cited; no account needed"),
      ('try await aii.forget(groups: ["notes"])', "and forgetMemory() for what conversations taught it")]),
]


def join_guide(browser):
    cards = []
    for i, (colour, title, note, commands) in enumerate(JOIN_STEPS, 1):
        lines = "".join(f'<div class="cmd"><code>{html.escape(c)}</code><span>{html.escape(d)}</span></div>'
                        for c, d in commands)
        cards.append(f'<div class="card" style="--c:{colour}"><div class="head"><i>{i}</i><b>{title}</b><em>{note}</em></div>{lines}</div>')
    flow = " ".join(
        f'<span class="node" style="color:{c}">{t}</span>' + ('<span class="arrow">→</span>' if j < 4 else "")
        for j, (c, t) in enumerate([(FG, "your app"), (REGION[3], "AIIInstance"), (DIM, "~/.rao"),
                                    (GREEN, "Sewn + Thread"), (GOLD, "◉ your lane")]))
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
html, body {{ margin: 0; background: {BG}; color: {FG}; font-family: {SANS}; }}
.sheet {{ padding: 36px 44px 38px 44px; width: 1150px; }}
h1 {{ font-size: 30px; margin: 0 0 4px 0; color: {WHITE}; }}
.lede {{ color: {DIM}; font-size: 17px; margin-bottom: 18px; }}
.lede code {{ font-family: {MONO}; font-size: 15px; color: {FG}; }}
.flow {{ font-family: {MONO}; font-size: 15px; margin-bottom: 26px; padding: 12px 16px; border: 1px solid #262626; border-radius: 6px; display: inline-block; }}
.arrow {{ color: {MUTED}; margin: 0 10px; }}
.grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
.card {{ border: 1px solid #2a2a2a; border-left: 4px solid var(--c); border-radius: 6px; padding: 16px 18px 12px 18px; background: #181818; }}
.head {{ display: flex; align-items: baseline; gap: 12px; margin-bottom: 12px; }}
.head i {{ font: normal 700 14px/26px {SANS}; width: 26px; height: 26px; border-radius: 50%; background: var(--c); color: #111; text-align: center; flex: 0 0 26px; transform: translateY(-2px); }}
.head b {{ font-size: 19px; color: var(--c); white-space: nowrap; }}
.head em {{ font-style: normal; color: {DIM}; font-size: 14.5px; }}
.cmd {{ margin-bottom: 10px; }}
.cmd code {{ display: block; font-family: {MONO}; font-size: 13.5px; color: {WHITE}; white-space: pre; overflow: hidden; text-overflow: ellipsis; }}
.cmd > span {{ display: block; color: #b9b6ae; font-size: 14px; margin-top: 2px; padding-left: 2ch; }}
</style></head><body><div class="sheet" id="sheet">
<h1>Join the index</h1>
<div class="lede">From one dependency to an answer grounded in your own lane, in six steps. AII is on the Mac already (<code>aii install</code>, or any Rao app); the first app up starts it, every later app adopts it.</div>
<div class="flow">{flow}</div>
<div class="grid">{"".join(cards)}</div>
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "join-guide.png"), selector="#sheet", viewport=(1240, 1200), scale=2)


# MARK: Thread's search

SEARCH_REGIONS = [
    (1, "Your lane", "the secret on the call names the lane. The candidates are the owner's documents in it, a group's, "
                     "or with <code>scope: \"global\"</code> the shared ones too. Other lanes are never candidates"),
    (2, "Embed", "<code>query_text</code> through voyage-4-nano with the query role: 1024 dimensions, cached per query"),
    (3, "Match the graph", "entities by name from the query and <code>entities</code>; relationships by embedding "
                           "(a dot product of at least 0.15)"),
    (4, "Gate", "only documents linked to a matched relationship, else to a matched entity, are scanned. When nothing "
                "matched, nothing is cut. Code never gates: a matched identifier boosts instead"),
    (5, "Scan", "a product-quantized distance over 16 subvectors, the best 3 partitions of each document, in parallel"),
    (6, "Expand", "one hop from the matched entities and the hits' entities: neighbouring documents by summed edge "
                  "weight, the best partition of each, at ×1.1"),
    (7, "Rank", "one list by ascending distance, cut at <code>top_k</code>, with a trace of what the graph matched"),
]

SEARCH_MARKS = [
    (f'<svg width="120" height="18"><rect x="1" y="2" width="14" height="14" rx="3" fill="{HERO_BLUE}"/>'
     f'<rect x="26" y="2" width="14" height="14" rx="3" fill="none" stroke="#5a5a5a" stroke-width="1.5"/></svg>',
     "a document in your lane: scanned, or cut by the gate"),
    (f'<svg width="120" height="20"><circle cx="9" cy="10" r="7" fill="#2c2c2c" stroke="#8a8a8a" stroke-width="1.5"/>'
     f'<circle cx="36" cy="10" r="7" fill="#2c2c2c" stroke="{GOLD}" stroke-width="2.4"/></svg>',
     "an entity, merged by kind and name across lanes; a gold ring is one the query matched"),
    (f'<svg width="120" height="14"><line x1="2" y1="7" x2="50" y2="7" stroke="{GOLD}" stroke-width="3"/>'
     f'<line x1="66" y1="7" x2="114" y2="7" stroke="{GOLD}" stroke-width="2" stroke-dasharray="5 4"/></svg>',
     "a matched relationship; a one-hop expansion"),
    (f'<span style="color:{WHITE}">0.21</span>  <span style="color:{DIM}">score</span>',
     "a PQ distance: lower is closer, and results arrive in ascending order"),
    (f'<span style="color:{FG}">trace</span> <span style="color:{DIM}">matched_entity_names · expanded_document_count</span>',
     "why a result is there: what the graph matched and how many documents the hop added"),
]


def thread_search(browser):
    blue, dim = HERO_BLUE, "#5a5a5a"
    # Documents (x, y, state): "hit" scanned and ranked, "cut" removed by the gate, "hop" added by expansion.
    docs = {
        "d1": (300, 100, "hit"), "d2": (372, 100, "cut"), "d3": (444, 100, "hit"), "d4": (516, 100, "cut"), "d5": (588, 100, "hit"),
        "d6": (300, 330, "cut"), "d7": (372, 330, "hop"), "d8": (444, 330, "cut"), "d9": (516, 330, "hit"), "d10": (588, 330, "cut"),
    }
    # Entities (x, y, label, matched).
    ents = {"ada": (330, 215, "Ada", False), "jolt": (470, 215, "Joltvault", True), "port": (604, 215, "port 41027", False)}
    mentions = [("jolt", "d1"), ("jolt", "d3"), ("jolt", "d5"), ("ada", "d2"), ("ada", "d6"), ("ada", "d7"),
                ("jolt", "d9"), ("port", "d4"), ("port", "d10"), ("port", "d8"), ("ada", "d1")]
    lines = []
    for e, d in mentions:
        ex, ey = ents[e][:2]
        dx, dy = docs[d][:2]
        state = docs[d][2]
        if state == "hop":
            lines.append(f'<line x1="{ex}" y1="{ey}" x2="{dx}" y2="{dy}" stroke="{GOLD}" stroke-width="2" stroke-dasharray="5 4"/>')
        else:
            colour = "#6a6a6a" if state == "hit" else "#383838"
            lines.append(f'<line x1="{ex}" y1="{ey}" x2="{dx}" y2="{dy}" stroke="{colour}" stroke-width="1.4"/>')
    ax, ay = ents["ada"][:2]
    jx, jy = ents["jolt"][:2]
    lines.append(f'<line x1="{ax}" y1="{ay}" x2="{jx}" y2="{jy}" stroke="{GOLD}" stroke-width="3"/>')
    lines.append(f'<text x="{(ax + jx) / 2}" y="{ay - 9}" text-anchor="middle" font-family="Menlo" font-size="12" fill="{GOLD}">leads</text>')
    px, py = ents["port"][:2]
    lines.append(f'<line x1="{jx}" y1="{jy}" x2="{px}" y2="{py}" stroke="#4a4a4a" stroke-width="1.6"/>')
    lines.append(f'<text x="{(jx + px) / 2}" y="{jy - 9}" text-anchor="middle" font-family="Menlo" font-size="12" fill="{DIM}">listens on</text>')
    distances = {"d3": "0.21", "d1": "0.34", "d9": "0.38", "d5": "0.47", "d7": "0.52"}
    shapes = []
    for name, (x, y, state) in docs.items():
        if state == "hit":
            shapes.append(f'<rect x="{x - 13}" y="{y - 13}" width="26" height="26" rx="5" fill="{blue}"/>')
        elif state == "hop":
            shapes.append(f'<rect x="{x - 13}" y="{y - 13}" width="26" height="26" rx="5" fill="#34507e"/>'
                          f'<rect x="{x - 16}" y="{y - 16}" width="32" height="32" rx="7" fill="none" stroke="{GOLD}" stroke-width="2" stroke-dasharray="4 3"/>')
        else:
            shapes.append(f'<rect x="{x - 13}" y="{y - 13}" width="26" height="26" rx="5" fill="#161616" stroke="{dim}" stroke-width="1.5"/>')
        if name in distances:
            dy = -24 if y < 215 else 34
            shapes.append(f'<text x="{x}" y="{y + dy}" text-anchor="middle" font-family="Menlo" font-size="12.5" fill="{WHITE}">{distances[name]}</text>')
    for key, (x, y, label, matched) in ents.items():
        stroke, width = (GOLD, 2.6) if matched else ("#8a8a8a", 1.6)
        shapes.append(f'<circle cx="{x}" cy="{y}" r="11" fill="#262626" stroke="{stroke}" stroke-width="{width}"/>')
        shapes.append(f'<text x="{x}" y="{y + 32}" text-anchor="middle" font-family="-apple-system, Helvetica" font-size="13.5" '
                      f'fill="{GOLD if matched else FG}">{label}</text>')
    others = "".join(
        f'<rect x="{492 + i * 20}" y="374" width="13" height="13" rx="3" fill="{c}" opacity=".3"/>'
        for i, c in enumerate([HERO_GREEN, HERO_ORANGE, HERO_GREEN, HERO_GREEN, HERO_ORANGE, HERO_ORANGE, HERO_GREEN]))
    results = [("d3", "Joltvault runbook", "0.21", False), ("d1", "Stand-up, 15 Oct", "0.34", False),
               ("d9", "Health checks", "0.38", False), ("d5", "Release notes", "0.47", False), ("d7", "Ada's 1:1", "0.52", True)]
    rows = "".join(
        f'<div class="row{" hop" if hop else ""}"><span class="doc"></span><b>{html.escape(n)}</b><code>{dist}</code>'
        f'{"<em>+1 hop</em>" if hop else ""}</div>' for _, n, dist, hop in results)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{SHEET_CSS}
.diagram {{ position: relative; width: 1010px; height: 420px; }}
.query {{ position: absolute; left: 0; top: 46px; width: 214px; box-sizing: border-box; border: 1px solid #2a2a2a; border-left: 4px solid {REGION[1]};
          border-radius: 6px; background: #181818; padding: 12px 14px; }}
.query small {{ display: block; font: 12.5px {MONO}; color: {DIM}; margin-bottom: 6px; }}
.query code {{ font-size: 14.5px; color: {WHITE}; }}
.embed {{ position: absolute; left: 0; top: 170px; width: 214px; box-sizing: border-box; border: 1px solid #2a2a2a; border-radius: 6px; background: #181818;
          padding: 10px 14px; font: 12.5px/1.5 {MONO}; color: #b9b6ae; }}
.embed b {{ color: {WHITE}; font-weight: 400; }}
.lane {{ position: absolute; left: 252px; top: 0; width: 392px; height: 420px; box-sizing: border-box; border: 1px solid #2a2a2a; border-left: 4px solid {HERO_BLUE};
         border-radius: 8px; background: #161616; }}
.lane .label {{ position: absolute; left: 14px; top: 10px; font: 12.5px {MONO}; color: {HERO_BLUE}; }}
.lane .others {{ position: absolute; left: 14px; bottom: 34px; font: 12px {MONO}; color: {MUTED}; }}
svg.g {{ position: absolute; left: 0; top: 0; }}
.results {{ position: absolute; left: 690px; top: 46px; width: 320px; }}
.results h3 {{ margin: 0 0 10px 0; padding-left: 22px; font: 12.5px {MONO}; color: {DIM}; font-weight: 400; }}
.row {{ display: flex; align-items: center; gap: 10px; padding: 9px 12px; border: 1px solid #2a2a2a; border-radius: 6px; background: #181818; margin-bottom: 8px; }}
.row .doc {{ width: 14px; height: 14px; border-radius: 3px; background: {HERO_BLUE}; flex: 0 0 14px; }}
.row b {{ font-weight: 500; font-size: 14.5px; color: {FG}; flex: 1; }}
.row code {{ font-size: 13.5px; color: {WHITE}; }}
.row em {{ font-style: normal; font: 12px {MONO}; color: {GOLD}; }}
.row.hop {{ border-style: dashed; border-color: {GOLD}; }}
.row.hop .doc {{ background: #34507e; }}
.cut {{ border-top: 1px dashed #555; margin: 4px 0 10px 0; position: relative; }}
.cut span {{ position: absolute; right: 0; top: -9px; background: {BG}; padding-left: 8px; font: 12px {MONO}; color: {DIM}; }}
.arrow {{ position: absolute; font: 20px {SANS}; color: {MUTED}; }}
</style></head><body><div class="sheet" id="sheet">
<h1>How Thread answers a search</h1>
<div class="lede"><code style="color:{WHITE}">ThreadQuery.Search</code> on gRPC 47090: the graph narrows the field, a quantized scan ranks what is left, and one hop of the graph brings in the neighbours.</div>
<div class="diagram">
  <div class="query"><small>query_text</small><code>who leads Joltvault?</code></div>
  <div class="embed"><b>voyage-4-nano</b><br>query role · 1024-d</div>
  <div class="arrow" style="left:222px;top:72px">→</div>
  <div class="lane"><span class="label">your lane · ambient</span><span class="others">other lanes: never candidates</span></div>
  <svg class="g" width="1010" height="420">{"".join(lines)}{"".join(shapes)}{others}</svg>
  <div class="arrow" style="left:656px;top:72px">→</div>
  <div class="results"><h3>results · ascending distance</h3>{rows.replace('<div class="row hop">', '<div class="cut"><span>top_k = 4, then the hop</span></div><div class="row hop">')}</div>
  {badge(1, 239, -13)}{badge(2, -13, 157)}{badge(3, 448, 158)}{badge(4, 534, 112)}{badge(5, 470, 56)}{badge(6, 364, 258)}{badge(7, 677, 37)}
</div>
{legend_columns(SEARCH_REGIONS, SEARCH_MARKS)}
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "thread-search.png"), selector="#sheet", viewport=(1300, 1500), scale=2)


# MARK: A turn through Sewn

TURN_STEPS = [
    (1, "Admit", "<code>X-Ambient-Secret</code> names your app. No bearer → owner <code>local-&lt;app&gt;</code>, no account needed"),
    (2, "Retrieve", "Seam fans the last message out to Thread, stamped with your lane"),
    (3, "Compose", "your passages as \"you wrote\", the recap, a persona, <code>[[n]]</code> citations"),
    (4, "Generate", "on device: SinatraHarness steers sampling toward the passages. With a key: Mistral"),
    (5, "Stream", "SSE: references, tokens, contribution, Sinatra diagnostics, <code>[DONE]</code>"),
    (6, "Write back", "memories, resonant passages and the recap go back into your lane"),
]

TURN_MARKS = [
    (f'<span style="color:{GREEN}">● live</span>',
     "retrieval from your lane; auto-memory every 7th message or at a session boundary; resonant passages; "
     "the opt-in running recap; personas; the on-device SinatraHarness steer, trained per person"),
    (f'<span style="color:{MUTED}">○ planned</span>',
     "Marielle (open, proactive, interject, bridge) answers 503 today; the server-side GBT tone trains, but "
     "nothing applies it yet"),
    (f'<span style="color:{GOLD}">↺</span> <span style="color:{DIM}">the loop</span>',
     "what a turn writes back is retrieved by the next one: the index becomes the person's memory"),
    (f'<span style="color:{WHITE}">&lt;app&gt;-memory-&lt;owner&gt;</span> <span style="color:{WHITE}">&lt;app&gt;-resonance-&lt;owner&gt;</span>',
     "the Thread groups the personal layer writes, in the caller's lane like any other document; the recap is "
     "one memory record, &lt;app&gt;/memory/recap-&lt;owner&gt;"),
]


def sewn_turn(browser):
    cards = []
    for i, (n, title, text) in enumerate(TURN_STEPS):
        x = i * 172
        cards.append(f'<div class="step" style="left:{x}px;--c:{REGION[n - 1]}"><i>{n}</i><b>{title}</b><span>{text}</span></div>')
        if i < len(TURN_STEPS) - 1:
            cards.append(f'<div class="arrow" style="left:{x + 156}px">→</div>')
    groups = "".join(f'<span class="chip" style="{style}">{html.escape(t)}</span>' for t, style in [
        ("your documents", ""), ("<app>-memory-<owner>", f"border-color:{GREEN};color:{GREEN}"),
        ("<app>-resonance-<owner>", f"border-color:{GREEN};color:{GREEN}"), ("the recap", f"border-color:{GREEN};color:{GREEN}")])
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{SHEET_CSS}
.diagram {{ position: relative; width: 1010px; height: 384px; }}
.step {{ position: absolute; top: 0; width: 150px; height: 214px; box-sizing: border-box; border: 1px solid #2a2a2a; border-top: 4px solid var(--c);
         border-radius: 6px; background: #181818; padding: 14px 12px; }}
.step i {{ display: block; width: 26px; height: 26px; border-radius: 50%; background: var(--c); color: #111; font: normal 700 14px/26px {SANS}; text-align: center; margin-bottom: 10px; }}
.step b {{ display: block; color: var(--c); font-size: 18px; margin-bottom: 8px; }}
.step span {{ display: block; color: #c9c6be; font-size: 13.5px; line-height: 1.42; }}
.step code {{ font-size: 12px; color: {WHITE}; }}
.arrow {{ position: absolute; top: 92px; width: 16px; text-align: center; color: {MUTED}; font-size: 18px; }}
svg {{ position: absolute; left: 0; top: 0; }}
.lane {{ position: absolute; left: 0; top: 290px; width: 1010px; box-sizing: border-box; border: 1px solid #2a2a2a; border-left: 4px solid {HERO_BLUE};
         border-radius: 8px; background: #161616; padding: 14px 18px; }}
.lane h3 {{ margin: 0 0 10px 0; font-size: 17px; color: {WHITE}; }}
.lane h3 small {{ font: 13px {MONO}; color: {DIM}; font-weight: 400; margin-left: 10px; }}
.chip {{ display: inline-block; font: 12.5px {MONO}; color: #c9c6be; border: 1px solid #3a3a3a; border-radius: 4px; padding: 3px 8px; margin: 0 6px 0 0; }}
.steer {{ position: absolute; right: 18px; top: 16px; font: 12.5px {MONO}; color: {DIM}; text-align: right; }}
.steer b {{ color: {REGION[3]}; font-weight: 400; }}
.loop {{ position: absolute; left: 400px; top: 248px; font: 12.5px {MONO}; color: {GOLD}; background: {BG}; padding: 0 8px; }}
</style></head><body><div class="sheet" id="sheet">
<h1>A turn through Sewn</h1>
<div class="lede"><code style="color:{WHITE}">POST /v1/chat/completions</code> with <code style="color:{WHITE}">"provider": "local"</code>: your secret is enough, the context comes from your lane, and what the turn learns goes back into it.</div>
<div class="diagram">
  {"".join(cards)}
  <svg width="1010" height="420">
    <path d="M935,214 L935,262 Q935,272 925,272 L257,272 Q247,272 247,262 L247,222" fill="none" stroke="{GOLD}" stroke-width="2" stroke-dasharray="6 5"/>
    <path d="M241,228 L247,216 L253,228" fill="none" stroke="{GOLD}" stroke-width="2"/>
  </svg>
  <div class="loop">↺ the next turn retrieves what this one wrote</div>
  <div class="lane"><h3>Your lane <small>Thread · the documents Sewn reads and writes for you</small></h3>{groups}
    <div class="steer"><b>SinatraHarness</b> · a small net per person<br>learns which passages ground an answer</div></div>
</div>
{legend_columns([], TURN_MARKS, "What personalizes, today").replace('<div class="regions"><h2>Regions</h2><ul></ul></div>', '')}
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "sewn-turn.png"), selector="#sheet", viewport=(1300, 1500), scale=2)


# MARK: Seam's two paths

SEAM_REGIONS = [
    (1, "Apps", "call Thread directly as plain unary RPCs; <code>StackSecretClientInterceptor</code> adds the secret"),
    (2, "The direct path", "<code>ThreadQuery</code> · <code>ThreadLibrary</code> · <code>ThreadGraph</code> · "
                           "<code>ThreadUpdate</code> on Thread's own port. The secret picks the lane"),
    (3, "Thread", "the node: hosts the services and answers what arrives down the session through a "
                  "<code>SessionRequestHandling</code> dispatcher"),
    (4, "Registration", "<code>Register</code>, then a <code>Heartbeat</code> every 15 s on its own connection, so "
                        "liveness never queues behind a 100 MB push"),
    (5, "The session", "one bidirectional stream the node dials and holds open; many requests in flight, each "
                       "paired by <code>correlation_id</code>"),
    (6, "Sewn", "the mothership: <code>ThreadSessionManager</code> correlates, <code>ThreadQueryClient</code> fans "
                "out with the caller's lane stamped on each request"),
]

SEAM_MARKS = [
    (f'<span style="color:{FG}">───▶</span> <span style="color:{DIM}">dials</span>   '
     f'<span style="color:{REGION[4]}">═══</span> <span style="color:{DIM}">held open</span>   '
     f'<span style="color:{REGION[5]}">┄┄▶</span> <span style="color:{DIM}">pushed down</span>',
     "the TCP connection runs node → mothership; requests run mothership → node"),
    (f'<span style="color:{WHITE}">30 s</span> ping  <span style="color:{WHITE}">15 s</span> heartbeat  '
     f'<span style="color:{WHITE}">45 s</span> watchdog  <span style="color:{WHITE}">60 s</span> active',
     "in-stream ping, out-of-band heartbeat, the node's staleness watchdog (5 s reconnect), how long a node counts as active"),
    (f'<span style="color:{WHITE}">30</span> / <span style="color:{WHITE}">90</span> / <span style="color:{WHITE}">120 s</span>',
     "per-RPC timeouts on the session: interactive reads, library pages, index"),
    (f'<span style="color:{GOLD}">x-ambient-secret</span>',
     "on every RPC on both paths; loopback peers only. Thread's own registration uses the stack identity, <code>aii</code>"),
]


def seam_wire(browser):
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{SHEET_CSS}
.diagram {{ position: relative; width: 1010px; height: 420px; }}
.box {{ position: absolute; box-sizing: border-box; border: 1px solid #2a2a2a; border-radius: 6px; background: #181818; padding: 14px 16px; }}
.box h3 {{ margin: 0 0 4px 0; font-size: 20px; color: {WHITE}; }}
.box small {{ display: block; font: 12.5px {MONO}; color: {DIM}; margin-bottom: 10px; }}
.box li {{ font: 13px/1.6 {MONO}; color: #c9c6be; }}
svg {{ position: absolute; left: 0; top: 0; }}
.tag {{ position: absolute; font: 12.5px {MONO}; color: {DIM}; white-space: nowrap; }}
.env {{ position: absolute; left: 360px; top: 352px; width: 340px; box-sizing: border-box; border: 1px dashed {REGION[5]}; border-radius: 6px;
        padding: 8px 12px; font: 12.5px/1.55 {MONO}; color: #c9c6be; background: #151515; }}
.env b {{ color: {REGION[5]}; font-weight: 400; }}
</style></head><body><div class="sheet" id="sheet">
<h1>Seam: two ways to reach Thread</h1>
<div class="lede">One proto, two call paths. A caller on the same Mac calls Thread directly. A mothership cannot dial a node, so the node dials in and the work comes down the open stream.</div>
<div class="diagram">
  <div class="box" style="left:0;top:20px;width:250px;height:130px;border-left:4px solid {REGION[0]}">
    <h3>Apps</h3><small>Ambient · Craft · Veil</small>
    <ul><li>Thread_V1_ThreadQuery.Client</li><li>StackSecretClientInterceptor</li></ul></div>
  <div class="box" style="left:0;top:220px;width:250px;height:120px;border-left:4px solid {REGION[5]}">
    <h3>Sewn</h3><small>mothership · gRPC 47091</small>
    <ul><li>ThreadSessionManager</li><li>ThreadQueryClient</li></ul></div>
  <div class="box" style="left:760px;top:20px;width:250px;height:320px;border-left:4px solid {REGION[2]}">
    <h3>Thread</h3><small>node · gRPC 47090</small>
    <ul><li>ThreadQuery</li><li>ThreadLibrary</li><li>ThreadGraph</li><li>ThreadUpdate</li></ul>
    <small style="margin-top:58px">dials out with</small><ul><li>MothershipRegistrationClient</li></ul></div>
  <svg width="1010" height="420">
    <defs>
      <marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{FG}"/></marker>
      <marker id="b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{REGION[5]}"/></marker>
      <marker id="c" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{REGION[3]}"/></marker>
    </defs>
    <line x1="250" y1="84" x2="752" y2="84" stroke="{FG}" stroke-width="2" marker-end="url(#a)"/>
    <line x1="760" y1="246" x2="258" y2="246" stroke="{REGION[3]}" stroke-width="2" marker-end="url(#c)"/>
    <line x1="760" y1="282" x2="250" y2="282" stroke="{REGION[4]}" stroke-width="9" opacity=".5"/>
    <line x1="250" y1="322" x2="752" y2="322" stroke="{REGION[5]}" stroke-width="2" stroke-dasharray="6 5" marker-end="url(#b)"/>
    <line x1="525" y1="322" x2="525" y2="352" stroke="{REGION[5]}" stroke-width="1.5" stroke-dasharray="2 3"/>
  </svg>
  <span class="tag" style="left:306px;top:62px"><span style="color:{FG}">the direct path</span> · unary RPC · the app's secret picks its lane</span>
  <span class="tag" style="left:322px;top:224px;color:{REGION[3]}">Register · then Heartbeat every 15 s, its own connection</span>
  <span class="tag" style="left:322px;top:293px;color:{REGION[4]}">Session · dialled by Thread, held open</span>
  <span class="tag" style="left:560px;top:328px;color:{REGION[5]}">requests pushed down</span>
  <div class="env"><b>ThreadSessionMessage</b><br>correlation_id · search_request {{ lane }}</div>
  {badge(1, -13, 7)}{badge(2, 268, 71)}{badge(3, 747, 7)}{badge(4, 284, 233)}{badge(5, 284, 269)}{badge(6, -13, 207)}
</div>
{legend_columns(SEAM_REGIONS, SEAM_MARKS)}
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "seam-wire.png"), selector="#sheet", viewport=(1300, 1500), scale=2)


ALL = ["hero", "stack", "join_guide", "thread_search", "sewn_turn", "seam_wire"]


def main():
    targets = sys.argv[2:] or ALL
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        for target in targets:
            globals()[target](browser)
        browser.close()
    for name in (t.replace("_", "-") + ".png" for t in targets):
        path = os.path.join(OUT, name)
        with Image.open(path) as im:
            print(f"{name}: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
