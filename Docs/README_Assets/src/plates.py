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


def plate(name, height, caption, title, sub, body, tag):
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {height}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97; font-variant-numeric: lining-nums;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 50px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 68px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 39.5px; padding-left: 40px; top: 104px; font-size: 104px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; white-space: nowrap; }}
.sub {{ position: absolute; left: 69px; top: 222px; font-size: 32px; color: #9b9991; white-space: nowrap; }}
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


def partition_index():
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
    # Slice 3 of every partition, drawn flat: four clusters, a centroid at the centre of each.
    bx0, by0, bw, bh = 104, 884, 440, 230
    centres = [(0.2, 0.3), (0.62, 0.24), (0.3, 0.76), (0.8, 0.7)]
    points = [[(min(.97, max(.03, cx + rng.gauss(0, .075))), min(.95, max(.05, cy + rng.gauss(0, .09)))) for _ in range(40)]
              for cx, cy in centres]
    means = [(sum(x for x, _ in c) / len(c), sum(y for _, y in c) / len(c)) for c in points]
    at = lambda x, y: (bx0 + x * bw, by0 + y * bh)
    s.append(f'<rect x="{bx0 - 8}" y="{by0 - 8}" width="{bw + 16}" height="{bh + 16}" rx="10" fill="rgba(0,0,0,.12)" stroke="rgba(255,255,255,.07)"/>')
    for cluster in points:
        for x, y in cluster:
            X, Y = at(x, y)
            s.append(f'<circle cx="{X:.1f}" cy="{Y:.1f}" r="2.6" fill="#6d6b64"/>')
    for j, (x, y) in enumerate(means):
        X, Y = at(x, y)
        s.append(f'<circle cx="{X:.1f}" cy="{Y:.1f}" r="8" fill="none" stroke="{GOLD}" stroke-width="1.8"/>'
                 f'<circle cx="{X:.1f}" cy="{Y:.1f}" r="2.4" fill="{GOLD}"/>')
        labels.append(wire(X + 12, Y - 22, f"c{'₀₁₂₃'[j]}", GOLD))
    p1 = at(means[1][0] - 0.09, means[1][1] + 0.13)
    c1 = at(*means[1])
    s.append(f'<line x1="{p1[0]:.1f}" y1="{p1[1]:.1f}" x2="{c1[0]:.1f}" y2="{c1[1]:.1f}" stroke="{GOLD}" stroke-width="1.4" stroke-dasharray="3 3"/>')
    s.append(f'<circle cx="{p1[0]:.1f}" cy="{p1[1]:.1f}" r="5" fill="{LINE}"/>')
    labels.append(wire(p1[0] - 34, p1[1] + 10, "p₁’s slice", LINE))
    axis(bx0 - 8, 850, "slice 3 of all 160 partitions, 64 dimensions drawn in two")
    labels.append(f'<div class="caption2 small" style="left:96px; top:{by0 + bh + 18}px; width:460px">k-means put each centroid at the centre of a cluster of the document’s own slices; p₁’s slice is replaced by the nearest, c₁</div>')
    # p₁, its codes, and the vector the codes stand for.
    rx = 600
    v1 = vector()
    approx = [min(1, max(0, v + rng.uniform(-.09, .09))) for v in v1]
    axis(rx, 850, "p₁’s vector · 1024 floats · 4 KB", LINE)
    s.append(strip(rx, 874, v1, h=20, mark=SLICE))
    rsx = rx + SLICE * CELL_W + CELL_W / 2
    s.append(dotted(rsx, 898, rsx, 941))
    axis(rsx + 12, 910, "each slice to its nearest centroid", GOLD)
    s.append(codes_row(rx, 944, CODES, mark=SLICE))
    axis(rx + SUBVECTORS * CELL_W + 12, 948, "32 bytes", GOLD)
    s.append(dotted(rsx, 974, rsx, 1011))
    axis(rsx + 12, 980, "each code back to its centroid")
    s.append(strip(rx, 1014, approx, h=20, mark=SLICE))
    axis(rx, 1042, "p̂₁ · what the codes stand for: p₁ rebuilt from sixteen centroids", LINE)
    s.append(reply(bx0 + bw + 12, rx - 8, 957, GOLD, width=1.4))
    axis(bx0 + bw + 16, 935, "c₁ → 1", GOLD)
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
{card(70, 372, 1460, 374, head(step(1) + "A document becomes sixteen codebooks", GOLD, "ONCE, WHEN THE DOCUMENT IS FILED"))}
<div class="caption2" style="left:96px; top:688px; width:1410px; font-size:16px">A partition is a segment of its document, a paragraph or a section, with one vector. Every vector, and every query, is cut at the same boundaries into sixteen 64-d slices; each codebook is trained on one slice of <b>all the document’s partitions together</b>, so the document’s sixteen codebooks are shared by every partition in it. k is the largest power of two at most n ÷ 39.</div>
{card(70, 770, 1460, 448, head(step(2) + "A partition becomes sixteen codes", GOLD, "ITS COMPRESSED EMBEDDING"))}
{card(70, 1242, 720, 336, head("Where each part lives", "", "MEMORY · DISK"))}
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
{card(810, 1242, 720, 336, head(step(3) + "The ceiling: 65,536, for now", GOLD, "UINT16 CODES"))}
<div class="tiles" style="left:830px; top:1294px; width:680px">
  {tile("65,536", "centroids one UInt16 code can name: the most a codebook may hold today")}
  {tile("2<sup>256</sup>", "codes one partition can take: 65,536 choices in each of sixteen slices")}
  {tile("2,555,904", "partitions before a document’s k reaches 65,536: some 3.8 billion characters, at 1,500 a partition")}
  {tile("UInt8", "what it can come down to: 16 bytes a partition while k ≤ 256. Today’s documents sit at k = 2 to 64")}
</div>
{card(70, 1602, 1460, 400, head(step(4) + "A query finds its partition", LINE, "PER QUERY, PER CANDIDATE DOCUMENT"))}
<svg width="{W}" height="2100">{"".join(s)}</svg>
{"".join(labels)}"""
    return plate("partition-index.png", 2074, "RAO STUDIOS · AMBIENT INTELLIGENCE INDEX · THREAD",
                 "The partition index", "one per document: its vectors become codes, and a query is answered by lookups",
                 body, "the codes and distances are illustrative; the shapes, the sizes and the rules are the code’s")


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


ALL = ["sewn_thread_seam", "thread_inside", "partition_index", "first_index", "lineage", "credibility"]


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
                tab.wait_for_timeout(200)
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
