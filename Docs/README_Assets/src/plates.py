"""Renders the README's plates in Braid's hero style (Braid/README_Assets/src/across.py): the stack's three
pieces, Thread from the inside, and one document's partition index.

    python3 -I Docs/README_Assets/src/plates.py Docs/README_Assets [target …]

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: sewn-thread-seam.png, thread-inside.png, partition-index.png in argv[1].

What each plate draws follows the code. The turn: Sewn's fan-out (SewnCore+ThreadFanout.swift) down the
session Thread dialed (MothershipRegistrationClient.swift), with ThreadQueryClient's timeouts. Thread:
ThreadQueryServiceImpl's index and search, Database, its two mutators and their files. The partition
index: PartitionIndex and PartitionQuantizer, 16 subvectors, k = the largest power of two at most n / 39,
an adaptive threshold of mean + 1.5σ of the training errors, at least 8.0. The partition index's codes and
distances are illustrative; its shapes and rules are the code's.
"""

import math
import os
import random
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# The hero's colours (build.py), and Braid's fourth for Thread.
BLUE, GREEN, ORANGE, GOLD, LINE, VIOLET = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0", "#a88bd6"
DIAL = "#8b8a84"
MONO = "Menlo, 'SF Mono', monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
W = 1600


# MARK: Marks (across.py's)

def arrowhead(x, y, direction, colour):
    if direction in ("up", "down"):
        d = 1 if direction == "up" else -1
        return (f'<path d="M{x - 7},{y + d * 9} L{x},{y} L{x + 7},{y + d * 9}" fill="none" stroke="{colour}" '
                f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
    d = 1 if direction == "left" else -1
    return (f'<path d="M{x + d * 9},{y - 7} L{x},{y} L{x + d * 9},{y + 7}" fill="none" stroke="{colour}" '
            f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')


def badge(x, y, n):
    return (f'<circle cx="{x}" cy="{y}" r="11" fill="#191917" stroke="{GOLD}" stroke-width="1.6"/>'
            f'<text x="{x}" y="{y + 4.6}" text-anchor="middle" font-family="{SANS}" font-size="{12 if n > 9 else 13}" '
            f'font-weight="600" fill="{GOLD}">{n}</text>')


def call(x0, x1, y, colour=GOLD):
    """A request: dashed, from x0 to x1."""
    return (f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{colour}" stroke-width="1.8" stroke-dasharray="6 5" stroke-linecap="round"/>'
            + arrowhead(x1, y, "right" if x1 > x0 else "left", colour))


def reply(x0, x1, y, colour, width=2.8):
    """A reply: solid, from x0 to x1."""
    return (f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{colour}" stroke-width="{width}" stroke-linecap="round"/>'
            + arrowhead(x1, y, "right" if x1 > x0 else "left", colour))


def dial(x0, x1, y):
    """A connection one side opens: thin, solid, grey."""
    return reply(x0, x1, y, DIAL, width=1.6)


def vertical(x, y0, y1, colour=GOLD, dashed=True):
    dash = ' stroke-dasharray="6 5"' if dashed else ""
    return (f'<line x1="{x}" y1="{y0}" x2="{x}" y2="{y1}" stroke="{colour}" stroke-width="1.8"{dash} stroke-linecap="round"/>'
            + arrowhead(x, y1, "down" if y1 > y0 else "up", colour))


def wire(x, y, text, colour="#a7a49b", anchor="left"):
    side = f"left:{x}px" if anchor == "left" else f"right:{W - x}px"
    return f'<div class="wire" style="{side}; top:{y}px; color:{colour}">{text}</div>'


def card(left, top, width, height, inner, cls=""):
    return (f'<div class="card {cls}" style="left:{left}px; top:{top}px; width:{width}px; height:{height}px">'
            f'{inner}</div>')


def head(name, colour, machine=""):
    dot = f'<i class="dot" style="background:{colour}"></i>' if colour else ""
    right = f'<span class="machine">{machine}</span>' if machine else ""
    return f'<div class="head"><span>{dot}<b>{name}</b></span>{right}</div>'


def step(*numbers):
    return "".join(f'<span class="step">{n}</span>' for n in numbers)


def steps(blocks, top):
    """The numbered calls under the diagram: one or two titled columns."""
    columns = []
    for title, rows in blocks:
        body = "".join(
            f'<div class="row">{f"<span class=step>{n}</span>" if n else "<span></span>"}<span>{text}</span><code>{code}</code></div>'
            for n, text, code in rows)
        columns.append(f'<div><div class="machine">{title}</div><div class="rows">{body}</div></div>')
    return f'<div class="steps" style="top:{top}px">{"".join(columns)}</div>'


# The header's rhythm, shared by Rao's plates: the mark's ink sits 70 px from the top and the left; every
# header line's ink starts at the mark's left edge (an italic first glyph overhangs by its own amount, so
# the page measures it); the title's ink starts 70 px under the mark's; what follows starts HEADER_GAP px
# under the subtitle's baseline, and the page grows or shrinks to keep its foot.
INK, TITLE_INK, HEADER_GAP = 70.5, 174, 54
HEADER_JS = """<script>
document.fonts.ready.then(() => {
  const ctx = document.createElement("canvas").getContext("2d");
  const measure = (el) => {
    const cs = getComputedStyle(el), text = el.textContent.trim();
    ctx.font = `italic ${cs.fontWeight} ${cs.fontSize} Playfair`;
    const probe = document.createElement("span");
    probe.style.cssText = "display:inline-block; width:0; height:0";
    el.prepend(probe);
    const baseline = probe.getBoundingClientRect().bottom;
    probe.remove();
    return {left: parseFloat(cs.paddingLeft), top: parseFloat(cs.top), baseline,
            ink: baseline - ctx.measureText(text).actualBoundingBoxAscent, overhang: ctx.measureText(text[0]).actualBoundingBoxLeft};
  };
  const title = document.querySelector(".title"), sub = document.querySelector(".sub");
  const t = measure(title), s = measure(sub), dy = __TITLE_INK__ - t.ink;
  for (const [el, m] of [[title, t], [sub, s]]) {
    el.style.left = (__INK__ - m.left + m.overhang) + "px";
    el.style.top = (m.top + dy) + "px";
  }
  const header = ".mark, .caption, .title, .sub, script, style", rest = [...document.body.children].filter((el) => !el.matches(header));
  let first = Infinity;
  for (const el of rest) {
    const r = el.getBoundingClientRect();
    if (el instanceof SVGSVGElement) {
      const b = el.getBBox();
      if (b.width || b.height) first = Math.min(first, r.top + b.y);
    } else if (r.width && r.height) first = Math.min(first, r.top);
  }
  const shift = Math.round(s.baseline + dy + __GAP__ - first);
  for (const el of rest) el.style.translate = `0 ${shift}px`;
  const height = parseFloat(getComputedStyle(document.body).height) + shift;
  document.documentElement.style.height = document.body.style.height = height + "px";
  document.body.dataset.height = height;
});
</script>""".replace("__INK__", str(INK)).replace("__TITLE_INK__", str(TITLE_INK)).replace("__GAP__", str(HEADER_GAP))


def plate(name, height, caption, title, sub, body, tag):
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {height}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97; font-variant-numeric: lining-nums;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 60px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 78px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 39.5px; padding-left: 40px; top: 162px; font-size: 104px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; white-space: nowrap; }}
.sub {{ position: absolute; left: 69px; top: 280px; font-size: 32px; color: #9b9991; white-space: nowrap; }}
svg {{ position: absolute; left: 0; top: 0; }}
.card {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.11); border-radius: 14px;
        background: rgba(255,255,255,.028); padding: 16px 20px; }}
.card.frame {{ border: 1px dashed rgba(255,255,255,.14); background: transparent; }}
.card.inner {{ padding: 12px 14px; }}
.card.optional {{ border-style: dashed; }}
.card p {{ margin: 8px 0 0; font-size: 17px; line-height: 1.3; color: #a29f97; }}
.card.inner p {{ margin-top: 5px; font-size: 15.5px; }}
.card b {{ font-weight: 400; color: #ecebe5; }}
.card h4 {{ margin: 16px 0 0; font-weight: 400; font-size: 19px; color: #e3e1da; display: flex; align-items: center; }}
.card h4 + p {{ margin-top: 4px; }}
.card code, .chip code {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #c3c0b7; }}
.head {{ display: flex; justify-content: space-between; align-items: baseline; }}
.head b {{ font-size: 26px; }}
.card.inner .head b {{ font-size: 21px; }}
.machine {{ font-size: 11.5px; letter-spacing: .22em; color: #77756f; white-space: nowrap; }}
.label {{ position: absolute; }}
.dot {{ display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 10px; transform: translateY(-2px); }}
.step {{ display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; margin-right: 9px; border: 1.6px solid {GOLD};
        border-radius: 50%; font-family: {SANS}; font-style: normal; font-weight: 600; font-size: 12px; color: {GOLD}; transform: translateY(-1px); flex: none; }}
.wire {{ position: absolute; font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #a7a49b; white-space: nowrap; }}
.lanes {{ display: grid; grid-template-columns: 74px 1fr; row-gap: 9px; align-items: center; margin-top: 14px; }}
.lanes span {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #a7a49b; }}
.lanes i {{ display: block; height: 5px; border-radius: 3px; }}
.chip {{ display: flex; flex-direction: column; margin-top: 11px; padding: 9px 12px; border: 1px solid rgba(255,255,255,.09); border-radius: 9px; }}
.chip code {{ font-size: 12.5px; color: #dcdad3; }}
.chip span {{ font-size: 15px; line-height: 1.28; margin-top: 3px; }}
.steps {{ position: absolute; left: 70px; width: 1460px; display: grid; grid-template-columns: 1fr 1fr; column-gap: 56px; }}
.steps .rows {{ margin-top: 8px; }}
.steps .row {{ display: grid; grid-template-columns: 30px 1fr auto; column-gap: 12px; align-items: center; padding: 8px 0;
              border-bottom: 1px solid rgba(255,255,255,.07); font-size: 17px; color: #a29f97; }}
.steps .row .step {{ margin: 0; }}
.steps code {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #a7a49b; white-space: nowrap; }}
.tag {{ position: absolute; right: 70px; top: {height - 52}px; font-size: 18px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">{caption}</div>
<div class="title">{title}</div>
<div class="sub">{sub}</div>
{body}
<div class="tag">{tag}</div>
{HEADER_JS}
</body></html>"""
    return name, height, page


# MARK: Sewn, Thread, Seam

APPS = dict(left=70, right=300, top=372, bottom=872)
APP_CARDS = [("Ambient", BLUE, "text · AIISupervisor"), ("Craft", GREEN, "code · AIISupervisor"),
             ("Veil", ORANGE, "visuals · AIISupervisor"), ("Your app", VIOLET, "its own lane · AIIInstance")]
SEWN = dict(left=430, right=860, top=372, bottom=800)
THREAD = dict(left=1110, right=1530, top=372, bottom=872)
TUBE = (520, 716)                                   # the session, top and bottom
REGISTER, HEARTBEAT = 432, 470
SEARCH, HITS, INDEX, INDEXED = 566, 598, 654, 686
ASK, TOKENS = 444, 482
DIRECT, RESULTS = 836, 858


def sewn_thread_seam():
    inner = APPS["right"] - 14
    s = []
    # Seam: the band between Sewn and Thread, which the direct path crosses too.
    s.append(f'<rect x="884" y="342" width="202" height="538" rx="12" fill="rgba(199,166,89,.035)" stroke="rgba(199,166,89,.22)" stroke-width="1" stroke-dasharray="3 5"/>')
    # Before any turn: Thread dials Sewn.
    s.append(dial(THREAD["left"], SEWN["right"] + 4, REGISTER))
    s.append(dial(THREAD["left"], SEWN["right"] + 4, HEARTBEAT))
    # The session: one stream, held open.
    for y in TUBE:
        s.append(f'<line x1="{SEWN["right"]}" y1="{y}" x2="{THREAD["left"]}" y2="{y}" stroke="#77756f" stroke-width="1.4"/>')
        s.append(f'<line x1="{SEWN["right"]}" y1="{y + 5 if y == TUBE[0] else y - 5}" x2="{THREAD["left"]}" y2="{y + 5 if y == TUBE[0] else y - 5}" stroke="#4a4944" stroke-width="1"/>')
    s.append(call(SEWN["right"], THREAD["left"] - 4, SEARCH))
    s.append(reply(THREAD["left"], SEWN["right"] + 4, HITS, VIOLET))
    s.append(call(SEWN["right"], THREAD["left"] - 4, INDEX))
    s.append(reply(THREAD["left"], SEWN["right"] + 4, INDEXED, VIOLET, width=2))
    s.append(badge(1076, SEARCH, 3))
    s.append(badge(1076, INDEX, 7))
    # An app and Sewn: the turn in, the tokens out.
    s.append(call(inner, SEWN["left"] - 4, ASK))
    s.append(f'<line x1="{SEWN["left"]}" y1="{TOKENS}" x2="{inner + 22}" y2="{TOKENS}" stroke="{LINE}" stroke-width="3" stroke-linecap="round"/>')
    s.append(f'<circle cx="{inner + 12}" cy="{TOKENS}" r="9.5" fill="#191917" stroke="{GOLD}" stroke-width="2.4"/>')
    s.append(f'<circle cx="{inner + 12}" cy="{TOKENS}" r="4" fill="{GOLD}"/>')
    s.append(badge(404, ASK, 1))
    s.append(badge(404, TOKENS, 6))
    # The direct path: under Sewn, through Seam, to Thread.
    s.append(call(inner, THREAD["left"] - 4, DIRECT))
    s.append(reply(THREAD["left"], inner + 4, RESULTS, VIOLET, width=2))

    apps = "".join(
        card(APPS["left"] + 14, 410 + i * 94, APPS["right"] - APPS["left"] - 28, 80,
             head(name, colour) + f'<p>{text}</p>', "inner" + (" optional" if name == "Your app" else ""))
        for i, (name, colour, text) in enumerate(APP_CARDS))
    sewn = card(SEWN["left"], SEWN["top"], SEWN["right"] - SEWN["left"], SEWN["bottom"] - SEWN["top"], f"""
  {head("Sewn", LINE, "HTTP/WS 47080 · gRPC 47091")}
  <p>the models and the personal layer; it keeps the conversation, never a vector</p>
  <h4>{step(2)}admit</h4>
  <p>the secret names your app, and your app its lane; with no bearer the owner is local-&lt;app&gt;</p>
  <h4>{step(5)}compose and generate</h4>
  <p>your passages as “you wrote”, a persona, citations; on device through SinatraHarness, or Mistral or Tinker with a key</p>
  <h4>{step(7)}write back</h4>
  <p>a memory every 7th message, a resonant passage, the recap: ordinary documents in your lane</p>""")
    lanes = "".join(f'<span>{lane}</span><i style="background:{colour}{"" if lane != "your app" else "; background: repeating-linear-gradient(90deg, #8b8a84 0 7px, transparent 7px 12px)"}"></i>'
                    for lane, colour in [("ambient", BLUE), ("craft", GREEN), ("veil", ORANGE), ("your app", "#8b8a84")])
    thread = card(THREAD["left"], THREAD["top"], THREAD["right"] - THREAD["left"], THREAD["bottom"] - THREAD["top"], f"""
  {head("Thread", VIOLET, "HTTP 47081 · gRPC 47090")}
  <p>the index: quantized vectors and a knowledge graph in one store, a lane for every app</p>
  <div class="lanes">{lanes}</div>
  <h4>the node</h4>
  <p>dials Sewn, registers as the stack’s own identity, and answers what comes down the session</p>
  <h4>{step(4)}search</h4>
  <p>the graph narrows the field, a PQ scan ranks it, one hop brings the neighbours</p>
  <h4>the direct path</h4>
  <p>apps call it as plain unary RPCs; the lane is the secret’s, never the request’s</p>""")
    labels = "".join([
        wire(SEWN["right"] + 16, REGISTER - 19, "Register", DIAL),
        wire(SEWN["right"] + 16, HEARTBEAT - 19, "Heartbeat · every 15 s", DIAL),
        wire(SEWN["right"] + 16, TUBE[0] - 22, "Session · held open", LINE),
        wire(SEWN["right"] + 16, SEARCH - 19, "Search · your lane", GOLD),
        wire(SEWN["right"] + 16, HITS - 19, "hits · correlated", VIOLET),
        wire(SEWN["right"] + 16, INDEX - 19, "Index · what it learned", GOLD),
        wire(SEWN["right"] + 16, INDEXED - 19, "indexed", VIOLET),
        wire(SEWN["right"] + 16, TUBE[1] + 8, "ping 30 s · watchdog 45 s", "#77756f"),
        wire(APPS["right"] + 12, ASK - 19, "chat", GOLD),
        wire(APPS["right"] + 22, TOKENS + 7, "tokens", LINE),
        wire(SEWN["left"] + 2, DIRECT - 20, "the direct path · ThreadQuery · Library · Graph · Update · unary, gRPC 47090", GOLD),
        wire(SEWN["left"] + 2, RESULTS + 5, "your lane’s answers", VIOLET),
        f'<div class="machine label" style="left:{APPS["left"] + 14}px; top:{APPS["top"] + 14}px">THIS MAC · THE APPS</div>',
        f'<div class="machine label" style="left:885px; width:200px; text-align:center; top:352px; color:{GOLD}">SEAM · THREAD.V1</div>',
    ])
    body = (card(APPS["left"], APPS["top"], APPS["right"] - APPS["left"], APPS["bottom"] - APPS["top"], "", "frame")
            + f'<svg width="{W}" height="1200">{"".join(s)}</svg>' + apps + sewn + thread + labels
            + steps([("ONE TURN · THREAD DIALED IN BEFORE IT, AND STAYS", [
                (1, "the app to Sewn: the turn, with its secret", "POST /v1/chat/completions"),
                (2, "Sewn admits: the secret names the app and its lane", ""),
                (3, "Sewn to Thread, down the session, stamped with the lane", "Search · 30 s"),
                (4, "Thread searches the lane; the hits go back up, correlated", ""),
            ]), ("&nbsp;", [
                (5, "Sewn composes and generates, on device or with a key", ""),
                (6, "Sewn to the app: tokens, references, each document’s share", "server-sent events"),
                (7, "Sewn to Thread: what the turn learned, filed in the lane", "Index · 120 s"),
            ])], 912))
    return plate("sewn-thread-seam.png", 1200, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE STACK",
                 "Sewn, Thread, Seam", "Sewn answers, Thread remembers; Seam is the one wire between them and every app",
                 body, "Seam is a library: Protos/thread.proto and the Swift made from it, one source for every side of the wire")


# MARK: Inside Thread

# What each store is drawn in, here and in the pipelines that read it.
STORE = {"registry": LINE, "graph": GREEN, "vectors": BLUE, "model": ORANGE, "-parts": DIAL}
FRAME = dict(left=300, right=1530, top=372, bottom=1052)
DOORS = dict(left=320, right=600, top=410, bottom=694)
MODELS = dict(left=320, right=600, top=736, bottom=1032)
DB = dict(left=680, right=1230, top=410, bottom=1032)
DISK = dict(left=1290, right=1510, top=410, bottom=1032)
REGISTRY = dict(left=700, right=1210, top=526, bottom=598)
TABLE = dict(left=700, right=1210, top=614, bottom=972)
GRAPH = dict(left=716, right=940, top=676, bottom=904)
VECTORS = dict(left=970, right=1194, top=676, bottom=904)
DISK_FILES = [
    ("registry-&lt;node&gt;", "registry", "who holds what, where"),
    ("table-&lt;node&gt;", "vectors", "every PQ index"),
    ("graph-&lt;node&gt;", "graph", "the entities and edges"),
    ("embedder-&lt;node&gt;", "model", "the model behind them"),
    ("documents/&lt;id&gt;", "-parts", "the document’s record"),
    ("documents/&lt;id&gt;-parts", "-parts", "text and url, for hits"),
]
PIPE_X, PIPE_W, PIPE_GAP, PIPE_H = 300, 190, 18, 172
PIPELINES = [
    ("FILING", "Index", "ThreadQuery.Index", [
        ("the lane", "from the secret, or the stamp Sewn set; an id or group of another lane is refused", ["registry"]),
        ("embed", "voyage-4-nano, document role: one 1024-d vector for each text", ["model"]),
        ("answer", "each item numbered in the order it came; Index replies now", []),
        ("the graph", "your entities, your tags, sym: identifiers for code, else Mistral-Nemo; edges embedded", ["model"]),
        ("the put", "in answer order: the registry links the owner, the group, the lane", ["registry"]),
        ("train and link", "the document’s PQ index; its entities and edges merged into the graph", ["vectors", "graph", "-parts"]),
    ]),
    ("FINDING", "Search", "ThreadQuery.Search", [
        ("embed the query", "query role, cached by its text", ["model"]),
        ("match the graph", "entities sharing a name token; edges whose embedding, or 0.8 × their predicate’s, scores ≥ 0.15", ["graph"]),
        ("gate", "the lane and the owner’s documents; prose keeps those linked to what matched, code is boosted", ["registry", "graph"]),
        ("scan", "each candidate’s PQ index in parallel: 16 lookups a partition, the best 3", ["vectors"]),
        ("one hop", "from the matches and the hits’ entities: neighbours by edge weight, their best partition × 1.1", ["graph", "vectors"]),
        ("rank", "one list by ascending distance, cut at top_k, with a trace of what matched", ["-parts"]),
    ]),
    ("WALKING", "the graph", "ThreadGraph.Query", [
        ("embed the text", "only when the query has text; an entity name is matched as written", ["model"]),
        ("match", "entities by name and kind; edges by meaning, seeded by those entities", ["graph"]),
        ("seed", "the matched entities, and both ends of every matched edge", ["graph"]),
        ("walk", "breadth first, 1 hop unless asked, 3 at most; every edge crossed is kept", ["graph"]),
        ("cut to the lane", "only documents the caller may see; with no name and no text, the lane’s most-mentioned entities", ["registry"]),
        ("answer", "entities with mentions, edges with weights, documents if asked; 20 unless asked", []),
    ]),
]


def store(name):
    return f'<span class="store" style="color:{STORE[name]}; border-color:{STORE[name]}55">{name}</span>'


def mini_graph():
    """Three entities and the edges between them, inside the graph's card."""
    nodes = {"Ada": (752, 742), "Joltvault": (838, 742), "port": (912, 790), "Babbage": (770, 806)}
    edges = [("Ada", "Joltvault", "leads"), ("Joltvault", "port", ""), ("Ada", "Babbage", "")]
    out = []
    for a, b, label in edges:
        (xa, ya), (xb, yb) = nodes[a], nodes[b]
        out.append(f'<line x1="{xa}" y1="{ya}" x2="{xb}" y2="{yb}" stroke="{GREEN}" stroke-width="1.6" opacity=".7"/>')
        if label:
            out.append(f'<text x="{(xa + xb) / 2 - 12}" y="{ya - 7}" text-anchor="middle" font-family="{MONO}" font-size="10.5" fill="{GREEN}">{label}</text>')
    for name, (x, y) in nodes.items():
        out.append(f'<circle cx="{x}" cy="{y}" r="6.5" fill="#191917" stroke="{GREEN}" stroke-width="1.8"/>')
        out.append(f'<text x="{x}" y="{y - 12 if name == "Joltvault" else y + 20}" text-anchor="middle" font-family="{MONO}" font-size="10.5" fill="#a7a49b">{name}</text>')
    return "".join(out)


def mini_codes():
    """Two documents' indices, sixteen codes a partition, inside the vectors' card."""
    rng = random.Random(16)
    out = []
    x0, cell = VECTORS["left"] + 16, 11.5
    for doc, (y0, rows) in enumerate([(740, 3), (796, 2)]):
        out.append(f'<text x="{x0}" y="{y0 - 6}" font-family="{MONO}" font-size="10.5" fill="#a7a49b">doc {doc + 1}</text>')
        for r in range(rows):
            for i in range(16):
                level = int(48 + rng.random() * 70)
                out.append(f'<rect x="{x0 + i * cell}" y="{y0 + r * 13}" width="{cell - 2}" height="10" rx="2" '
                           f'fill="rgb({level - 18},{level},{level + 40})" opacity=".85"/>')
    return "".join(out)


def pipeline(row, top, title, verb, rpc, stages):
    cards, arrows = [], []
    for i, (name, text, stores) in enumerate(stages):
        x = PIPE_X + i * (PIPE_W + PIPE_GAP)
        chips = "".join(store(s) for s in stores)
        cards.append(f'<div class="stage" style="left:{x}px; top:{top}px; width:{PIPE_W}px; height:{PIPE_H}px">'
                     f'<h5><span class="step">{i + 1}</span>{name}</h5><p>{text}</p><div class="stores">{chips}</div></div>')
        if i < len(stages) - 1:
            arrows.append(reply(x + PIPE_W + 3, x + PIPE_W + PIPE_GAP - 3, top + PIPE_H / 2, DIAL, width=1.4))
    label = (f'<div class="label" style="left:70px; top:{top + 4}px; width:210px">'
             f'<div class="machine">{title}</div><div class="verb">{verb}</div><code class="rpc">{rpc}</code></div>')
    return label + "".join(cards), "".join(arrows)


def thread_inside():
    s = []
    # Callers to the doors.
    s.append(call(250, DOORS["left"] - 4, 470))
    s.append(call(250, DOORS["left"] - 4, 616))
    # The doors to the Database: filing, finding, walking.
    s.append(call(DOORS["right"], DB["left"] - 4, 470))
    s.append(call(DOORS["right"], DB["left"] - 4, 548, LINE))
    s.append(reply(DB["left"], DOORS["right"] + 4, 574, VIOLET))
    s.append(call(DOORS["right"], DB["left"] - 4, 636, LINE))
    s.append(reply(DB["left"], DOORS["right"] + 4, 662, VIOLET))
    # The doors and the models; extraction reaches the put later.
    s.append(vertical(400, DOORS["bottom"], MODELS["top"] - 4))
    s.append(call(MODELS["right"], DB["left"] - 4, 840))
    # Inside the table: an index names its entities, an entity its documents.
    mid = (GRAPH["top"] + GRAPH["bottom"]) / 2
    s.append(f'<line x1="{GRAPH["right"] + 6}" y1="{mid}" x2="{VECTORS["left"] - 6}" y2="{mid}" stroke="#77756f" stroke-width="1.4"/>')
    s.append(arrowhead(GRAPH["right"] + 6, mid, "left", "#77756f") + arrowhead(VECTORS["left"] - 6, mid, "right", "#77756f"))
    s.append(mini_graph())
    s.append(mini_codes())
    # The stores to their files.
    for y, colour in ((532, LINE), (598, BLUE), (664, GREEN)):
        s.append(reply(DB["right"], DISK["left"] - 4, y, colour, width=1.6))

    doors = card(DOORS["left"], DOORS["top"], DOORS["right"] - DOORS["left"], DOORS["bottom"] - DOORS["top"], f"""
  {head("The doors", "")}
  <h4>the lane</h4>
  <p>from the secret that matched, or the stamp Sewn set; never from the request</p>
  <h4>gRPC 47090 · HTTP 47081</h4>
  <p><code>ThreadQuery · Library · Graph · Update</code>, and the session</p>""")
    models = card(MODELS["left"], MODELS["top"], MODELS["right"] - MODELS["left"], MODELS["bottom"] - MODELS["top"], f"""
  {head("The models", ORANGE)}
  <h4>voyage-4-nano</h4>
  <p>1024-d, on device through MLX; a document role and a query role</p>
  <h4>Mistral-Nemo</h4>
  <p>entities and relationships from text, after Index has answered</p>""")
    db = card(DB["left"], DB["top"], DB["right"] - DB["left"], DB["bottom"] - DB["top"], f"""
  {head("Database", VIOLET, "AN ACTOR")}
  <p>writes queue and apply in the order Index answered; reads take a snapshot and never wait</p>
  <p style="position:absolute; left:20px; right:20px; bottom:16px">the graph and the vectors change together and save together, within 1 s</p>""")
    registry = card(REGISTRY["left"], REGISTRY["top"], REGISTRY["right"] - REGISTRY["left"], REGISTRY["bottom"] - REGISTRY["top"],
                    head("the registry", LINE) + "<p>owners, groups, lanes, access; a document is in one lane for life</p>", "inner")
    table = card(TABLE["left"], TABLE["top"], TABLE["right"] - TABLE["left"], TABLE["bottom"] - TABLE["top"],
                 head("the partition table", "#e3e1da", "ONE STORE, TWO VIEWS")
                 + f'<p style="position:absolute; left:16px; right:16px; bottom:12px; text-align:center">an index names its document’s entities; an entity or an edge names its documents</p>',
                 "inner nest")
    graph = card(GRAPH["left"], GRAPH["top"], GRAPH["right"] - GRAPH["left"], GRAPH["bottom"] - GRAPH["top"],
                 head("the graph", GREEN) + '<p style="margin-top:118px">entities by kind and name; edges with a weight and an embedding; predicates</p>', "inner")
    vectors = card(VECTORS["left"], VECTORS["top"], VECTORS["right"] - VECTORS["left"], VECTORS["bottom"] - VECTORS["top"],
                   head("the vectors", BLUE) + '<p style="margin-top:118px">a PQ index per document: its codebooks, sixteen codes a partition</p>', "inner")
    disk = card(DISK["left"], DISK["top"], DISK["right"] - DISK["left"], DISK["bottom"] - DISK["top"],
                head("On disk", "") + "<p><code>~/.rao/aii/thread/db</code></p>"
                + "".join(f'<div class="chip"><code style="color:{STORE[kind]}">{name}</code><span>{text}</span></div>'
                          for name, kind, text in DISK_FILES))
    callers = (card(70, 420, 180, 104, head("Apps", BLUE) + "<p>unary RPCs, the secret on every call</p>", "inner")
               + card(70, 566, 180, 104, head("Sewn", LINE) + "<p>down the session, the caller’s lane stamped</p>", "inner"))
    labels = "".join([
        wire(256, 470 - 19, "direct", GOLD),
        wire(256, 616 - 19, "session", GOLD),
        wire(DOORS["right"] + 12, 470 - 19, "Index", GOLD),
        wire(DOORS["right"] + 12, 548 - 19, "Search", LINE),
        wire(DOORS["right"] + 12, 574 + 5, "hits", VIOLET),
        wire(DOORS["right"] + 12, 636 - 19, "Query", LINE),
        wire(DOORS["right"] + 12, 662 + 5, "the walk", VIOLET),
        wire(412, DOORS["bottom"] + 12, "embed", GOLD),
        wire(MODELS["right"] + 12, 840 - 19, "graph", GOLD),
        wire(MODELS["right"] + 12, 840 + 5, "later", "#77756f"),
        f'<div class="machine label" style="left:{FRAME["left"] + 18}px; top:{FRAME["top"] + 13}px">THREAD · AIISERVER THREAD · ONE PER MAC</div>',
    ])
    rows, arrows = [], []
    for row, (title, verb, rpc, stages) in enumerate(PIPELINES):
        cards, lines = pipeline(row, 1128 + row * (PIPE_H + 34), title, verb, rpc, stages)
        rows.append(cards)
        arrows.append(lines)
    legend = (f'<div class="label legend" style="left:70px; top:1092px">'
              f'<span class="machine">THREE WAYS IN · WHAT EACH STEP READS OR WRITES</span>'
              + "".join(store(name) for name in STORE) + '</div>')
    css = f"""<style>
.card.nest {{ background: rgba(255,255,255,.018); border-style: dashed; }}
.stage {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.1); border-radius: 12px; background: rgba(255,255,255,.028); padding: 12px 14px; }}
.stage h5 {{ margin: 0; font-weight: 400; font-size: 18px; color: #e3e1da; display: flex; align-items: center; }}
.stage p {{ margin: 6px 0 0; font-size: 14.5px; line-height: 1.3; color: #a29f97; }}
.stages, .stores {{ position: absolute; left: 14px; bottom: 11px; display: flex; gap: 5px; }}
.store {{ font-family: {MONO}; font-style: normal; font-size: 10.5px; border: 1px solid; border-radius: 4px; padding: 1px 6px; }}
.legend {{ display: flex; gap: 8px; align-items: center; }}
.legend .machine {{ margin-right: 8px; }}
.verb {{ font-size: 30px; color: #ecebe5; margin-top: 4px; }}
.rpc {{ font-family: {MONO}; font-style: normal; font-size: 12px; color: #8b8a84; }}
</style>"""
    height = 1128 + 3 * (PIPE_H + 34) + 48
    body = (css + card(FRAME["left"], FRAME["top"], FRAME["right"] - FRAME["left"], FRAME["bottom"] - FRAME["top"], "", "frame")
            + callers + doors + models + db + registry + table + graph + vectors + disk
            + f'<svg width="{W}" height="{height}">{"".join(s)}{"".join(arrows)}</svg>' + labels + legend + "".join(rows))
    return plate("thread-inside.png", height, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THREAD",
                 "Inside Thread", "one process, one store: the lane comes from the secret, the graph decides, the vectors rank",
                 body, "no HNSW, no shards, no WAL: debounced full-file saves and a sweep at start")


# MARK: The partition index

CELL_W, CELL_H, SUBVECTORS, K = 36, 24, 16, 4
SLICE = 2                                                   # the slice each band follows: dimensions 129–192
CODES = [2, 0, 1, 1, 1, 2, 0, 3, 2, 1, 0, 0, 3, 1, 2, 1]   # p₁'s centroid in each codebook
PARTITIONS = [("p₁", "Ada leads Joltvault; on-call rotates weekly…"), ("p₂", "Deploys go out on Tuesdays, behind a flag…"),
              ("p₃", "The health port is 41027; it answers a nonce…")]


def shade(value, lo=0.0, hi=1.0):
    t = max(0.0, min(1.0, (value - lo) / (hi - lo)))
    level = int(44 + t * 46)
    return f"rgb({level},{level - 1},{level - 4})"


def strip(x, y, values, h=16, w=CELL_W, outline=None, mark=None):
    """A 1024-d vector as its 16 subvectors, each shaded by a stand-in value; `mark` outlines one slice."""
    cells = "".join(
        f'<rect x="{x + i * w + 1}" y="{y}" width="{w - 2}" height="{h}" rx="2.5" fill="{shade(v)}"/>'
        for i, v in enumerate(values))
    if outline:
        cells += f'<rect x="{x - 3}" y="{y - 3}" width="{len(values) * w + 6}" height="{h + 6}" rx="5" fill="none" stroke="{outline}" stroke-width="1.2" opacity=".55"/>'
    if mark is not None:
        cells += f'<rect x="{x + mark * w - 1}" y="{y - 3}" width="{w + 2}" height="{h + 6}" rx="4" fill="none" stroke="{GOLD}" stroke-width="1.8"/>'
    return cells


def grid(x, y, fill, path=None, text=None):
    """16 codebooks of K centroids, one column each; `path` outlines one centroid per column."""
    out = []
    for i in range(SUBVECTORS):
        for j in range(K):
            cx, cy = x + i * CELL_W + 1, y + j * CELL_H + 1
            out.append(f'<rect x="{cx}" y="{cy}" width="{CELL_W - 2}" height="{CELL_H - 2}" rx="3" fill="{fill(i, j)}"/>')
            if text:
                picked = path is not None and path[i] == j
                out.append(f'<text x="{cx + (CELL_W - 2) / 2}" y="{cy + 15.5}" text-anchor="middle" font-family="{MONO}" '
                           f'font-size="10" fill="{GOLD if picked else "#8f8c84"}">{text(i, j)}</text>')
    if path:
        for i, j in enumerate(path):
            out.append(f'<rect x="{x + i * CELL_W + 0.5}" y="{y + j * CELL_H + 0.5}" width="{CELL_W - 1}" height="{CELL_H - 1}" rx="3.5" '
                       f'fill="none" stroke="{GOLD}" stroke-width="1.8"/>')
    return "".join(out)


def codes_row(x, y, codes, mark=None):
    out = []
    for i, code in enumerate(codes):
        cx = x + i * CELL_W + 1
        strong = mark is None or mark == i
        out.append(f'<rect x="{cx}" y="{y}" width="{CELL_W - 2}" height="26" rx="4" fill="#191917" stroke="{GOLD}" '
                   f'stroke-width="{1.8 if mark == i else 1.2}" opacity="{1 if strong else .55}"/>')
        out.append(f'<text x="{cx + (CELL_W - 2) / 2}" y="{y + 17.5}" text-anchor="middle" font-family="{MONO}" font-size="13" '
                   f'fill="{GOLD}" opacity="{1 if strong else .6}">{code}</text>')
    return "".join(out)


def dotted(x0, y0, x1, y1, colour=GOLD, opacity=.6):
    return (f'<line x1="{x0}" y1="{y0}" x2="{x1}" y2="{y1}" stroke="{colour}" stroke-width="1.2" stroke-dasharray="2 4" '
            f'opacity="{opacity}" stroke-linecap="round"/>')


def partition_index_body():
    rng = random.Random(1024)
    vector = lambda: [rng.random() for _ in range(SUBVECTORS)]
    # The query's distance to each centroid; p₁'s path runs low, as a near partition's would.
    table = [[round(rng.uniform(0.16, 0.38), 2) for _ in range(K)] for _ in range(SUBVECTORS)]
    for i, j in enumerate(CODES):
        table[i][j] = round(rng.uniform(0.08, 0.2), 2)
    distance = sum(table[i][j] for i, j in enumerate(CODES))
    s, labels = [], []
    axis = lambda x, y, text, colour="#77756f": labels.append(wire(x, y, text, colour))

    # 1 · A document becomes sixteen codebooks.
    mx, cw = 420, 30                                       # one vector per partition, cut into slices
    rows = [474, 508, 542, 600]
    for (name, text), y in zip(PARTITIONS + [("p₁₆₀", "…the last paragraph of the runbook")], rows):
        labels.append(f'<div class="ptext" style="left:96px; top:{y}px"><b>{name}</b> {text}</div>')
        s.append(strip(mx, y + 4, vector(), h=18, w=cw))
    labels.append(f'<div class="wire" style="left:220px; top:570px; color:#77756f">⋮</div><div class="wire" style="left:{mx + 232}px; top:570px; color:#77756f">⋮</div>')
    s.append(reply(352, mx - 8, 521, DIAL, width=1.4))
    axis(354, 500, "embed", GOLD)
    s.append(f'<rect x="{mx + SLICE * cw - 2}" y="464" width="{cw + 4}" height="{rows[-1] + 30 - 464}" rx="5" fill="rgba(199,166,89,.08)" stroke="{GOLD}" stroke-width="1.8"/>')
    axis(mx, 444, "1–64")
    axis(mx + SLICE * cw - 8, 444, "129–192", GOLD)
    axis(mx + 15 * cw - 30, 444, "961–1024")
    # k-means on that one slice of every partition, into codebook 3.
    cx = mx + SLICE * cw + cw / 2
    s.append(f'<path d="M{cx},{rows[-1] + 30} L{cx},658 L1056,658 L1056,{486 + 3 * 28 + 30}" fill="none" stroke="{GOLD}" stroke-width="1.8" stroke-dasharray="6 5"/>')
    s.append(arrowhead(1056, 486 + 3 * 28 + 26, "up", GOLD))
    axis(mx + 110, 664, "k-means on slice 3 of all 160 partitions, together · k = 4", GOLD)
    centroid = [[rng.random() for _ in range(8)] for _ in range(K)]
    axis(996, 460, "codebook 3 · 4 × 64-d", GOLD)
    for j in range(K):
        s.append(strip(1000, 486 + j * 28, centroid[j], h=18, w=14))
        axis(976, 486 + j * 28 + 1, f"c{'₀₁₂₃'[j]}")
    s.append(reply(1124, 1162, 546, DIAL, width=1.4))
    axis(1126, 524, "×16")
    axis(1176, 460, "sixteen codebooks, one per slice")
    for i in range(SUBVECTORS):
        for j in range(K):
            fill = f"rgba(199,166,89,{.25 + .1 * j})" if i == SLICE else shade(rng.random())
            s.append(f'<rect x="{1178 + i * 20}" y="{490 + j * 24}" width="16" height="20" rx="3" fill="{fill}"/>')
    s.append(f'<rect x="{1176 + SLICE * 20}" y="487" width="20" height="{K * 24 + 2}" rx="4" fill="none" stroke="{GOLD}" stroke-width="1.6"/>')
    axis(1176, 602, "the document’s, shared by all 160")

    # 2 · One partition becomes sixteen codes, and what they stand for.
    # Column 3 of the pin board, from the side: each row's pin where its slice would put it, the notches
    # where the pins bunch up, and each pin sliding to its nearest.
    bx0, by0, bw, bh = 104, 884, 440, 230
    plate_x, x0, x1 = bx0 + 6, bx0 + 40, bx0 + bw - 6
    centres = [0.14, 0.4, 0.63, 0.88]
    rows = 15
    depths = [min(.98, max(.02, centres[r % 4] + rng.gauss(0, .055))) for r in range(rows)]
    depths[4] = centres[1] - 0.085                                   # p₁, a little short of notch 1
    notch = [sum(d for r, d in enumerate(depths) if r % 4 == j) / len([r for r in range(rows) if r % 4 == j]) for j in range(4)]
    X = lambda d: x0 + d * (x1 - x0)
    s.append(f'<rect x="{bx0 - 8}" y="{by0 - 8}" width="{bw + 16}" height="{bh + 16}" rx="10" fill="rgba(0,0,0,.12)" stroke="rgba(255,255,255,.07)"/>')
    s.append(f'<rect x="{plate_x}" y="{by0 + 2}" width="12" height="{bh - 4}" rx="3" fill="#0d0d0c" stroke="#3a3936"/>')
    for j, d in enumerate(notch):
        s.append(f'<line x1="{X(d):.1f}" y1="{by0 + 6}" x2="{X(d):.1f}" y2="{by0 + bh - 6}" stroke="{GOLD}" stroke-width="1.2" stroke-dasharray="3 4" opacity=".7"/>')
        s.append(f'<text x="{X(d):.1f}" y="{by0 - 12}" text-anchor="middle" font-family="{MONO}" font-size="11" fill="{GOLD}">{j}</text>')
    step_y = (bh - 20) / (rows - 1)
    for r, d in enumerate(depths):
        y = by0 + 10 + r * step_y
        j = min(range(4), key=lambda n: abs(notch[n] - d))
        p1 = r == 4
        s.append(f'<line x1="{plate_x + 12}" y1="{y:.1f}" x2="{X(d):.1f}" y2="{y:.1f}" stroke="{"#9a9ca1" if p1 else "#55575b"}" stroke-width="{1.8 if p1 else 1.2}"/>')
        s.append(f'<line x1="{X(d):.1f}" y1="{y:.1f}" x2="{X(notch[j]):.1f}" y2="{y:.1f}" stroke="{GOLD}" stroke-width="{1.8 if p1 else 1}" opacity="{1 if p1 else .55}"/>')
        s.append(f'<circle cx="{X(d):.1f}" cy="{y:.1f}" r="{5 if p1 else 3.4}" fill="{LINE if p1 else "#7d7b74"}"/>')
        s.append(f'<circle cx="{X(notch[j]):.1f}" cy="{y:.1f}" r="{6.5 if p1 else 4.2}" fill="none" stroke="{GOLD}" stroke-width="{1.8 if p1 else 1.1}"/>')
        if p1:
            labels.append(wire(X(notch[j]) + 12, y - 9, "p₁ → notch 1", GOLD))
    axis(bx0 - 8, 834, "column 3 of the board, from the side: one pin a row")
    labels.append(f'<div class="caption2 small" style="left:96px; top:{by0 + bh + 18}px; width:460px">k-means cuts the notches where this column’s pins bunch up; each pin then slides to the nearest. Drawn as one depth; a real slice is 64 numbers.</div>')
    # p₁, its codes, and the vector the codes stand for.
    rx = 600
    v1 = vector()
    approx = [min(1, max(0, v + rng.uniform(-.09, .09))) for v in v1]
    axis(rx, 850, "p₁’s vector · 1024 floats · 4 KB", LINE)
    s.append(strip(rx, 874, v1, h=20, mark=SLICE))
    rsx = rx + SLICE * CELL_W + CELL_W / 2
    s.append(dotted(rsx, 898, rsx, 941))
    axis(rsx + 12, 910, "each slice to its nearest centroid: its notch", GOLD)
    s.append(codes_row(rx, 944, CODES, mark=SLICE))
    axis(rx + SUBVECTORS * CELL_W + 12, 948, "32 bytes", GOLD)
    s.append(dotted(rsx, 974, rsx, 1011))
    axis(rsx + 12, 980, "each code back to its centroid")
    s.append(strip(rx, 1014, approx, h=20, mark=SLICE))
    axis(rx, 1042, "p̂₁ · what the codes stand for: p₁ rebuilt from sixteen centroids", LINE)
    s.append(reply(bx0 + bw + 12, rx - 8, 957, GOLD, width=1.4))
    axis(bx0 + bw + 16, 935, "code 1", GOLD)
    labels.append(f'<div class="caption2 small" style="left:{rx}px; top:1074px; width:600px">p̂₁ is not p₁, but it sits close to it in the same space. The gap is p₁’s reconstruction error, and the document’s errors set its threshold</div>')
    labels.append(f"""<div class="label why" style="left:1258px; top:852px; width:250px">
  <div class="machine">WHY IT CAN STILL BE SEARCHED</div>
  <p>The slices are fixed, not random: the same 64 dimensions of every vector, and of the query, so slice 3 only meets slice 3.</p>
  <p>A centroid is drawn from the document’s own slices, so p̂₁ lands near p₁, and near partitions share centroids and codes.</p>
  <p>A query is measured against the centroids a partition’s codes name, which is nearly where it would land against the partition itself.</p>
</div>""")

    # 4 · A query finds its partition.
    qy, ty = 1708, 1764
    s.append(strip(mx, qy, vector(), h=18, outline=LINE, mark=SLICE))
    s.append(reply(384, mx - 8, qy + 9, DIAL, width=1.4))
    axis(mx, qy - 24, "q, cut the same sixteen ways", LINE)
    qx = mx + SLICE * CELL_W + CELL_W / 2
    s.append(dotted(qx, qy + 22, qx, ty - 3, LINE))
    axis(qx + 10, qy + 26, "slice 3 against codebook 3’s k centroids: one column of the table")
    s.append(grid(mx, ty, lambda i, j: shade(0.4 - table[i][j], 0.0, 0.32), path=CODES,
                  text=lambda i, j: f"{table[i][j]:.2f}"[1:]))
    axis(mx - 30, ty + 4, "c₀")
    axis(mx - 30, ty + 3 * CELL_H + 4, "c₃")
    cr = ty + K * CELL_H + 22
    for i, j in enumerate(CODES):
        x = mx + i * CELL_W + CELL_W / 2
        s.append(dotted(x, cr - 3, x, ty + (j + 1) * CELL_H + 1))
    s.append(codes_row(mx, cr, CODES))
    axis(96, cr + 5, "p₁’s codes, from memory", GOLD)
    picked = " + ".join(f"{table[i][j]:.2f}" for i, j in enumerate(CODES[:5]))
    axis(mx, cr + 40, f"d(q, p₁) = {picked} + … = {distance:.2f}", GOLD)
    axis(mx, cr + 60, "each code is an address into the table: sixteen reads and adds, no vector rebuilt")
    ranked = [("p₁", distance), ("p₄₂", distance + 0.45), ("p₇", distance + 0.54), ("p₁₁₃", distance + 1.09), ("p₉", distance + 1.16)]
    rows_html = "".join(
        f'<div class="hit{" kept" if n < 3 else ""}"><code>{name}</code><code>{d:.2f}</code></div>'
        + ('<div class="cut">best 3 · each under the threshold, so kept</div>' if n == 2 else "")
        for n, (name, d) in enumerate(ranked))
    labels.append(f"""<div class="label" style="left:1060px; top:1688px; width:446px">
  <div class="wire" style="position:static; color:#77756f; margin-bottom:8px">every partition of the document, scored so</div>{rows_html}
  <div class="wire" style="position:static; color:#77756f; margin-top:6px">⋯ 155 more</div>
  <p class="then">only now is any text read: p₁, p₄₂ and p₇ from <code>-parts</code>, then one ranking across every candidate document</p>
</div>""")
    labels.append(f'<div class="ptext query" style="left:96px; top:{qy - 6}px; width:276px"><b>“who leads Joltvault?”</b></div>')
    axis(96, qy + 30, "voyage-4-nano · query role")

    tile = lambda big, text: f'<div class="tile"><div class="big">{big}</div><p>{text}</p></div>'
    chip = lambda name, text, dashed=False: f'<div class="chip"{" style=border-style:dashed" if dashed else ""}><code>{name}</code><span>{text}</span></div>'
    body = f"""<style>
.ptext {{ position: absolute; width: 250px; box-sizing: border-box; height: 26px; padding: 4px 9px; border: 1px solid rgba(255,255,255,.1); border-radius: 6px;
         font-size: 13.5px; color: #a29f97; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.ptext b {{ font-family: {MONO}; font-style: normal; font-weight: 400; font-size: 11.5px; color: {GOLD}; margin-right: 4px; }}
.ptext.query {{ height: 30px; padding: 5px 10px; }}
.ptext.query b {{ font-family: "Playfair", Georgia, serif; font-style: italic; font-size: 16px; color: #ecebe5; }}
.caption2 {{ position: absolute; font-size: 17px; line-height: 1.32; color: #a29f97; }}
.caption2 b {{ font-weight: 400; color: #e3e1da; }}
.cols {{ position: absolute; display: grid; grid-template-columns: 1fr 1fr; column-gap: 20px; }}
.cols .chip {{ margin-top: 8px; }}
.tiles {{ position: absolute; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }}
.tile sup {{ font-size: .52em; vertical-align: .9em; line-height: 0; margin-left: 2px; }}
.caption2.small {{ font-size: 15.5px; color: #8f8c84; }}
.why p {{ margin: 12px 0 0; font-size: 15.5px; line-height: 1.32; color: #a29f97; }}
.tile {{ border: 1px solid rgba(255,255,255,.09); border-radius: 10px; padding: 12px 16px 14px; }}
.tile .big {{ font-size: 32px; line-height: 1.05; color: #ecebe5; }}
.tile p {{ margin: 6px 0 0; font-size: 15px; line-height: 1.3; color: #a29f97; }}
.hit {{ display: flex; justify-content: space-between; padding: 6px 12px; margin-top: 6px; border: 1px solid rgba(255,255,255,.08); border-radius: 7px; }}
.hit code {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #8b8a84; }}
.hit.kept {{ border-color: rgba(199,166,89,.55); }}
.hit.kept code {{ color: {GOLD}; }}
.cut {{ font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #77756f; border-top: 1px dashed #4a4944; margin-top: 9px; padding-top: 5px; text-align: right; }}
.then {{ margin: 12px 0 0; font-size: 16px; line-height: 1.32; color: #a29f97; }}
.then code {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #c3c0b7; }}
</style>
{card(70, 372, 1460, 374, head(step(1) + "A document becomes sixteen codebooks" + board("cutting the notches"), GOLD, "ONCE, WHEN THE DOCUMENT IS FILED"))}
<div class="caption2" style="left:96px; top:688px; width:1410px; font-size:16px">A partition is a segment of its document, a paragraph or a section, with one vector. Every vector, and every query, is cut at the same boundaries into sixteen 64-d slices; each codebook is trained on one slice of <b>all the document’s partitions together</b>, so the document’s sixteen codebooks are shared by every partition in it. k is the largest power of two at most n ÷ 39.</div>
{card(70, 770, 1460, 448, head(step(2) + "A partition becomes sixteen codes" + board("pressing a row"), GOLD, "ITS COMPRESSED EMBEDDING"))}
{card(70, 1242, 720, 336, head("Where each part lives" + board("the board, in memory"), "", "MEMORY · DISK"))}
<div class="cols" style="left:90px; top:1300px; width:680px">
  <div><div class="machine">IN MEMORY · WHAT SEARCH READS</div>
    {chip("codebooks", "16 × k centroids of 64 floats, one set per document")}
    {chip("slots", "each partition’s id, document and 16 codes")}
    {chip("entity_ids", "what the graph’s gate reads")}</div>
  <div><div class="machine">ON DISK</div>
    {chip("table-&lt;node&gt;", "the same codebooks and codes, saved within 1 s")}
    {chip("documents/&lt;id&gt;-parts", "each partition’s text and url, read only for hits")}
    {chip("the full vector", "in -parts only if the caller brought it; one Thread made is dropped once encoded", True)}</div>
</div>
{card(810, 1242, 720, 336, head(step(3) + "The ceiling: 65,536, for now" + board("notches a pin"), GOLD))}
<div class="tiles" style="left:830px; top:1294px; width:680px">
  {tile("65,536", "centroids one UInt16 code can name: the most a codebook may hold today")}
  {tile("2<sup>256</sup>", "codes one partition can take: 65,536 choices in each of sixteen slices")}
  {tile("2,555,904", "partitions before a document’s k reaches 65,536: some 3.8 billion characters, at 1,500 a partition")}
  {tile("UInt8", "what it can come down to: 16 bytes a partition while k ≤ 256. Today’s documents sit at k = 2 to 64")}
</div>
{card(70, 1602, 1460, 400, head(step(4) + "A query finds its partition" + board("holding the query up"), LINE, "PER QUERY, PER CANDIDATE DOCUMENT"))}
{card(70, 2026, 1460, 330, head(step(5) + "From the board to the table" + board("every term"), GOLD, "THE ANALOGY, TERM BY TERM"))}
<div class="label map" style="left:96px; top:2080px; width:960px">
  <div class="mrow mhead"><span>on the pin board</span><span>in the index</span></div>
  {"".join(f'<div class="mrow"><span>{a}</span><span>{b}</span></div>' for a, b in BOARD_TO_TABLE)}
</div>
<div class="label why" style="left:1110px; top:2080px; width:396px">
  <div class="machine">WHY IT IS FAST</div>
  <p>A partition costs <b>sixteen reads and adds</b>, not 1,024 multiplications against the query.</p>
  <p>The ruler is cut once per document per query: 16 × k distances, however many partitions it holds.</p>
  <p>Every candidate document is scanned at once, each on its own board.</p>
</div>
<svg width="{W}" height="2400">{"".join(s)}</svg>
{"".join(labels)}"""
    return body




def board(text):
    """Names a panel's part of the pin board (pin-board.png), beside its title."""
    return f'<span class="board">on the pin board · {text}</span>'


BOARD_TO_TABLE = [
    ("the query’s pin in a column", "q<sub>i</sub>: the query’s slice i, 64 of its 1,024 numbers"),
    ("a notch", "c<sub>ij</sub>: centroid j of the document’s codebook i"),
    ("the notch a row’s pin chose", "code<sub>i</sub>: one UInt16 a slice, sixteen a partition"),
    ("the gap from the query’s pin to a notch", "table[i][j] = ‖q<sub>i</sub> − c<sub>ij</sub>‖, cut once per query, per document"),
    ("a row’s sixteen gaps, added", "d(q, p) = Σ<sub>i</sub> table[i][code<sub>i</sub>]"),
    ("the rows that sit closest", "the best 3 partitions, kept if under the threshold"),
]
PARTITION_CSS = f"""<style>
.board {{ display: inline-block; margin-left: 14px; transform: translateY(-4px); font-family: {MONO}; font-style: normal; font-size: 11px; color: {GOLD}; border: 1px solid rgba(199,166,89,.4); border-radius: 12px; padding: 2px 10px; white-space: nowrap; }}
.map .mrow {{ display: grid; grid-template-columns: 340px 1fr; column-gap: 20px; padding: 7px 0; border-bottom: 1px solid rgba(255,255,255,.07); font-size: 16px; color: #dcdad3; }}
.map .mrow span:last-child {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #c3c0b7; }}
.map .mhead span {{ font-family: "Playfair", Georgia, serif !important; font-style: italic !important; font-size: 11.5px !important; letter-spacing: .22em; text-transform: uppercase; color: #77756f !important; }}
.why p b {{ font-weight: 400; color: #ecebe5; }}
</style>"""


def partition_window(top, height, body):
    """One stretch of the partition index's long page, shown from y = 372 down."""
    return (PARTITION_CSS + f'<div style="position:absolute; left:0; top:372px; width:{W}px; height:{height}px; overflow:hidden">'
            f'<div style="position:absolute; left:0; top:{-top}px; width:{W}px; height:2400px">{body}</div></div>')


def partition_index_filing():
    return plate("partition-index-1.png", 1666, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE PARTITION INDEX · I OF II",
                 "Filing a document", "its paragraphs become codes, against notches learned from them all",
                 partition_window(372, 1214, partition_index_body()),
                 "read with pin-board.png; the codes are illustrative, the shapes, sizes and rules are the code’s")


def partition_index_search():
    return plate("partition-index-2.png", 1210, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE PARTITION INDEX · II OF II",
                 "Searching a document", "a query becomes a ruler per column, and every paragraph is read in sixteen lookups",
                 partition_window(1602, 760, partition_index_body()),
                 "read with pin-board.png; the distances are illustrative, the rules are the code’s")


# MARK: The first index (Seer, with HNSW)

# From riteshpakala/Seer: PartitionIndex at 87b7738 (2025-11-15), the HNSW graphs at 691ac2f (2026-03-23).
TIMELINE = [
    ("2025-11-15", "PartitionIndex", "one per document, each scanned"),
    ("2026-03-08", "IVF-PQ", "a global index, trained at 2,500"),
    ("2026-03-11", "HNSW", "replaces IVF, live from the first insert"),
    ("2026-03-14", "personal HNSW", "a graph per owner, and its routes"),
    ("AII", "set aside", "the PQ scan stays; the graph returns"),
]
ROUTES = [
    ("GLOBAL", "the global graph is live", ["global HNSW · k × 10", "your access: available ∪ yours, k × 8 + k × 2",
                                            "a floor for every group, from its PartitionIndex", "Sinatra", "threshold"]),
    ("PERSONAL · GROUP", "your graph is live", ["your HNSW · k × 5", "the group, if asked", "Sinatra", "threshold"]),
    ("NO GRAPH YET", "the fallback", ["each document’s PartitionIndex, scanned with PQ"]),
]
HNSW_ROUTES = [
    ("POST /v1/hnsw/personal", "every live node of your graph, with its layer-0 neighbours"),
    ("POST /v1/hnsw/global", "the shared graph, as far as you may see it"),
    ("POST /v1/hnsw/node", "one node: its full text and every layer’s neighbours"),
    ("DELETE /v1/hnsw/node", "remove it, from both graphs and its document"),
]


def layered_graph(x0, y0):
    """Three layers of one graph, and a query cascading down them."""
    xs = [x0 + 40 + i * 44 for i in range(14)]
    layers = {2: [2, 10], 1: [2, 5, 8, 10, 12], 0: list(range(14))}
    ys = {2: y0 + 30, 1: y0 + 120, 0: y0 + 210}
    out = []
    for level, y in ys.items():
        out.append(f'<rect x="{x0}" y="{y - 26}" width="{xs[-1] - x0 + 40}" height="52" rx="10" fill="rgba(255,255,255,.025)" stroke="rgba(255,255,255,.07)"/>')
    for i in range(14):                                   # a node is one column through its layers
        top = max(l for l, members in layers.items() if i in members)
        if top > 0:
            out.append(dotted(xs[i], ys[top], xs[i], ys[0], "#6d6b64", .7))
    for level, members in layers.items():
        y = ys[level]
        pairs = list(zip(members, members[1:])) + ([(a, b) for a, b in zip(members, members[2:])] if level == 0 else [])
        for a, b in pairs:
            arc = "" if level else f" Q{(xs[a] + xs[b]) / 2},{y + (18 if (b - a) == 2 else 0)} "
            d = f"M{xs[a]},{y}{arc or ' L'}{xs[b]},{y}"
            out.append(f'<path d="{d}" fill="none" stroke="#5f5d57" stroke-width="1.3"/>')
        for i in members:
            r = 7 if level == 2 else 6 if level == 1 else 4.5
            out.append(f'<circle cx="{xs[i]}" cy="{y}" r="{r}" fill="#2a2925" stroke="#8b8a84" stroke-width="1.4"/>')
    # The query: greedy at 2 and 1, a beam at 0.
    path = [(2, 2), (2, 10), (1, 10), (1, 8), (0, 8)]
    for (la, ia), (lb, ib) in zip(path, path[1:]):
        xa, ya, xb, yb = xs[ia], ys[la], xs[ib], ys[lb]
        if la == lb:
            out.append(f'<line x1="{xa + (8 if xb > xa else -8)}" y1="{ya - 12}" x2="{xb + (-10 if xb > xa else 10)}" y2="{yb - 12}" stroke="{GOLD}" stroke-width="2"/>')
            out.append(arrowhead(xb + (-10 if xb > xa else 10), yb - 12, "right" if xb > xa else "left", GOLD))
        else:
            out.append(f'<line x1="{xa + 10}" y1="{ya + 8}" x2="{xb + 10}" y2="{yb - 10}" stroke="{GOLD}" stroke-width="2" stroke-dasharray="5 4"/>')
            out.append(arrowhead(xb + 10, yb - 10, "down", GOLD))
    out.append(f'<ellipse cx="{xs[8]}" cy="{ys[0]}" rx="104" ry="20" fill="rgba(199,166,89,.1)" stroke="{GOLD}" stroke-width="1.4" stroke-dasharray="4 4"/>')
    for i in (6, 7, 8, 9, 10):
        out.append(f'<circle cx="{xs[i]}" cy="{ys[0]}" r="4.5" fill="{GOLD}"/>')
    out.append(f'<text x="{xs[2] - 22}" y="{ys[2] - 14}" font-family="{MONO}" font-size="11" fill="{GOLD}" text-anchor="end">q</text>')
    out.append(f'<circle cx="{xs[2] - 14}" cy="{ys[2] - 18}" r="3.5" fill="{GOLD}"/>')
    out.append(dotted(xs[2] - 11, ys[2] - 15, xs[2] - 6, ys[2] - 6))
    labels = [(x0 + 10, ys[2] - 46, "layer 2 · the few hubs: greedy, one hop"), (x0 + 10, ys[1] - 46, "layer 1 · greedy again, then down"),
              (x0 + 10, ys[0] - 46, "layer 0 · every partition, ≤ 2M = 32 links")]
    return "".join(out), labels, (xs[8] + 112, ys[0] - 8)


def world_graph(x0, y0, w, h):
    """The graph as it was shown: layer-0 neighbours as edges, a node's level as its size, yours in blue."""
    rng = random.Random(7)
    centres = [(0.22, 0.32), (0.55, 0.22), (0.78, 0.55), (0.38, 0.72), (0.64, 0.82)]
    nodes = []
    for c, (cx, cy) in enumerate(centres):
        for _ in range(9):
            nodes.append((x0 + w * min(.97, max(.03, cx + rng.gauss(0, .07))), y0 + h * min(.95, max(.05, cy + rng.gauss(0, .08))),
                          c in (0, 3)))
    out, edges = [], set()
    for i, (xa, ya, _) in enumerate(nodes):
        near = sorted(range(len(nodes)), key=lambda j: (nodes[j][0] - xa) ** 2 + (nodes[j][1] - ya) ** 2)[1:4]
        edges.update(tuple(sorted((i, j))) for j in near)
    for a, b in sorted(edges):
        out.append(f'<line x1="{nodes[a][0]:.1f}" y1="{nodes[a][1]:.1f}" x2="{nodes[b][0]:.1f}" y2="{nodes[b][1]:.1f}" stroke="#4f4d48" stroke-width="1.1"/>')
    hubs = {0: 2, 9: 1, 20: 2, 31: 1, 40: 1}
    for i, (x, y, yours) in enumerate(nodes):
        level = hubs.get(i, 0)
        r = 4 + level * 3.2
        fill = BLUE if yours else "#7d7b74"
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{fill}" opacity="{.95 if yours else .7}" stroke="#191917" stroke-width="1.5"/>')
    sx, sy, _ = nodes[4]
    out.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="11" fill="none" stroke="{GOLD}" stroke-width="2"/>')
    return "".join(out), (sx, sy)


def first_index():
    s, labels = [], []
    axis = lambda x, y, text, colour="#77756f": labels.append(wire(x, y, text, colour))

    # The timeline.
    ty = 368
    s.append(f'<line x1="96" y1="{ty}" x2="1504" y2="{ty}" stroke="#4a4944" stroke-width="1.4"/>')
    step_x = (1504 - 96) / (len(TIMELINE) - 1)
    for n, (date, name, text) in enumerate(TIMELINE):
        x = 96 + n * step_x
        last = n == len(TIMELINE) - 1
        s.append(f'<circle cx="{x}" cy="{ty}" r="6" fill="#191917" stroke="{DIAL if last else GOLD}" stroke-width="2"/>')
        align = "left" if n == 0 else "right" if last else "center"
        shift = 0 if n == 0 else -250 if last else -125
        labels.append(f'<div class="tl" style="left:{x + shift}px; top:{ty + 14}px; text-align:{align}"><code>{date}</code><b>{name}</b><span>{text}</span></div>')

    # 1 · A partition lived twice.
    s.append(reply(338, 416, 578, GOLD, width=1.8))
    s.append(reply(338, 416, 760, LINE, width=1.8))
    s.append(f'<path d="M330,640 Q338,640 338,600 L338,578 M338,690 L338,760" fill="none" stroke="#6d6b64" stroke-width="1.4"/>')
    axis(346, 556, "first", GOLD)
    axis(346, 738, "then", LINE)
    s.append(strip(108, 668, [random.Random(3).random() for _ in range(16)], h=14, w=13.5))

    # 2 · The graph's layers.
    graph, glabels, beam_at = layered_graph(102, 996)
    s.append(graph)
    for x, y, text in glabels:
        axis(x, y, text)
    axis(beam_at[0] - 214, beam_at[1] + 40, "layer 0: a beam of ef = 50 around the landing", GOLD)

    # 4 · The world.
    world, (sx, sy) = world_graph(110, 1450, 450, 400)
    s.append(world)
    s.append(f'<path d="M{sx + 11},{sy} L560,{sy} L590,1500" fill="none" stroke="{GOLD}" stroke-width="1.2"/>')

    routes = "".join(
        f'<div class="route"><div class="who"><span class="machine">{scope}</span><i>{when}</i></div><div class="flow">'
        + '<span class="arrow">→</span>'.join(f'<span class="hop">{hop}</span>' for hop in hops) + "</div></div>"
        for scope, when, hops in ROUTES)
    endpoints = "".join(f'<div class="ep"><code>{call}</code><span>{text}</span></div>' for call, text in HNSW_ROUTES)
    body = f"""<style>
.tl {{ position: absolute; width: 250px; }}
.tl span {{ white-space: nowrap; }}
.tl code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #77756f; }}
.tl b {{ display: block; font-weight: 400; font-size: 20px; color: #ecebe5; margin-top: 2px; }}
.tl span {{ display: block; font-size: 14.5px; line-height: 1.28; color: #a29f97; margin-top: 2px; }}
.box {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.1); border-radius: 12px; padding: 12px 16px; background: rgba(255,255,255,.02); }}
.box h5 {{ margin: 0; font-weight: 400; font-size: 19px; color: #e3e1da; display: flex; justify-content: space-between; align-items: baseline; }}
.box h5 .machine {{ font-size: 10.5px; }}
.box p {{ margin: 6px 0 0; font-size: 15px; line-height: 1.3; color: #a29f97; }}
.field {{ display: grid; grid-template-columns: 150px 1fr; column-gap: 10px; margin-top: 5px; font-size: 14.5px; color: #a29f97; }}
.field code {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #dcdad3; }}
.kv {{ display: flex; gap: 6px; flex-wrap: wrap; margin-top: 10px; }}
.kv code {{ font-family: {MONO}; font-style: normal; font-size: 11.5px; color: {GOLD}; border: 1px solid rgba(199,166,89,.4); border-radius: 4px; padding: 1px 7px; }}
.route {{ border-top: 1px solid rgba(255,255,255,.07); padding: 12px 0 10px; }}
.route:first-child {{ border-top: none; padding-top: 0; }}
.route .who {{ display: flex; gap: 10px; align-items: baseline; }}
.route .who i {{ font-size: 15px; color: #8f8c84; }}
.route .flow {{ display: flex; flex-wrap: wrap; gap: 6px 4px; align-items: center; margin-top: 8px; }}
.hop {{ font-size: 15px; color: #dcdad3; border: 1px solid rgba(255,255,255,.12); border-radius: 7px; padding: 3px 9px; }}
.arrow {{ color: #6d6b64; font-style: normal; font-size: 13px; }}
.ep {{ display: grid; grid-template-columns: 196px 1fr; column-gap: 12px; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,.06); }}
.ep code {{ font-family: {MONO}; font-style: normal; font-size: 12px; color: {GOLD}; }}
.ep span {{ font-size: 14.5px; color: #a29f97; line-height: 1.28; }}
.hci p {{ margin: 11px 0 0; font-size: 16px; line-height: 1.34; color: #a29f97; }}
.hci p b {{ font-weight: 400; color: #ecebe5; }}
.inspect {{ position: absolute; width: 238px; box-sizing: border-box; border: 1px solid rgba(199,166,89,.55); border-radius: 10px; padding: 10px 12px; background: #1d1c19; }}
.inspect code {{ font-family: {MONO}; font-style: normal; font-size: 11px; color: #8b8a84; }}
.inspect p {{ margin: 5px 0 0; font-size: 14.5px; line-height: 1.28; color: #dcdad3; }}
.inspect .del {{ display: inline-block; margin-top: 8px; font-family: {MONO}; font-style: normal; font-size: 11px; color: {ORANGE}; border: 1px solid rgba(216,119,63,.5); border-radius: 4px; padding: 1px 7px; }}
.legend2 {{ position: absolute; display: flex; gap: 16px; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #8b8a84; }}
.legend2 i {{ display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }}
</style>
{card(70, 488, 1460, 400, head(step(1) + "A partition lived twice", GOLD, "ON PUT · TABLEMUTATOR"))}
<div class="ptext" style="left:96px; top:592px; width:234px; height:auto; white-space:normal"><b>p</b> a partition: a segment of its document, a paragraph of an essay, with its full vector</div>
<div class="box" style="left:424px; top:540px; width:560px; height:160px">
  <h5>a node in the graph <span class="machine">HNSWGRAPH · GLOBAL, AND YOUR OWN</span></h5>
  <div class="field"><code>partition</code><span>its text, url and owner</span></div>
  <div class="field"><code>embedding</code><span>the full vector, kept: traversal measures it</span></div>
  <div class="field"><code>level</code><span>the highest layer it reaches</span></div>
  <div class="field"><code>neighbors[l]</code><span>its links at layer l: ≤ 32 at 0, ≤ 16 above</span></div>
</div>
<div class="box" style="left:424px; top:716px; width:560px; height:150px">
  <h5>a partition of its document’s PartitionIndex <span class="machine">PER DOCUMENT · PQ</span></h5>
  <p>the document’s codebooks are trained on all its partitions; each keeps 16 codes, 32 bytes, and its vector is cleared: <code style="font-family:{MONO}; font-style:normal; font-size:12.5px; color:#dcdad3">embedding = []</code></p>
  <p>the graph had to take the vector first, before training let it go</p>
</div>
<div class="box" style="left:1004px; top:540px; width:500px; height:326px">
  <h5>Where it lived <span class="machine">ON DISK</span></h5>
  <div class="field"><code>table</code><span>keys, one PartitionIndex per document, and the global graph</span></div>
  <div class="field"><code>personal/&lt;owner&gt;</code><span>that owner’s own graph, written beside the global one</span></div>
  <div class="field"><code>documents/&lt;id&gt;</code><span>the document’s record</span></div>
  <div class="field"><code>registry</code><span>owners, groups, access</span></div>
  <div class="kv"><code>M = 16</code><code>efConstruction = 200</code><code>efSearch = 50</code></div>
  <p style="margin-top:12px">the trade: in its document, a partition’s vector is 32 bytes of codes, scanned; in the graph it holds the full vector and its links, and is walked in O(log N)</p>
</div>
{card(70, 912, 720, 420, head(step(2) + "The navigable graph", GOLD, "HNSW"))}
<div class="caption2 small" style="left:96px; top:1264px; width:670px">A node’s level is drawn at insert, P(level ≥ l) = (1 / ln M)<sup>l</sup>, so most live only at layer 0. An insert links to its nearest at each of its layers; a delete only marks the node, and compaction rebuilds.</div>
{card(810, 912, 720, 420, head(step(3) + "Search, by scope", GOLD, "PARTITIONTABLE.SEARCH"))}
<div class="label" style="left:836px; top:1004px; width:670px">{routes}</div>
{card(70, 1356, 1460, 520, head(step(4) + "A world you could walk", BLUE, "THE GRAPH, AS AN INTERFACE"))}
<div class="legend2" style="left:96px; top:1416px; flex-direction:column; gap:4px; width:470px"><span><i style="background:{BLUE}"></i>yours: read, delete, relink</span><span><i style="background:#7d7b74"></i>the shared graph: read only</span><span>size = level · edges = layer-0 neighbours</span></div>
<div class="inspect" style="left:590px; top:1470px"><code>p · level 0 · 6 neighbours · yours</code><p>“Ada leads Joltvault; on-call rotates weekly…”</p><span class="del">delete node</span></div>
<div class="label" style="left:836px; top:1404px; width:670px">{endpoints}
  <div class="hci">
    <p><b>The index was the interface.</b> What a person saw was the structure search used: a partition’s neighbours were its edges, and its rank in the hierarchy was its size.</p>
    <p><b>Ownership lived in the data.</b> Your graph held only your partitions, so it could be handed to you whole; the shared graph was shown as far as you could see it, never filtered after the fact.</p>
    <p><b>Changes were visible.</b> Deleting a node took its edges with it, and compaction demoted hubs, which shrank.</p>
  </div>
</div>
<svg width="{W}" height="1960">{"".join(s)}</svg>
{"".join(labels)}"""
    css_more = f"""<style>
.ptext {{ position: absolute; box-sizing: border-box; padding: 8px 10px 34px; border: 1px solid rgba(255,255,255,.1); border-radius: 8px; font-size: 14.5px; line-height: 1.28; color: #a29f97; }}
.ptext b {{ font-family: {MONO}; font-style: normal; font-weight: 400; font-size: 12px; color: {GOLD}; margin-right: 4px; }}
.caption2 {{ position: absolute; font-size: 15.5px; line-height: 1.32; color: #8f8c84; }}
.caption2 sup {{ font-size: .7em; }}
</style>"""
    return plate("first-index.png", 1940, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE FIRST DESIGN · SEER",
                 "The first index", "each partition lived twice: as codes in its document, and as a node in a world you could walk",
                 css_more + body, "from riteshpakala/Seer: 87b7738, 2025-11-15, to 691ac2f, 2026-03-23 · retired in AII, planned to return")


# MARK: The lineage (words to partitions)

LINEAGE = [
    ("2016 · where this began", "lexicons", "a score per word, looked up"),
    ("2014 · GloVe", "word vectors", "a point per word, learned from use"),
    ("2018 · ELMo, BERT", "context", "a word’s point depends on its sentence"),
    ("2019 → · sentence models", "passages", "a passage becomes one point"),
    ("2026 · Seer", "the graph", "HNSW links them across documents"),
]


def iso(x, y, z, ox, oy, s=145):
    """A point of a small 3-D space, drawn isometrically."""
    return ox + (x - z) * s * 0.87, oy + (x + z) * s * 0.5 - y * s


def word_space(ox, oy):
    out = []
    for (x, y, z), name in (((1.25, 0, 0), "x"), ((0, 1.25, 0), "y"), ((0, 0, 1.25), "z")):
        X, Y = iso(x, y, z, ox, oy)
        out.append(f'<line x1="{ox}" y1="{oy}" x2="{X:.1f}" y2="{Y:.1f}" stroke="#5f5d57" stroke-width="1.3"/>')
        out.append(f'<text x="{X + (6 if name != "z" else -14):.1f}" y="{Y + 4:.1f}" font-family="{MONO}" font-size="11" fill="#77756f">{name}</text>')
    words = {"king": (0.25, 0.95, 0.2), "queen": (0.6, 0.95, 0.2), "man": (0.25, 0.5, 0.15), "woman": (0.6, 0.5, 0.15),
             "happy": (1.15, 0.12, 0.55), "glad": (0.98, 0.42, 0.62), "joyful": (0.8, 0.2, 0.88),
             "car": (0.15, 0.15, 1.0), "truck": (0.28, 0.08, 1.12)}
    at = {w: iso(*p, ox, oy) for w, p in words.items()}
    for a, b, colour in (("man", "king", GOLD), ("woman", "queen", GOLD), ("man", "woman", "#8b8a84"), ("king", "queen", "#8b8a84")):
        (xa, ya), (xb, yb) = at[a], at[b]
        dash = ' stroke-dasharray="4 4"' if colour != GOLD else ""
        out.append(f'<line x1="{xa:.1f}" y1="{ya:.1f}" x2="{xb:.1f}" y2="{yb:.1f}" stroke="{colour}" stroke-width="1.6"{dash}/>')
    for w, (x, y) in at.items():
        x0, y0, z0 = words[w]
        fx, fy = iso(x0, 0, z0, ox, oy)
        out.append(dotted(x, y, fx, fy, "#4a4944", .8))
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4.5" fill="{LINE}"/>')
        out.append(f'<text x="{x + 8:.1f}" y="{y - 6:.1f}" font-family="{MONO}" font-size="12" fill="#dcdad3">{w}</text>')
    return "".join(out)


def passage_space(x0, y0, w, h):
    rng = random.Random(11)
    docs = [("runbook", BLUE, (0.25, 0.35)), ("stand-ups", GREEN, (0.7, 0.3)), ("essay", ORANGE, (0.5, 0.75))]
    pts = []
    for d, (_, colour, (cx, cy)) in enumerate(docs):
        for _ in range(9):
            pts.append((x0 + w * min(.95, max(.05, cx + rng.gauss(0, .13))), y0 + h * min(.93, max(.07, cy + rng.gauss(0, .12))), d))
    out, edges = [], set()
    for i, (xa, ya, _) in enumerate(pts):
        near = sorted(range(len(pts)), key=lambda j: (pts[j][0] - xa) ** 2 + (pts[j][1] - ya) ** 2)[1:4]
        edges.update(tuple(sorted((i, j))) for j in near)
    cross = [(a, b) for a, b in sorted(edges) if pts[a][2] != pts[b][2]]
    pick = min(cross, key=lambda e: (pts[e[0]][0] - pts[e[1]][0]) ** 2 + (pts[e[0]][1] - pts[e[1]][1]) ** 2)
    for a, b in sorted(edges):
        strong = (a, b) == pick
        out.append(f'<line x1="{pts[a][0]:.1f}" y1="{pts[a][1]:.1f}" x2="{pts[b][0]:.1f}" y2="{pts[b][1]:.1f}" '
                   f'stroke="{GOLD if strong else "#4f4d48"}" stroke-width="{2.4 if strong else 1.1}"/>')
    for x, y, d in pts:
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{docs[d][1]}" stroke="#191917" stroke-width="1.5"/>')
    a, b = pick
    return "".join(out), docs, ((pts[a][0] + pts[b][0]) / 2, (pts[a][1] + pts[b][1]) / 2)


def lineage():
    s, labels = [], []
    ty = 372
    s.append(f'<line x1="96" y1="{ty}" x2="1504" y2="{ty}" stroke="#4a4944" stroke-width="1.4"/>')
    step_x = (1504 - 96) / (len(LINEAGE) - 1)
    for n, (when, name, text) in enumerate(LINEAGE):
        x = 96 + n * step_x
        s.append(f'<circle cx="{x}" cy="{ty}" r="6" fill="#191917" stroke="{GOLD}" stroke-width="2"/>')
        align = "left" if n == 0 else "right" if n == len(LINEAGE) - 1 else "center"
        shift = 0 if n == 0 else -250 if n == len(LINEAGE) - 1 else -125
        labels.append(f'<div class="tl" style="left:{x + shift}px; top:{ty + 14}px; text-align:{align}"><code>{when}</code><b>{name}</b><span>{text}</span></div>')

    # ① A word has a score.
    lex = [("running", "—", 0), ("late", "sadness", .35), ("dreading", "fear", .85), ("the", "—", 0), ("review", "—", 0)]
    rows = "".join(f'<div class="lex"><span>{word}</span><code>{tag}</code><i style="width:{v * 120:.0f}px"></i></div>' for word, tag, v in lex)
    cadence = "".join(f'<div class="cad"><code>{emo}</code><i style="width:{v * 200:.0f}px; background:{c}"></i></div>'
                      for emo, v, c in (("fear", .85, ORANGE), ("sadness", .35, BLUE), ("joy", .04, GOLD)))
    # ② A word is a point.
    s.append(word_space(830, 760))
    # ③ A partition is a point.
    graph, docs, mid = passage_space(1084, 560, 420, 300)
    s.append(graph)
    s.append(f'<line x1="{mid[0]:.1f}" y1="{mid[1]:.1f}" x2="{mid[0] - 30:.1f}" y2="{mid[1] + 60:.1f}" stroke="{GOLD}" stroke-width="1"/>')
    labels.append(wire(mid[0] - 26, mid[1] + 62, "a link across two documents", GOLD, anchor="right"))
    legend = "".join(f'<span><i style="background:{c}"></i>{name}</span>' for name, c, _ in docs)

    body = f"""<style>
.tl {{ position: absolute; width: 250px; }}
.tl code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #77756f; }}
.tl b {{ display: block; font-weight: 400; font-size: 20px; color: #ecebe5; margin-top: 2px; }}
.tl span {{ display: block; font-size: 14.5px; line-height: 1.28; color: #a29f97; margin-top: 2px; white-space: nowrap; }}
.cap {{ position: absolute; font-size: 15.5px; line-height: 1.34; color: #a29f97; }}
.cap b {{ font-weight: 400; color: #ecebe5; }}
.lex {{ display: grid; grid-template-columns: 90px 80px 1fr; align-items: center; padding: 5px 0; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 16px; color: #dcdad3; }}
.lex code, .cad code {{ font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #8b8a84; }}
.lex i {{ display: block; height: 6px; border-radius: 3px; background: #8b8a84; }}
.msg {{ font-size: 18px; color: #ecebe5; margin-bottom: 10px; }}
.cad {{ display: grid; grid-template-columns: 70px 1fr; align-items: center; margin-top: 7px; }}
.cad i {{ display: block; height: 8px; border-radius: 4px; }}
.legend3 {{ position: absolute; display: flex; gap: 14px; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #8b8a84; }}
.legend3 i {{ display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }}
.note {{ position: absolute; font-size: 17px; line-height: 1.36; color: #a29f97; }}
.note b {{ font-weight: 400; color: #ecebe5; }}
</style>
{card(70, 470, 473, 560, head(step(1) + "A word has a score", GOLD, "LEXICONS"))}
<div class="label" style="left:94px; top:528px; width:425px">
  <div class="msg">“running late, dreading the review”</div>{rows}
  <div class="wire" style="position:static; color:#77756f; margin-top:16px">the message’s cadence: its words, summed</div>{cadence}
</div>
<div class="cap" style="left:94px; top:880px; width:425px">A lexicon scores each word on its own, and a message is the sum of its words. <b>Meaning is looked up, not measured</b>: a word the list lacks says nothing, and “not happy” reads as happy.</div>
{card(563, 470, 473, 560, head(step(2) + "A word is a point", GOLD, "GLOVE"))}
<div class="cap" style="left:587px; top:880px; width:425px">GloVe learns from how words are used together, so words used alike sit close. <b>Distance is meaning, and a direction can be a relation</b>: king − man + woman lands near queen. Drawn here in three dimensions; GloVe used 50 to 300.</div>
{card(1056, 470, 474, 560, head(step(3) + "A partition is a point", GOLD, "HNSW"))}
<div class="legend3" style="left:1080px; top:566px">{legend}</div>
<div class="cap" style="left:1080px; top:880px; width:426px">A text embedding model reads a whole passage, in context, into one vector: voyage-4-nano gives 1,024 numbers. <b>The graph links each partition to its nearest</b>, whichever document it came from.</div>
<div class="note" style="left:70px; top:1062px; width:1460px">A vector is a list of numbers, one per dimension; x, y and z are only how we draw it. What grew along the way is the unit that gets a point: <b>a word, then a word in its sentence, then a whole passage</b>. The embedding model makes the distances; HNSW makes them walkable, so one partition of a document can find its neighbours in another.</div>
<svg width="{W}" height="1300">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("lineage.png", 1220, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE LINEAGE",
                 "Words to partitions", "from a score per word, to a point per word, to a point per passage, linked across documents",
                 body, "the points are illustrative; GloVe 2014, ELMo and BERT 2018, Sentence-BERT 2019")


# MARK: The credibility layer (Seer's firehose and Gita)

# From riteshpakala/Seer: the firehose (2026-03-02 → 03-12) and Gita's spans, royalties and wallet (2026-03-29 → 04-23).
SOURCES = [("BlueSky", BLUE, 60), ("RSS", ORANGE, 25), ("you", GREEN, 15)]
POSTS = [("@person-a.bsky.social", "the bridge closure moves the night buses to the river road"),
         ("@person-b.bsky.social", "river road runs every 20 minutes after 11, checked tonight"),
         ("@person-c.bsky.social", "the 40 skips the bridge stop until spring")]


def credibility():
    s, labels = [], []
    axis = lambda x, y, text, colour="#77756f": labels.append(wire(x, y, text, colour))

    # ① The firehose: a chain of stages.
    chain = [("Bluesky · RSS", "posts, as they are published"), ("the firehose", "hourly, filtered by keywords"),
             ("service accounts", "filed as BlueSky, RSS, …"), ("the index", "partitions, owned by those accounts")]
    chain_html = ""
    for i, (name, text) in enumerate(chain):
        x = 96 + i * 362
        chain_html += f'<div class="stage2" style="left:{x}px; top:430px"><b>{name}</b><span>{text}</span></div>'
        if i < len(chain) - 1:
            s.append(reply(x + 304, x + 352, 466, DIAL, width=1.4))

    # ② An answer and the people behind it.
    bar_x, bar_y, bar_w = 640, 690, 460
    x = bar_x
    for name, colour, pct in SOURCES:
        w = bar_w * pct / 100
        s.append(f'<rect x="{x + 1}" y="{bar_y}" width="{w - 2}" height="26" rx="5" fill="{colour}" opacity=".85"/>')
        s.append(f'<text x="{x + 10}" y="{bar_y + 17.5}" font-family="{MONO}" font-size="12" fill="#121211">{pct}% {name}</text>')
        x += w
    s.append(f'<rect x="{bar_x - 3}" y="{bar_y - 3}" width="{bar_w * .6 + 2}" height="32" rx="7" fill="none" stroke="{GOLD}" stroke-width="1.8"/>')
    s.append(f'<path d="M{bar_x + bar_w * .3},{bar_y + 30} L{bar_x + bar_w * .3},{bar_y + 70} L1100,{bar_y + 70}" fill="none" stroke="{GOLD}" stroke-width="1.6" stroke-dasharray="5 4"/>')
    s.append(arrowhead(1104, bar_y + 70, "right", GOLD))
    axis(bar_x + bar_w * .3 + 10, bar_y + 48, "tap BlueSky", GOLD)
    posts = "".join(f'<div class="post"><code>{who}</code><span>“{text}”</span></div>' for who, text in POSTS)

    answer = ('The <mark class="b">night buses now take the river road</mark><sup>1</sup> while the bridge is closed, '
              '<mark class="b">every 20 minutes after 11</mark><sup>2</sup>. <mark class="r">The city expects the bridge back in March</mark><sup>3</sup>, '
              'and <mark class="g">you usually catch the 11:40</mark><sup>4</sup>.')
    body = f"""<style>
.stage2 {{ position: absolute; width: 300px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.1); border-radius: 10px; padding: 10px 14px; }}
.stage2 b {{ display: block; font-weight: 400; font-size: 19px; color: #ecebe5; }}
.stage2 span {{ display: block; font-size: 15px; color: #a29f97; margin-top: 2px; }}
.cap {{ position: absolute; font-size: 15.5px; line-height: 1.34; color: #a29f97; }}
.cap b {{ font-weight: 400; color: #ecebe5; }}
.q {{ font-size: 17px; color: #8f8c84; }}
.ans {{ font-size: 19px; line-height: 1.55; color: #dcdad3; margin-top: 8px; }}
.ans mark {{ background: none; color: #ecebe5; padding: 0 2px; border-bottom: 2px solid; }}
.ans mark.b {{ border-color: {BLUE}; }} .ans mark.r {{ border-color: {ORANGE}; }} .ans mark.g {{ border-color: {GREEN}; }}
.ans sup {{ font-family: {MONO}; font-style: normal; font-size: 10px; color: {GOLD}; }}
.post {{ border: 1px solid rgba(94,143,218,.4); border-radius: 9px; padding: 8px 12px; margin-top: 8px; }}
.post code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: {BLUE}; }}
.post span {{ display: block; font-size: 15px; line-height: 1.3; color: #dcdad3; margin-top: 3px; }}
.pts p {{ margin: 10px 0 0; font-size: 16px; line-height: 1.36; color: #a29f97; }}
.pts p b {{ font-weight: 400; color: #ecebe5; }}
</style>
{card(70, 372, 1460, 150, head(step(1) + "The firehose", GOLD, "SEER · 2026-03"))}
{chain_html}
{card(70, 546, 1460, 384, head(step(2) + "An answer, and the people behind it", GOLD, "GITA · SPANS, SHARES, ROYALTIES"))}
<div class="label" style="left:96px; top:604px; width:500px">
  <div class="q">“how do I get home tonight?”</div>
  <div class="ans">{answer}</div>
</div>
<div class="cap" style="left:96px; top:800px; width:500px">The model cites with markers; each cited span is matched back to the partition it came from, and colored by the account that owns it.</div>
<div class="wire" style="left:640px; top:662px; color:#77756f">this answer, by whose words it was sewn from</div>
<div class="cap" style="left:640px; top:792px; width:430px">Each share is priced against the turn’s real token cost and <b>credited to its owner as a royalty</b>: fair use, settled at the retrieval layer.</div>
<div class="label" style="left:1112px; top:604px; width:396px">
  <div class="wire" style="position:static; color:{BLUE}">BlueSky · the posts this answer used</div>{posts}
  <div class="cap" style="position:static; margin-top:10px">real accounts, real people: something to check, not a voice to trust</div>
</div>
{card(70, 954, 720, 260, head(step(3) + "Sewing, not sourcing", GOLD, "WHY IT MATTERED"))}
<div class="label pts" style="left:96px; top:1004px; width:670px">
  <p><b>The model stitched; it was not the source.</b> An answer became a seam between people, each thread traceable to someone who wrote it.</p>
  <p><b>Personal, by construction.</b> The same layer that paid authors showed you whose words were shaping what you read, including your own.</p>
  <p><b>Verify, don’t trust.</b> A black box can lead you somewhere wrong, sometimes on purpose; a cited span you can open and check is a guard against that.</p>
</div>
{card(810, 954, 720, 260, head(step(4) + "Why the graph was set aside", LINE, "PRIVACY FIRST"))}
<div class="label pts" style="left:836px; top:1004px; width:670px">
  <p><b>Inserts linked in place; deletes did not.</b> A deleted node was only marked: its text and full vector stayed in the graph, and links still pointed at it, until a compaction rebuilt it.</p>
  <p><b>Forgetting has to be immediate.</b> Per-document PQ indices drop a document’s whole index the moment it is removed, and the save is not deferred.</p>
  <p><b>Worth bringing back</b>, once deletion can be as clean as insertion.</p>
</div>
<svg width="{W}" height="1300">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("credibility.png", 1290, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE CREDIBILITY LAYER",
                 "Who said it", "an answer, traced back to the people whose words it was sewn from",
                 body, "the posts, accounts and shares are illustrative; the firehose, spans and royalties are Seer’s")


# MARK: Many threads (the split)

# From riteshpakala/Seer: Linux builds (2026-02-06 → 02-21), Oracle peers (03-03 → 03-05), the split into
# Totem (05-23) and gRPC between them (05-24). Totem is today's Thread; Seer is today's Sewn (2026-09-07).
SPLIT = [
    ("2026-02", "Linux", "Sewn builds on Ubuntu, with MLX"),
    ("2026-03", "peers", "Sewn servers connect to each other"),
    ("2026-05-23", "the split", "the database leaves as Thread"),
    ("2026-05-24", "gRPC", "Sewn and Thread talk over the wire"),
    ("2026-09 · AII", "AII", "the two halves, one index"),
]


def box(x, y, w, h, title, lines, colour=None, dashed=False, machine=""):
    dot = f'<i class="dot" style="background:{colour}"></i>' if colour else ""
    style = "border-style:dashed;" if dashed else ""
    rows = "".join(f"<span>{line}</span>" for line in lines)
    tag = f'<em>{machine}</em>' if machine else ""
    return f'<div class="bx" style="left:{x}px; top:{y}px; width:{w}px; height:{h}px; {style}"><b>{dot}{title}</b>{tag}{rows}</div>'


def threads():
    s, labels = [], []
    axis = lambda x, y, text, colour="#77756f": labels.append(wire(x, y, text, colour))
    ty = 372
    s.append(f'<line x1="96" y1="{ty}" x2="1504" y2="{ty}" stroke="#4a4944" stroke-width="1.4"/>')
    step_x = (1504 - 96) / (len(SPLIT) - 1)
    for n, (when, name, text) in enumerate(SPLIT):
        x = 96 + n * step_x
        s.append(f'<circle cx="{x}" cy="{ty}" r="6" fill="#191917" stroke="{GOLD}" stroke-width="2"/>')
        align = "left" if n == 0 else "right" if n == len(SPLIT) - 1 else "center"
        shift = 0 if n == 0 else -250 if n == len(SPLIT) - 1 else -125
        labels.append(f'<div class="tl" style="left:{x + shift}px; top:{ty + 14}px; text-align:{align}"><code>{when}</code><b>{name}</b><span>{text}</span></div>')

    # ① The split.
    s.append(reply(380, 448, 640, DIAL, width=1.6))
    s.append(f'<path d="M462,640 L478,640 M478,588 L478,692" fill="none" stroke="#6d6b64" stroke-width="1.4"/>')
    s.append(reply(478, 506, 588, DIAL, width=1.4))
    s.append(reply(478, 506, 692, DIAL, width=1.4))
    one = box(96, 548, 278, 184, "Sewn", ["the REST API", "the LLM providers", "retrieval and the personal layer", "the index, the graph, the registry"], LINE, machine="ONE SERVER")
    service = box(514, 528, 250, 120, "Sewn", ["REST, the LLM APIs,", "and retrieval, prepared"], LINE, machine="THE SERVICE")
    data = box(514, 652, 250, 110, "Thread", ["the index, the graph,", "the registry: the data"], VIOLET, machine="THE DATABASE")

    # ② The proof, on a home network.
    s.append(reply(1110, 1180, 600, GOLD, width=1.8))
    s.append(reply(1180, 1110, 640, VIOLET, width=1.8))
    axis(1112, 578, "Search", GOLD)
    axis(1112, 646, "hits", VIOLET)
    axis(1106, 680, "gRPC · the LAN")
    desk = box(830, 528, 272, 220, "a desktop on Ubuntu", ["Swift on Linux, MLX on device", "an embedding model; an LLM to summarize", "a Thread holding arXiv:", "authors and entities, filed as groups"], VIOLET)
    mac = box(1188, 528, 318, 220, "Sewn", ["answers the front end", "asks the Thread for every turn’s context", "the first time the data lived on another machine"], LINE)

    # ③ Many threads, sewn.
    cx, cy = 560, 1110
    owners = [("yours", BLUE), ("theirs", GREEN), ("a lab’s", ORANGE), ("a feed’s", "#8b8a84"), ("arXiv", VIOLET)]
    for i, (name, colour) in enumerate(owners):
        tx, ty2 = 160 + i * 200, 920
        s.append(f'<path d="M{tx},{ty2 + 14} C{tx},{ty2 + 110} {cx},{cy - 90} {cx},{cy - 18}" fill="none" stroke="{colour}" stroke-width="2.4" opacity=".85"/>')
        s.append(f'<circle cx="{tx}" cy="{ty2}" r="13" fill="#191917" stroke="{colour}" stroke-width="2.2"/>')
        labels.append(f'<div class="node" style="left:{tx - 60}px; top:{ty2 - 52}px; color:{colour}">{name}<br><span>a Thread</span></div>')
    s.append(f'<circle cx="{cx}" cy="{cy}" r="17" fill="#191917" stroke="{GOLD}" stroke-width="2.4"/><circle cx="{cx}" cy="{cy}" r="6" fill="{GOLD}"/>')
    s.append(f'<line x1="{cx}" y1="{cy + 18}" x2="{cx}" y2="{cy + 54}" stroke="{LINE}" stroke-width="3" stroke-linecap="round"/>')
    labels.append(f'<div class="node" style="left:{cx + 28}px; top:{cy - 16}px; width:260px; color:{GOLD}; text-align:left">the mothership<br><span>Sewn, sewing the threads together</span></div>')
    labels.append(f'<div class="node" style="left:{cx - 60}px; top:{cy + 58}px; color:#ecebe5">Ambient<br><span>one interface</span></div>')

    body = f"""<style>
.tl {{ position: absolute; width: 250px; }}
.tl code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #77756f; }}
.tl b {{ display: block; font-weight: 400; font-size: 20px; color: #ecebe5; margin-top: 2px; }}
.tl span {{ display: block; font-size: 14.5px; color: #a29f97; margin-top: 2px; white-space: nowrap; }}
.bx {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.11); border-radius: 11px; padding: 11px 14px; background: rgba(255,255,255,.02); }}
.bx b {{ display: block; font-weight: 400; font-size: 20px; color: #ecebe5; }}
.bx em {{ display: block; font-style: normal; font-size: 10.5px; letter-spacing: .2em; color: #77756f; margin: 2px 0 4px; }}
.bx span {{ display: block; font-size: 15px; line-height: 1.32; color: #a29f97; }}
.dot {{ display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; transform: translateY(-2px); }}
.node {{ position: absolute; width: 120px; text-align: center; font-size: 17px; line-height: 1.15; }}
.node span {{ font-size: 13.5px; color: #8b8a84; }}
.quote {{ position: absolute; font-size: 30px; line-height: 1.25; color: #dcdad3; }}
.cap {{ position: absolute; font-size: 16px; line-height: 1.36; color: #a29f97; }}
.cap b {{ font-weight: 400; color: #ecebe5; }}
</style>
{card(70, 470, 720, 300, head(step(1) + "Divide and conquer", GOLD, "ONE SERVER, TWO PRODUCTS"))}
{one}{service}{data}
{card(810, 470, 720, 300, head(step(2) + "The proof, on a home network", GOLD, "THREAD ON UBUNTU"))}
{desk}{mac}
{card(70, 794, 1460, 500, head(step(3) + "Many threads, one seam", GOLD, "THE IDEA IT PROVED"))}
<div class="quote" style="left:1110px; top:860px; width:390px">“Decentralized intelligence centralizes progress for the whole.”</div>
<div class="cap" style="left:1110px; top:1020px; width:390px">One stone, many birds. <b>Each person hosts a Thread with their own data</b>, and a mothership sews them together for one interface. Attribution comes from retrieval, and ownership from where the data lives.</div>
<div class="cap" style="left:96px; top:1232px; width:960px">A Thread dials the mothership and holds its session open; the mothership never needs to reach in. That is still how Sewn reaches Thread on every Mac today.</div>
<svg width="{W}" height="1460">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("threads.png", 1360, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE SPLIT",
                 "Many threads", "the database left the server, and a home network proved people could host their own",
                 body, "from riteshpakala/Seer, 2026-02 to 2026-05, named as they are today")


# MARK: Narrowing the field (Thread today)

# PartitionTable.search: the lane and the owner's groups give the candidates, the graph gates them (a
# tag is a concept entity), a PQ scan ranks the best 3 of each, one hop adds neighbours, and one
# ranking cuts at top_k. The counts are illustrative.
FUNNEL = [
    ("your lane", "1,000,000 partitions · 40,000 documents", "the secret picks it", "registry"),
    ("your groups", "3,000 documents", "the owner, and the groups you named", "registry"),
    ("the graph", "120 documents", "linked to the entities, relationships and tags you named", "graph"),
    ("the vectors", "360 partitions", "a PQ scan: the best 3 of each document", "vectors"),
    ("one ranking", "8 partitions", "one hop of neighbours, then cut at top_k", "graph"),
]


def funnel():
    s, labels = [], []
    cx, top, h, gap = 450, 442, 50, 14
    widths = [700, 560, 420, 290, 170]
    for n, ((name, count, text, store_name), w) in enumerate(zip(FUNNEL, widths)):
        y = top + n * (h + gap)
        colour = STORE[store_name]
        s.append(f'<rect x="{cx - w / 2}" y="{y}" width="{w}" height="{h}" rx="9" fill="{colour}" fill-opacity=".14" stroke="{colour}" stroke-opacity=".55"/>')
        labels.append(f'<div class="fcount" style="left:{cx - w / 2}px; top:{y + 13}px; width:{w}px">{count}</div>')
        labels.append(f'<div class="fname" style="left:840px; top:{y + 4}px"><b>{name}</b>{store(store_name)}<span>{text}</span></div>')
    end = top + 5 * (h + gap) - gap
    s.append(f'<path d="M{cx},{end + 4} L{cx},{end + 22} M{cx - 190},{end + 22} L{cx + 190},{end + 22} M{cx - 190},{end + 22} L{cx - 190},{end + 38} M{cx + 190},{end + 22} L{cx + 190},{end + 38}" fill="none" stroke="#77756f" stroke-width="1.4"/>')
    s.append(arrowhead(cx - 190, end + 40, "down", "#77756f") + arrowhead(cx + 190, end + 40, "down", "#77756f"))
    outcomes = (f'<div class="out" style="left:{cx - 330}px; top:{end + 48}px"><b>context, for a request</b>'
                f'<span>Sewn frames the passages as “you wrote”, and the answer is personal</span></div>'
                f'<div class="out" style="left:{cx + 50}px; top:{end + 48}px"><b>recall, as memory</b>'
                f'<span>Ambient brings back a note from March that matters again today</span></div>')

    body = f"""<style>
.fcount {{ position: absolute; text-align: center; font-family: {MONO}; font-style: normal; font-size: 13.5px; color: #ecebe5; }}
.fname {{ position: absolute; width: 660px; display: grid; grid-template-columns: 150px auto 1fr; column-gap: 12px; align-items: baseline; }}
.fname b {{ font-weight: 400; font-size: 20px; color: #ecebe5; }}
.fname > span:last-child {{ font-size: 16px; color: #a29f97; }}
.store {{ font-family: {MONO}; font-style: normal; font-size: 10.5px; border: 1px solid; border-radius: 4px; padding: 1px 6px; }}
.out {{ position: absolute; width: 280px; box-sizing: border-box; border: 1px solid rgba(199,166,89,.45); border-radius: 10px; padding: 10px 14px; }}
.out b {{ display: block; font-weight: 400; font-size: 18px; color: #ecebe5; }}
.out span {{ display: block; font-size: 15px; line-height: 1.3; color: #a29f97; margin-top: 3px; }}
.pts p {{ margin: 10px 0 0; font-size: 16px; line-height: 1.36; color: #a29f97; }}
.pts p b {{ font-weight: 400; color: #ecebe5; }}
.pair {{ display: grid; grid-template-columns: 1fr 1fr; column-gap: 18px; margin-top: 4px; }}
.pair > div {{ border: 1px solid rgba(255,255,255,.09); border-radius: 10px; padding: 11px 14px; }}
.pair b {{ display: block; font-weight: 400; font-size: 19px; color: #ecebe5; }}
.pair code {{ font-family: {MONO}; font-style: normal; font-size: 11.5px; color: #8b8a84; }}
.pair span {{ display: block; font-size: 15px; line-height: 1.32; color: #a29f97; margin-top: 4px; }}
</style>
{card(70, 374, 1460, 520, head(step(1) + "From millions to a handful", GOLD, "THREADQUERY.SEARCH"))}
{outcomes}
<svg width="{W}" height="1400">{"".join(s)}</svg>
{card(70, 918, 720, 196, head(step(2) + "Two ways to ask", GOLD, "SAME INDEX"))}
<div class="label pair" style="left:96px; top:972px; width:670px">
  <div><b>similar</b><code>ThreadQuery.Search</code><span>a query against the partitions, ranked by distance: what reads alike</span></div>
  <div><b>related</b><code>ThreadGraph.Query</code><span>entities and relationships matched, then walked: the same graph gives the same answer</span></div>
</div>
{card(810, 918, 720, 196, head(step(3) + "Groups and tags", GOLD, "TWO WAYS TO NARROW"))}
<div class="label pair" style="left:836px; top:972px; width:670px">
  <div><b>a group</b><code>group_ids</code><span>a folder: each document sits in one, and a search can name which to look in</span></div>
  <div><b>a tag</b><code>tags → concept entities</code><span>a label: a document can carry many, each filed in the graph, so naming it finds the document</span></div>
</div>
{"".join(labels)}"""
    return plate("funnel.png", 1180, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THREAD TODAY",
                 "Narrowing the field", "the graph decides where to look, the vectors decide what reads alike",
                 body, "the counts are illustrative; the order is PartitionTable.search’s")


# MARK: The pin board (the partition index, by analogy)

PIN_COLS, PIN_ROWS = 16, 8
PIN_DX, PIN_DY, SKEW, ZX, ZY = 33, 40, 7, 5.5, 7     # the board's grid, and how far a notch pushes a pin out


def pin_at(bx, by, i, r, z):
    return bx + i * PIN_DX + r * SKEW + z * ZX, by + r * PIN_DY - z * ZY


def pin_board(bx, by, depths, mark_row=1, mark_col=15):
    """A pin-art board: a row per partition, a column per slice, each pin at its notch."""
    out = []
    w = PIN_COLS * PIN_DX + PIN_ROWS * SKEW
    # The back plate and its shadow, then the guides of the marked row and column.
    out.append(f'<rect x="{bx - 46}" y="{by - 40}" width="{w + 70}" height="{PIN_ROWS * PIN_DY + 50}" rx="14" fill="#0d0d0c" stroke="#2c2b28"/>')
    for r in range(PIN_ROWS):
        for i in range(PIN_COLS):
            z = depths[r][i]
            x0, y0 = pin_at(bx, by, i, r, 0)
            x1, y1 = pin_at(bx, by, i, r, z)
            out.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" stroke="#6d6f74" stroke-width="2.2" stroke-linecap="round"/>')
            ring = (f' stroke="{GOLD}" stroke-width="1.6"' if r == mark_row else
                    f' stroke="{BLUE}" stroke-width="1.6"' if i == mark_col else "")
            out.append(f'<circle cx="{x1:.1f}" cy="{y1:.1f}" r="9.5" fill="url(#pinhead)"{ring}/>')
    # The clear front plate, its corner posts.
    out.append(f'<rect x="{bx - 30}" y="{by - 64}" width="{w + 70}" height="{PIN_ROWS * PIN_DY + 58}" rx="12" fill="rgba(255,255,255,.035)" stroke="rgba(255,255,255,.22)" stroke-width="1.4"/>')
    for px, py in ((bx - 30, by - 64), (bx + w + 40, by - 64), (bx - 30, by - 6 + PIN_ROWS * PIN_DY), (bx + w + 40, by - 6 + PIN_ROWS * PIN_DY)):
        out.append(f'<circle cx="{px + (14 if px < bx else -14)}" cy="{py + (14 if py < by else -14)}" r="11" fill="#0d0d0c" stroke="#3a3936" stroke-width="2"/>'
                   f'<circle cx="{px + (14 if px < bx else -14)}" cy="{py + (14 if py < by else -14)}" r="4" fill="#262522"/>')
    return "".join(out)


def pins():
    rng = random.Random(9)
    # A document's relief: neighbouring paragraphs press alike, so the board shows a shape.
    depths = [[max(1, min(4, round(2.5 + 1.4 * math.sin(i / 2.6 + r / 1.7) + rng.uniform(-.6, .6)))) for i in range(PIN_COLS)]
              for r in range(PIN_ROWS)]
    query = [max(1, min(4, d + (1 if rng.random() < .2 else 0))) for d in depths[1]]
    bx, by = 196, 620
    s = [f'<defs><radialGradient id="pinhead" cx="35%" cy="32%" r="70%"><stop offset="0" stop-color="#f6f7f9"/>'
         f'<stop offset=".45" stop-color="#b9bcc3"/><stop offset="1" stop-color="#4b4d52"/></radialGradient></defs>']
    s.append(pin_board(bx, by, depths))

    # The query: a row of pins held up against every row of the board.
    qx, qy = bx, 474
    for i, z in enumerate(query):
        x, y = pin_at(qx, qy, i, 0, z)
        x0, y0 = pin_at(qx, qy, i, 0, 0)
        s.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x:.1f}" y2="{y:.1f}" stroke="{GOLD}" stroke-width="2" opacity=".7"/>')
        s.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="8.5" fill="#191917" stroke="{GOLD}" stroke-width="2"/>')
    for i in (2, 8, 14):
        x, _ = pin_at(qx, qy, i, 0, 0)
        s.append(f'<line x1="{x + 4}" y1="{qy + 14}" x2="{x + 4}" y2="{by - 66}" stroke="{GOLD}" stroke-width="1.4" stroke-dasharray="4 4"/>')
        s.append(arrowhead(x + 4, by - 66, "down", GOLD))

    # Leaders to the labels.
    labels = []
    def leader(px, py, ly, title, text, colour=LINE):
        s.append(f'<path d="M{px:.1f},{py:.1f} L800,{ly + 12} L836,{ly + 12}" fill="none" stroke="{colour}" stroke-width="1.1" opacity=".75"/>')
        s.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="3" fill="{colour}"/>')
        labels.append(f'<div class="lbl" style="left:846px; top:{ly}px"><b style="color:{colour}">{title}</b><span>{text}</span></div>')

    qx15, qy15 = pin_at(qx, qy, 15, 0, query[15])
    leader(qx15 + 12, qy15, 452, "the query", "pressed the same way, then held up against every row", GOLD)
    rx, ry = pin_at(bx, by, 15, 1, depths[1][15])
    leader(rx + 12, ry, 548, "a row: one partition", "a paragraph of the document, pressed into sixteen pins", GOLD)
    cx, cy = pin_at(bx, by, 15, 4, depths[4][15])
    leader(cx + 12, cy, 644, "a column: one slice", "64 of the vector’s 1,024 numbers, the same 64 in every row", BLUE)
    labels.append(f'<div class="lbl" style="left:846px; top:732px; width:420px"><b style="color:{LINE}">a pin’s depth: the notch it chose</b><span>the notch’s number is all a row keeps. Hold the query’s pin beside it, and the gap between them is that column’s distance</span></div>')
    # One column in profile: the row's pin in its notch, the query's pin beside it, and the gap.
    ix, iy = 1316, 760
    s.append(f'<rect x="{ix}" y="{iy - 18}" width="10" height="58" rx="3" fill="#0d0d0c" stroke="#3a3936"/>')
    for n in range(4):
        tx = ix + 40 + n * 38
        s.append(f'<line x1="{tx}" y1="{iy - 7}" x2="{tx}" y2="{iy + 7}" stroke="#8b8a84" stroke-width="1.4"/>')
        s.append(f'<text x="{tx}" y="{iy - 12}" text-anchor="middle" font-family="{MONO}" font-size="10.5" fill="{LINE if n == 1 else "#77756f"}">{n}</text>')
    s.append(f'<line x1="{ix + 10}" y1="{iy}" x2="{ix + 40 + 38}" y2="{iy}" stroke="#6d6f74" stroke-width="2.4"/>')
    s.append(f'<circle cx="{ix + 40 + 38}" cy="{iy}" r="9.5" fill="url(#pinhead)"/>')
    qx2 = ix + 40 + 2.7 * 38
    s.append(f'<line x1="{ix + 10}" y1="{iy + 24}" x2="{qx2:.1f}" y2="{iy + 24}" stroke="{GOLD}" stroke-width="2" opacity=".7"/>')
    s.append(f'<circle cx="{qx2:.1f}" cy="{iy + 24}" r="8.5" fill="#191917" stroke="{GOLD}" stroke-width="2"/>')
    s.append(f'<path d="M{ix + 40 + 38},{iy + 44} L{ix + 40 + 38},{iy + 50} L{qx2:.1f},{iy + 50} L{qx2:.1f},{iy + 44}" fill="none" stroke="{GOLD}" stroke-width="1.4"/>')
    s.append(f'<text x="{(ix + 78 + qx2) / 2:.1f}" y="{iy + 66}" text-anchor="middle" font-family="{MONO}" font-size="11" fill="{GOLD}">the gap: this column’s reading</text>')
    s.append(f'<text x="{ix + 92}" y="{iy + 4}" font-family="{MONO}" font-size="10" fill="#8b8a84">row</text>')
    s.append(f'<text x="{qx2 + 14:.1f}" y="{iy + 28}" font-family="{MONO}" font-size="10" fill="{GOLD}">query</text>')
    fx, fy = bx + PIN_COLS * PIN_DX + PIN_ROWS * SKEW + 30, by + PIN_ROWS * PIN_DY - 30
    leader(fx, fy, 836, "the board: the document’s index", "every paragraph’s pins, in memory; its notches learned from them all", "#8b8a84")

    body = f"""<style>
.lbl {{ position: absolute; width: 660px; }}
.lbl b {{ display: block; font-weight: 400; font-size: 21px; }}
.lbl span {{ display: block; font-size: 16px; line-height: 1.3; color: #a29f97; margin-top: 2px; }}
.pts p {{ margin: 10px 0 0; font-size: 16px; line-height: 1.36; color: #a29f97; }}
.pts p b {{ font-weight: 400; color: #ecebe5; }}
.note {{ position: absolute; font-size: 17px; line-height: 1.38; color: #a29f97; }}
.note b {{ font-weight: 400; color: #ecebe5; }}
</style>
{card(70, 372, 1460, 600, "")}
<svg width="{W}" height="1500">{"".join(s)}</svg>
{"".join(labels)}
{card(70, 996, 473, 176, head(step(1) + "Press", GOLD, "FILING"))}
<div class="label pts" style="left:94px; top:1046px; width:425px">
  <p>A paragraph’s vector pushes its row of pins out. <b>Each pin settles in the nearest notch</b>, so the row keeps the shape in sixteen small numbers and lets the vector go.</p>
</div>
{card(563, 996, 473, 176, head(step(2) + "The notches", GOLD, "THE CODEBOOKS"))}
<div class="label pts" style="left:587px; top:1046px; width:425px">
  <p>Each column’s notches are cut from <b>this document’s own paragraphs</b>, where their pins tend to land. A new document gets its own board, with notches of its own.</p>
</div>
{card(1056, 996, 474, 176, head(step(3) + "Hold it up", GOLD, "SEARCH"))}
<div class="label pts" style="left:1080px; top:1046px; width:426px">
  <p>Press the query, then measure, once per column, how far each notch sits from the query’s pin: <b>a ruler per column, the table</b>. A row’s distance is its sixteen gaps, added; the smallest is the closest paragraph.</p>
</div>
<div class="note" style="left:70px; top:1198px; width:1460px"><b>Faster</b>, because a row is read in sixteen glances at a ruler cut once, not measured against the query’s 1,024 numbers; and the whole board fits in memory. <b>Still right</b>, because paragraphs that press alike land in the same notches: what is near stays near. One honest caveat: a real notch is a place in 64 dimensions, not a mark on a line, so notch 2 is not “between” 1 and 3. That is why the ruler measures the query to every notch, rather than subtracting notch numbers.</div>"""
    return plate("pin-board.png", 1350, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE PARTITION INDEX, BY HAND",
                 "A pin board", "a document pressed into pins: each paragraph keeps its shape, not its vector",
                 body, "an analogy for partition-index.png: 16 pins a row, k notches a pin, one board per document")


# MARK: Training the notches (PartitionQuantizer.train, and a query's way in)

# PartitionQuantizer: k = the largest power of two at most n / 39, within 2…65,536; fewer vectors than k
# and the vectors are the notches; k-means++ seeding, at most 20 rounds, stopping when no centroid moves
# more than 0.001; an empty notch is reseeded; codes and errors from the same pass; a threshold of
# mean + 1.5σ, at least 8.0. A query is embedded with the query role, must match the stamped embedder and
# the codebook's width, and is never quantized: it meets the notches at full precision.
TRAIN_STEPS = [
    ("embed", "voyage-4-nano, document role: one 1024-d vector a paragraph", "model"),
    ("size k", "the largest power of two at most n ÷ 39, from 2 to 65,536; fewer paragraphs than k, and they are the notches", ""),
    ("seed", "k-means++: the first notch at random, each next where pins sit farthest from any", ""),
    ("settle", "each pin to its nearest notch, each notch to its pins’ mean; at most 20 rounds, still at 0.001", ""),
    ("press", "the codes come out of the same pass: sixteen a paragraph, and each one’s error back to its notches", "vectors"),
    ("threshold", "mean + 1.5σ of those errors, and never under 8.0: the board’s own sense of near", ""),
]
QUERY_FLOW = [("“who leads Joltvault?”", ""), ("voyage-4-nano", "query role"), ("the same model", "stamp checked"),
              ("1,024 numbers", "never pressed"), ("sixteen slices", "the same cuts"), ("this board’s notches", "a ruler each")]
WHY_OWN = [
    ("Notches that fit", "a document’s paragraphs share a voice, so a few notches hold them: k is 2 to 64 for today’s documents."),
    ("Nothing shared", "a board is cut only from its own document; no one’s paragraphs shape another’s notches, in any lane."),
    ("Forgetting is clean", "removing a document drops its board, notches and all; nothing of it lingers in a shared structure."),
    ("No warm-up, no drift", "it works from the first document, and filing one never retrains another: no stale global notches."),
    ("Its own sense of near", "each board’s threshold comes from its own errors, tight for a focused note, loose for a sprawling one."),
    ("The price", "each board carries its own notches, 16 × k × 64 floats, and a query cuts a ruler per candidate board: so the graph narrows first."),
]


def settle_frames(rng):
    """One column's pins and its notches after seeding, two rounds, and at rest: real k-means, in one depth."""
    centres = [0.15, 0.42, 0.66, 0.88]
    pins = sorted(min(.98, max(.02, centres[i % 4] + rng.gauss(0, .05))) for i in range(18))
    notches = [pins[1]]                                    # k-means++: the first at random, each next by D²
    while len(notches) < 4:
        d2 = [min((p - c) ** 2 for c in notches) for p in pins]
        target, acc = rng.random() * sum(d2), 0.0
        for p, w in zip(pins, d2):
            acc += w
            if acc >= target:
                notches.append(p)
                break
    frames = [("seeded", list(notches))]
    for round_ in range(1, 20):
        groups = [[] for _ in notches]
        for p in pins:
            groups[min(range(4), key=lambda j: abs(notches[j] - p))].append(p)
        moved = [sum(g) / len(g) if g else notches[j] for j, g in enumerate(groups)]
        shift = max(abs(a - b) for a, b in zip(moved, notches))
        notches = moved
        if round_ in (1, 2):
            frames.append((f"round {round_}", list(notches)))
        if shift < 0.001:
            break
    frames.append((f"still, after {round_}", notches))
    return pins, frames


def training():
    rng = random.Random(514)                    # a run that moves visibly and settles one notch to a bunch
    s, labels = [], []

    # ① The regime: six stages, and one column settling beneath them.
    steps_html = ""
    for n, (name, text, store_name) in enumerate(TRAIN_STEPS):
        x = 96 + n * 238
        chip = store(store_name) if store_name else ""
        steps_html += f'<div class="tstep" style="left:{x}px; top:430px"><h5><span class="step">{n + 1}</span>{name}</h5><p>{text}</p><div class="stores">{chip}</div></div>'
        if n < len(TRAIN_STEPS) - 1:
            s.append(reply(x + 220, x + 234, 505, DIAL, width=1.3))
    pins, frames = settle_frames(rng)
    fy, fh, fw = 660, 118, 330
    jitter = [rng.uniform(-7, 7) for _ in pins]
    previous = None
    for f, (name, notches) in enumerate(frames):
        fx = 96 + f * (fw + 29)
        X = lambda d: fx + 18 + d * (fw - 36)
        s.append(f'<rect x="{fx}" y="{fy}" width="{fw}" height="{fh}" rx="10" fill="rgba(0,0,0,.14)" stroke="rgba(255,255,255,.07)"/>')
        base = fy + 62
        s.append(f'<line x1="{fx + 14}" y1="{base}" x2="{fx + fw - 14}" y2="{base}" stroke="#3a3936" stroke-width="1"/>')
        if previous:
            for old, new_ in zip(previous, notches):
                if abs(X(old) - X(new_)) > 3:
                    s.append(f'<line x1="{X(old):.1f}" y1="{fy + 26}" x2="{X(old):.1f}" y2="{fy + 92}" stroke="{GOLD}" stroke-width="1.2" stroke-dasharray="2 4" opacity=".35"/>')
                    s.append(f'<line x1="{X(old):.1f}" y1="{fy + 20}" x2="{X(new_) + (-5 if new_ > old else 5):.1f}" y2="{fy + 20}" stroke="{GOLD}" stroke-width="1.2" opacity=".8"/>')
                    s.append(arrowhead(X(new_) + (-5 if new_ > old else 5), fy + 20, "right" if new_ > old else "left", GOLD))
        for c in notches:
            s.append(f'<line x1="{X(c):.1f}" y1="{fy + 30}" x2="{X(c):.1f}" y2="{fy + 92}" stroke="{GOLD}" stroke-width="1.8"/>')
        for p, jy in zip(pins, jitter):
            s.append(f'<circle cx="{X(p):.1f}" cy="{base + jy:.1f}" r="3.6" fill="#9a9ca1"/>')
        labels.append(wire(fx + 14, fy + fh - 20, name, GOLD if f == len(frames) - 1 else "#8b8a84"))
        if f < len(frames) - 1:
            s.append(reply(fx + fw + 4, fx + fw + 25, fy + fh / 2, DIAL, width=1.3))
        previous = notches
    labels.append(wire(96, fy - 24, "one column, settling: the same pins in every frame; the gold notches move to where the pins bunch, then stop", "#77756f"))

    # ② A query's way in.
    flow = ""
    for n, (name, note) in enumerate(QUERY_FLOW):
        x = 96 + n * 236
        flow += f'<div class="qstep" style="left:{x}px; top:932px"><b>{name}</b><span>{note}</span></div>'
        if n < len(QUERY_FLOW) - 1:
            s.append(reply(x + 214, x + 232, 958, GOLD, width=1.4))

    tiles = "".join(f'<div class="why2"><b>{t}</b><span>{d}</span></div>' for t, d in WHY_OWN)
    body = f"""<style>
.tstep {{ position: absolute; width: 220px; height: 150px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.1); border-radius: 11px; padding: 10px 12px; background: rgba(255,255,255,.02); }}
.tstep h5 {{ margin: 0; font-weight: 400; font-size: 18px; color: #e3e1da; display: flex; align-items: center; }}
.tstep p {{ margin: 6px 0 0; font-size: 14px; line-height: 1.3; color: #a29f97; }}
.stores {{ position: absolute; left: 12px; bottom: 9px; display: flex; gap: 5px; }}
.store {{ font-family: {MONO}; font-style: normal; font-size: 10.5px; border: 1px solid; border-radius: 4px; padding: 1px 6px; }}
.qstep {{ position: absolute; width: 214px; height: 54px; box-sizing: border-box; border: 1px solid rgba(199,166,89,.35); border-radius: 10px; padding: 7px 12px; }}
.qstep b {{ display: block; font-weight: 400; font-size: 16.5px; color: #ecebe5; white-space: nowrap; }}
.qstep span {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11px; color: #8b8a84; margin-top: 2px; }}
.cap {{ position: absolute; font-size: 16px; line-height: 1.36; color: #a29f97; }}
.cap b {{ font-weight: 400; color: #ecebe5; }}
.whys {{ position: absolute; display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }}
.why2 {{ border: 1px solid rgba(255,255,255,.09); border-radius: 10px; padding: 11px 14px; }}
.why2 b {{ display: block; font-weight: 400; font-size: 19px; color: #ecebe5; }}
.why2 span {{ display: block; font-size: 15px; line-height: 1.32; color: #a29f97; margin-top: 4px; }}
.board {{ display: inline-block; margin-left: 14px; transform: translateY(-4px); font-family: {MONO}; font-style: normal; font-size: 11px; color: {GOLD}; border: 1px solid rgba(199,166,89,.4); border-radius: 12px; padding: 2px 10px; white-space: nowrap; }}
</style>
{card(70, 372, 1460, 448, head(step(1) + "The training regime" + board("cutting the notches"), GOLD, "ONCE, WHEN A DOCUMENT IS FILED"))}
{steps_html}
{card(70, 844, 1460, 254, head(step(2) + "A query, translated" + board("holding the query up"), GOLD, "EVERY SEARCH"))}
{flow}
<div class="cap" style="left:96px; top:1006px; width:1408px"><b>The query is never pressed.</b> It is embedded by the same model the board was built from, with the query role, so a question lands where its answers sit; then it is cut at the same sixteen places and measured, at full precision, against this board’s notches. Only the stored paragraphs are approximate. A query from another model is refused, and one of another width scores nothing.</div>
{card(70, 1122, 1460, 300, head(step(3) + "Why each document trains its own" + board("one board per document"), GOLD, "THE PARTITION INDEX"))}
<div class="label whys" style="left:96px; top:1178px; width:1408px">{tiles}</div>
<svg width="{W}" height="1600">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("training.png", 1500, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE PARTITION INDEX · TRAINING",
                 "Training the notches", "each document cuts its own, and a query is measured against them as it is",
                 body, "the frames are a real k-means run on illustrative pins; the rules are PartitionQuantizer’s")


# MARK: One impossible table (why lookup tables)

# The idea in PartitionQuantizer's first lines, then (Seer, 2025-11-13) and now. Seer's history: LSH bucketing
# (2025-11-01), the first quantizer (11-13), LSH removed for one index per document (11-15), codebooks that
# scale with the document (2026-03-07), 1024 dimensions in 16 slices (03-11).
LUT_HISTORY = [
    ("2025-11-01", "buckets", "a vector hashed to a bucket; search looked in its own"),
    ("2025-11-13", "small tables", "384 numbers in 8 slices: the first quantizer"),
    ("2025-11-15", "one per document", "buckets removed; each document its own index"),
    ("2026-03-07", "tables that grow", "k scales with the document: n ÷ 39"),
    ("2026-03-11", "1,024 in 16", "today’s cut: sixteen slices of 64"),
]


def lut():
    s, labels = [], []
    # ② The impossible table, and sixteen small ones.
    gx, gy = 836, 742
    for r in range(9):                                   # one table, a row per possible vector, fading out
        op = max(.05, 1 - r * .11)
        s.append(f'<rect x="{gx}" y="{gy + r * 20}" width="300" height="16" rx="3" fill="rgba(255,255,255,{.06 * op:.3f})" stroke="rgba(255,255,255,{.18 * op:.3f})"/>')
    s.append(f'<text x="{gx + 150}" y="{gy + 192}" text-anchor="middle" font-family="{MONO}" font-size="12" fill="#77756f">⋮ and on, to 2²⁵⁶ rows</text>')
    sx0 = 1230
    for i in range(16):
        for j in range(4):
            s.append(f'<rect x="{sx0 + i * 18}" y="{gy + 30 + j * 22}" width="14" height="18" rx="3" fill="{shade(random.Random(i * 7 + j).random())}"/>')
    s.append(f'<rect x="{sx0 + 2 * 18 - 2}" y="{gy + 27}" width="18" height="{4 * 22 + 2}" rx="4" fill="none" stroke="{GOLD}" stroke-width="1.6"/>')
    labels.append(wire(sx0, gy + 2, "16 small tables, k rows each", GOLD))
    labels.append(wire(gx, gy - 22, "one table for whole vectors", "#8b8a84"))

    # ① A times table: 9 × 7, read rather than worked out.
    tx, ty0, c = 110, 728, 21
    for r in range(1, 10):
        for k in range(1, 10):
            hit = (r, k) == (9, 7)
            near = r == 9 or k == 7
            s.append(f'<rect x="{tx + (k - 1) * c}" y="{ty0 + (r - 1) * c}" width="{c - 3}" height="{c - 3}" rx="3" '
                     f'fill="{"rgba(199,166,89,.22)" if hit else "rgba(255,255,255,.035)" if near else "rgba(255,255,255,.015)"}" '
                     f'stroke="{GOLD if hit else "rgba(255,255,255,.08)"}" stroke-width="{1.6 if hit else 1}"/>')
            s.append(f'<text x="{tx + (k - 1) * c + (c - 3) / 2}" y="{ty0 + (r - 1) * c + 16}" text-anchor="middle" font-family="{MONO}" '
                     f'font-size="10.5" fill="{GOLD if hit else "#8b8a84" if near else "#5d5b56"}">{r * k}</text>')
    labels.append(wire(tx, ty0 - 22, "a times table: 9 × 7 is read, not worked out", "#8b8a84"))
    labels.append(f'<div class="label pts" style="left:{tx + 9 * c + 30}px; top:{ty0 - 6}px; width:{780 - tx - 9 * c - 50}px"><p>81 answers, worked out once. Every question after that costs a glance.</p><p>Search has the same shape: a query against a paragraph is 1,024 multiplications, and a table read is one. The catch: the table must hold <b>every question you might ask</b>. 81 rows for two digits; for a vector, far too many.</p></div>')

    # ④ How it got here.
    ty, tx0, tx1 = 1136, 836, 1504
    s.append(f'<line x1="{tx0}" y1="{ty}" x2="{tx1}" y2="{ty}" stroke="#4a4944" stroke-width="1.4"/>')
    step_x = (tx1 - tx0) / (len(LUT_HISTORY) - 1)
    for n, (when, name, text) in enumerate(LUT_HISTORY):
        x = tx0 + n * step_x
        s.append(f'<circle cx="{x}" cy="{ty}" r="5.5" fill="#191917" stroke="{GOLD if n else DIAL}" stroke-width="2"/>')
        top = ty + 14 if n % 2 == 0 else ty - 92
        align = "left" if n == 0 else "right" if n == len(LUT_HISTORY) - 1 else "center"
        shift = 0 if n == 0 else -150 if n == len(LUT_HISTORY) - 1 else -75
        labels.append(f'<div class="tl2" style="left:{x + shift}px; top:{top}px; text-align:{align}"><code>{when}</code><b>{name}</b><span>{text}</span></div>')

    body = f"""<style>
.quote2 {{ position: absolute; font-family: {MONO}; font-style: normal; font-size: 15px; line-height: 1.7; color: #dcdad3; }}
.quote2 em {{ font-family: "Playfair", Georgia, serif; font-style: italic; font-size: 13px; color: #77756f; letter-spacing: .18em; display: block; margin-bottom: 4px; }}
.quote2 b {{ font-weight: 400; color: {GOLD}; }}
.pts p {{ margin: 10px 0 0; font-size: 16px; line-height: 1.38; color: #a29f97; }}
.pts p b {{ font-weight: 400; color: #ecebe5; }}
.pts code {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #c3c0b7; }}
.tl2 {{ position: absolute; width: 150px; }}
.tl2 code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11px; color: #77756f; }}
.tl2 b {{ display: block; font-weight: 400; font-size: 17px; color: #ecebe5; }}
.tl2 span {{ display: block; font-size: 13.5px; line-height: 1.25; color: #a29f97; }}
.two {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 6px; }}
.two > div {{ border: 1px solid rgba(255,255,255,.09); border-radius: 10px; padding: 10px 13px; }}
.two b {{ display: block; font-weight: 400; font-size: 18px; color: #ecebe5; }}
.two code {{ display: block; font-family: {MONO}; font-style: normal; font-size: 11.5px; color: {GOLD}; margin-top: 2px; }}
.two span {{ display: block; font-size: 14.5px; line-height: 1.3; color: #a29f97; margin-top: 4px; }}
.board {{ display: inline-block; margin-left: 14px; transform: translateY(-4px); font-family: {MONO}; font-style: normal; font-size: 11px; color: {GOLD}; border: 1px solid rgba(199,166,89,.4); border-radius: 12px; padding: 2px 10px; white-space: nowrap; }}
</style>
{card(70, 372, 1460, 176, head("The line it started from", GOLD, "PARTITIONQUANTIZER · ITS FIRST COMMENT"))}
<div class="quote2" style="left:96px; top:430px; width:680px"><em>SEER · 2025-11-13</em>// Split 384-dim vector into 8 chunks of 48 dims<br>// Create 256-entry codebook for each chunk<br>// Result: <b>8 small LUTs instead of one impossible LUT</b></div>
<div class="quote2" style="left:816px; top:430px; width:690px"><em>THREAD · TODAY</em>// Split 1024-dim vector into 16 chunks of 64 dims<br>// Create codebook for each chunk (size scaled dynamically at train time)<br>// Result: <b>16 small LUTs instead of one impossible LUT</b></div>
{card(70, 572, 720, 380, head(step(1) + "What a lookup table buys", GOLD, "WORK, DONE ONCE"))}
<div class="label pts" style="left:96px; top:624px; width:670px">
  <p>A lookup table <b>trades arithmetic for memory</b>: work every answer out once, then read it. A times table is one; nobody multiplies 9 × 7 twice.</p>
</div>
{card(810, 572, 720, 380, head(step(2) + "The impossible table", GOLD, "AND THE WAY AROUND IT"))}
<div class="label pts" style="left:836px; top:624px; width:670px">
  <p>One table that gave every possible vector its own row would need <b>65,536<sup>16</sup> = 2<sup>256</sup> rows</b>, a number 78 digits long. Cut the vector into sixteen slices and give each slice its own table of k rows: sixteen small tables, a million rows at most, that together still name all 2<sup>256</sup> combinations.</p>
</div>
{card(70, 976, 720, 290, head(step(3) + "Two tables, two jobs" + board("notches and ruler"), GOLD))}
<div class="label two" style="left:96px; top:1028px; width:670px">
  <div><b>the codebook</b><code>code → notch</code><span>where each notch sits; cut once per document, from its own paragraphs, and kept</span></div>
  <div><b>the distance table</b><code>code → distance</code><span>how far the query is from each notch; cut once per query, per document, and thrown away</span></div>
</div>
<div class="label pts" style="left:96px; top:1162px; width:670px"><p>A paragraph is stored as sixteen <b>addresses into the first table</b>, and scored as sixteen <b>reads from the second</b>. That is the whole idea: nothing is multiplied per paragraph at all.</p></div>
{card(810, 976, 720, 290, head(step(4) + "How it got here", GOLD, "SEER, THEN THREAD"))}
<svg width="{W}" height="1500">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("lookup-tables.png", 1350, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THE PARTITION INDEX · WHY TABLES",
                 "One impossible table", "the idea in the first commit: many small lookup tables, instead of one that could never exist",
                 body, "the comments are PartitionQuantizer’s own, then and now; the dates are Seer’s and Thread’s history")


ALL = ["sewn_thread_seam", "thread_inside", "partition_index_filing", "partition_index_search", "first_index", "lineage", "credibility", "threads", "funnel", "pins", "training", "lut"]


def main():
    targets = sys.argv[2:] or ALL
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        for target in targets:
            name, height, page = globals()[target]()
            with tempfile.NamedTemporaryFile("w", suffix=".html", dir=HERE, delete=False, encoding="utf-8") as f:
                f.write(page)
                source = f.name
            try:
                tab = browser.new_page(device_scale_factor=2, viewport={"width": W, "height": height})
                tab.goto("file://" + source)
                tab.wait_for_selector("body[data-height]", state="attached")
                tab.set_viewport_size({"width": W, "height": round(float(tab.evaluate("document.body.dataset.height")))})
                tab.wait_for_timeout(100)
                path = os.path.join(OUT, name)
                tab.screenshot(path=path)
                tab.close()
            finally:
                os.unlink(source)
            with Image.open(path) as im:
                print(f"{name}: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")
        browser.close()


if __name__ == "__main__":
    main()
