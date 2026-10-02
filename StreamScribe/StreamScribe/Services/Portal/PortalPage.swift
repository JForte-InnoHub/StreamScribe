import Foundation

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
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>StreamScribe</title>
<style>
:root {
  --bg: #f6f7f9;
  --panel: #ffffff;
  --panel-2: #f1f3f6;
  --text: #16181d;
  --muted: #5d6470;
  --faint: #8a909b;
  --line: #e2e5ea;
  --accent: #2f5bea;
  --accent-ink: #ffffff;
  --accent-soft: #e8eefe;
  --ok: #1f8a4c;
  --ok-soft: #e3f4ea;
  --warn: #a15c00;
  --warn-soft: #fdf0dc;
  --bad: #c0352b;
  --bad-soft: #fbe6e4;
  --pin: #fff4c2;
  --shadow: 0 1px 2px rgba(16, 24, 40, .06), 0 1px 3px rgba(16, 24, 40, .08);
  --radius: 10px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111317;
    --panel: #1a1d23;
    --panel-2: #22262d;
    --text: #e8eaee;
    --muted: #a3a9b4;
    --faint: #767d89;
    --line: #2c3139;
    --accent: #6f93ff;
    --accent-ink: #0d1020;
    --accent-soft: #1e2a4a;
    --ok: #4cc27f;
    --ok-soft: #173325;
    --warn: #f0a44a;
    --warn-soft: #3a2b16;
    --bad: #ff7a6e;
    --bad-soft: #3d1d1a;
    --pin: #3d3614;
    --shadow: 0 1px 2px rgba(0, 0, 0, .4);
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: var(--bg);
  color: var(--text);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
button, input, select { font: inherit; color: inherit; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }

header.top {
  position: sticky; top: 0; z-index: 20;
  display: flex; align-items: center; gap: 12px;
  padding: 10px 20px;
  background: var(--panel);
  border-bottom: 1px solid var(--line);
}
.brand { font-weight: 700; letter-spacing: -.01em; font-size: 17px; cursor: pointer; }
.brand small { font-weight: 500; color: var(--muted); font-size: 13px; margin-left: 6px; }
.top .spacer { flex: 1; }
.who { color: var(--muted); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 32vw; }

.pill {
  min-width: 0;
  display: inline-flex; align-items: center; gap: 6px;
  padding: 3px 10px; border-radius: 999px;
  font-size: 12.5px; font-weight: 600; white-space: nowrap;
  background: var(--panel-2); color: var(--muted);
  max-width: 46vw; overflow: hidden; text-overflow: ellipsis;
}
.pill .dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; flex: none; }
.pill.ok { background: var(--ok-soft); color: var(--ok); }
.pill.busy { background: var(--accent-soft); color: var(--accent); }
.pill.warn { background: var(--warn-soft); color: var(--warn); }
.pill.bad { background: var(--bad-soft); color: var(--bad); }

main { max-width: 1180px; margin: 0 auto; padding: 20px; }
.banner {
  margin: 0 0 16px; padding: 10px 14px; border-radius: var(--radius);
  background: var(--bad-soft); color: var(--bad); font-weight: 500;
}
.banner.info { background: var(--accent-soft); color: var(--accent); }

.grid-home { display: grid; grid-template-columns: minmax(0, 420px) minmax(0, 1fr); gap: 20px; align-items: start; }
.grid-job { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 20px; align-items: start; }

.card {
  background: var(--panel); border: 1px solid var(--line);
  border-radius: var(--radius); box-shadow: var(--shadow);
}
.card > .hd { padding: 14px 16px 0; display: flex; align-items: center; gap: 10px; }
.card > .hd h2 { margin: 0; font-size: 15px; font-weight: 650; }
.card > .bd { padding: 14px 16px 16px; }
.sticky { position: sticky; top: 70px; }

.tabs { display: flex; gap: 4px; background: var(--panel-2); padding: 3px; border-radius: 8px; }
.tabs button {
  flex: 1; border: 0; background: transparent; padding: 6px 10px; border-radius: 6px;
  font-weight: 600; font-size: 13.5px; color: var(--muted); cursor: pointer;
}
.tabs button.on { background: var(--panel); color: var(--text); box-shadow: var(--shadow); }

label.f { display: block; font-size: 12.5px; font-weight: 600; color: var(--muted); margin: 12px 0 5px; }
input[type=text], input[type=url], input[type=number], select {
  width: 100%; padding: 9px 11px; border-radius: 8px;
  border: 1px solid var(--line); background: var(--panel);
}
input:focus, select:focus { outline: 2px solid var(--accent-soft); border-color: var(--accent); }
.row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
details.opts { margin-top: 12px; border-top: 1px solid var(--line); padding-top: 10px; }
details.opts summary { cursor: pointer; font-weight: 600; font-size: 13.5px; color: var(--muted); list-style: none; }
details.opts summary::before { content: "▸ "; }
details.opts[open] summary::before { content: "▾ "; }
.hint { font-size: 12.5px; color: var(--faint); margin-top: 4px; }
.tabs.seg { margin-top: 2px; }
.tabs.seg button { padding: 6px 4px; font-size: 13px; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tabs.seg button:disabled { opacity: .4; cursor: not-allowed; }
select:disabled { opacity: .6; }
.check { display: flex; gap: 9px; align-items: flex-start; margin-top: 14px; font-size: 14px; cursor: pointer; }
.check input { margin: 3px 0 0; width: 16px; height: 16px; flex: none; accent-color: var(--accent); }
.check .hint { margin-top: 1px; }
.probe { margin-top: 8px; padding: 8px 10px; border-radius: 8px; font-size: 13px; background: var(--panel-2); color: var(--muted); }
.probe .pl { display: flex; gap: 7px; align-items: baseline; font-weight: 600; }
.probe .pt { margin-top: 2px; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.probe .pm { margin-top: 2px; font-weight: 400; }
.probe.ok { background: var(--ok-soft); color: var(--ok); }
.probe.live { background: var(--accent-soft); color: var(--accent); }
.probe.bad { background: var(--warn-soft); color: var(--warn); }
.probe .spin { width: 9px; height: 9px; border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: rot .8s linear infinite; flex: none; align-self: center; }
@keyframes rot { to { transform: rotate(360deg); } }
.dl { padding: 10px 12px; border-radius: 8px; background: var(--panel-2); font-size: 13.5px; }
.dl .dlh { font-weight: 600; }
.dl .btn { margin-top: 8px; }
.dl .progress { margin-top: 8px; }
.dl.bad { background: var(--warn-soft); color: var(--warn); }

.drop {
  margin-top: 12px; border: 1.5px dashed var(--line); border-radius: var(--radius);
  padding: 22px 14px; text-align: center; color: var(--muted); cursor: pointer;
  background: var(--panel-2);
}
.drop.over { border-color: var(--accent); background: var(--accent-soft); color: var(--accent); }
.drop strong { color: var(--text); }

.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  border: 1px solid var(--line); background: var(--panel); color: var(--text);
  padding: 8px 14px; border-radius: 8px; font-weight: 600; font-size: 14px; cursor: pointer;
  white-space: nowrap;
}
.btn:hover { background: var(--panel-2); }
.btn:disabled { opacity: .5; cursor: default; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); }
.btn.primary:hover { filter: brightness(1.06); }
.btn.danger { color: var(--bad); }
.btn.sm { padding: 5px 10px; font-size: 13px; }
.btn.block { width: 100%; margin-top: 16px; padding: 10px 14px; }

.progress { height: 6px; background: var(--panel-2); border-radius: 99px; overflow: hidden; }
.progress > div { height: 100%; background: var(--accent); width: 0; transition: width .3s ease; }
.progress.ind > div { width: 30%; animation: slide 1.4s ease-in-out infinite; }
@keyframes slide { 0% { margin-left: -30%; } 100% { margin-left: 100%; } }

.jobs-filter { margin-left: auto; }
.jobs-filter .tabs button { padding: 3px 10px; font-size: 12.5px; }
.job-list { list-style: none; margin: 0; padding: 0; }
.job-item {
  display: block; padding: 12px 16px; border-top: 1px solid var(--line); cursor: pointer; color: inherit;
}
.job-item:first-child { border-top: 0; }
.job-item:hover { background: var(--panel-2); text-decoration: none; }
.job-title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.job-meta { font-size: 12.5px; color: var(--muted); display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-top: 3px; }
.job-item .progress { margin-top: 8px; }
.empty { padding: 26px 16px; color: var(--faint); text-align: center; }

.chip { font-size: 11.5px; font-weight: 700; padding: 1px 8px; border-radius: 99px; text-transform: uppercase; letter-spacing: .03em; }
.chip.queued { background: var(--panel-2); color: var(--muted); }
.chip.preparing, .chip.running, .chip.finishing { background: var(--accent-soft); color: var(--accent); }
.chip.completed { background: var(--ok-soft); color: var(--ok); }
.chip.failed, .chip.interrupted { background: var(--bad-soft); color: var(--bad); }
.chip.cancelled { background: var(--panel-2); color: var(--faint); }

.job-head { margin-bottom: 16px; }
.back { font-size: 13.5px; font-weight: 600; display: inline-block; margin-bottom: 8px; cursor: pointer; }
.job-head h1 { margin: 0 0 4px; font-size: 22px; letter-spacing: -.01em; line-height: 1.25; word-break: break-word; }
.job-head .job-meta { font-size: 13px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-top: 12px; }
.actions select { width: auto; padding: 7px 10px; }
.msg { margin-top: 10px; font-size: 13.5px; color: var(--muted); }
.msg.bad { color: var(--bad); }

.transcript { padding: 6px 18px 18px; }
.block { padding: 12px 0 4px; border-top: 1px solid var(--line); }
.block:first-child { border-top: 0; }
.block .who2 { display: flex; align-items: baseline; gap: 8px; margin-bottom: 3px; }
.block .name { font-weight: 700; font-size: 14px; }
.block .time { font-size: 12px; color: var(--faint); font-variant-numeric: tabular-nums; }
.block p { margin: 0; line-height: 1.65; }
.seg { border-radius: 3px; cursor: pointer; }
.seg:hover { background: var(--panel-2); }
.seg.pinned { background: var(--pin); }
.seg.sel { background: var(--accent-soft); outline: 1px solid var(--accent); }
.seg.review { text-decoration: underline dotted var(--warn); text-underline-offset: 3px; }
.follow { display: flex; align-items: center; gap: 6px; font-size: 13px; color: var(--muted); margin-left: auto; }

.side h3 { margin: 0; font-size: 14px; font-weight: 650; }
.spk { display: grid; grid-template-columns: 10px 1fr auto; gap: 8px; align-items: center; margin-top: 8px; }
.spk .sw { width: 10px; height: 10px; border-radius: 50%; }
.spk input { padding: 6px 9px; font-size: 14px; }
.spk .cnt { font-size: 12px; color: var(--faint); font-variant-numeric: tabular-nums; }
.spk .src { grid-column: 2 / 4; font-size: 11.5px; color: var(--faint); margin-top: -4px; }
.pinrow { padding: 10px 0; border-top: 1px solid var(--line); }
.pinrow:first-of-type { border-top: 0; }
.pinrow .pm { font-size: 12px; color: var(--muted); display: flex; gap: 6px; align-items: center; }
.pinrow .pm .x { margin-left: auto; border: 0; background: none; cursor: pointer; color: var(--faint); font-size: 16px; line-height: 1; }
.pinrow .pt { font-size: 14px; margin-top: 3px; cursor: pointer; }

.actionbar {
  position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%);
  background: var(--text); color: var(--bg); border-radius: 12px; padding: 8px 8px 8px 14px;
  display: flex; gap: 10px; align-items: center; box-shadow: 0 8px 24px rgba(0,0,0,.25); z-index: 30;
  max-width: calc(100vw - 24px);
}
.actionbar span { font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.actionbar .btn { background: var(--bg); color: var(--text); border-color: transparent; }
.actionbar .btn.on { outline: 2px solid var(--accent); }
.actionbar .btn .ico { display: none; }
.actionbar .btn .lbl { font-size: inherit; }

/* Popover menu (speaker / more) and modal dialogs (edit text, identify). */
.menu {
  position: fixed; z-index: 45; min-width: 200px; max-width: min(340px, calc(100vw - 16px));
  background: var(--panel); color: var(--text); border: 1px solid var(--line); border-radius: 10px;
  box-shadow: 0 10px 30px rgba(0,0,0,.28); padding: 5px; max-height: 60vh; overflow: auto;
}
.menu button {
  display: flex; width: 100%; align-items: center; gap: 8px; text-align: left; border: 0; background: none;
  padding: 8px 10px; border-radius: 7px; font-size: 14px; cursor: pointer; color: inherit;
}
.menu button:hover, .menu button:focus { background: var(--panel-2); outline: none; }
.menu button:disabled { opacity: .45; cursor: default; }
.menu button.danger { color: var(--bad); }
.menu button .chk { width: 14px; flex: none; color: var(--accent); font-weight: 700; }
.menu button .sub { margin-left: auto; font-size: 12px; color: var(--faint); padding-left: 10px; }
.menu button .sw { width: 9px; height: 9px; border-radius: 50%; background: var(--spk); flex: none; }
.menu hr { border: 0; border-top: 1px solid var(--line); margin: 5px 4px; }
.menu .mh { font-size: 11.5px; font-weight: 700; color: var(--faint); text-transform: uppercase; letter-spacing: .04em; padding: 6px 10px 2px; }
.overlay { position: fixed; inset: 0; z-index: 50; background: rgba(0,0,0,.42); display: flex; align-items: center; justify-content: center; padding: 16px; }
.dlg {
  background: var(--panel); color: var(--text); border-radius: 12px; box-shadow: 0 16px 48px rgba(0,0,0,.35);
  width: 100%; max-width: 460px; max-height: min(84vh, 640px); display: flex; flex-direction: column; overflow: hidden;
}
.dlg .dh { padding: 14px 16px 10px; border-bottom: 1px solid var(--line); }
.dlg .dh h3 { margin: 0; font-size: 15px; font-weight: 650; }
.dlg .dh .hint { margin-top: 2px; }
.dlg .db { padding: 12px 16px; overflow: auto; flex: 1 1 auto; min-height: 0; }
.dlg .df { padding: 10px 16px 14px; display: flex; gap: 8px; justify-content: flex-end; align-items: center; border-top: 1px solid var(--line); flex-wrap: wrap; }
.dlg .df .grow { flex: 1; }
.dlg textarea {
  width: 100%; min-height: 120px; max-height: 40vh; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line);
  background: var(--panel); color: inherit; font: inherit; line-height: 1.5; resize: vertical;
}
.dlg textarea:focus { outline: 2px solid var(--accent-soft); border-color: var(--accent); }
.dlg .orig { margin-top: 10px; font-size: 13px; color: var(--muted); }
.dlg .orig b { color: var(--text); font-weight: 600; }
.idlist { margin: 0 -6px; }
.idlist .mh { font-size: 11.5px; font-weight: 700; color: var(--faint); text-transform: uppercase; letter-spacing: .04em; padding: 10px 10px 2px; }
.idlist button {
  display: flex; width: 100%; align-items: center; gap: 8px; text-align: left; border: 0; background: none;
  padding: 8px 10px; border-radius: 7px; font-size: 14px; cursor: pointer; color: inherit;
}
.idlist button:hover, .idlist button:focus, .idlist button.first { background: var(--panel-2); outline: none; }
.idlist button .chk { margin-left: auto; color: var(--accent); font-weight: 700; }
.idlist .none { padding: 14px 10px; color: var(--faint); font-size: 13.5px; }
.spk .src button { border: 0; background: none; padding: 0 0 0 6px; color: var(--accent); cursor: pointer; font-size: 11.5px; font-weight: 600; }
.spk .src button.danger { color: var(--bad); }
.seg.edited { text-decoration-line: underline; text-decoration-style: dotted; text-decoration-color: var(--faint); text-underline-offset: 3px; }
.seg.review { text-decoration-color: var(--warn); }
.toast {
  position: fixed; right: 18px; bottom: 18px; z-index: 40;
  background: var(--text); color: var(--bg); padding: 10px 14px; border-radius: 10px;
  font-size: 14px; box-shadow: 0 8px 24px rgba(0,0,0,.25); max-width: calc(100vw - 36px);
}
.hidden { display: none !important; }

/* Web miniplayer: pinned above the transcript while you scroll it. */
.player { position: sticky; top: 62px; z-index: 15; margin-bottom: 14px; overflow: hidden; }
.player video { display: block; width: 100%; max-height: 42vh; background: #000; }
.player.audio video { height: 54px; background: var(--panel-2); }
.player .pc { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; padding: 8px 12px; font-size: 13px; color: var(--muted); }
.player .pc select { width: auto; padding: 4px 8px; font-size: 13px; }
.player .pc label { display: flex; gap: 6px; align-items: center; cursor: pointer; }
.player .pc .grow { flex: 1; }
.player-note { padding: 12px 14px; font-size: 13.5px; color: var(--muted); }
.seg.now { background: var(--accent-soft); box-shadow: inset 0 -2px 0 var(--accent); }
.block .time.seek { cursor: pointer; }
.block .time.seek:hover { color: var(--accent); text-decoration: underline; }
.pinrow .pa { display: flex; gap: 10px; margin-top: 4px; font-size: 12.5px; }
.pinrow .pa button { border: 0; background: none; padding: 0; color: var(--accent); cursor: pointer; font-weight: 600; }
.exp { margin-top: 10px; padding: 12px 14px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--panel); max-width: 560px; }
.exp .row2 { margin-top: 2px; }
.exp .check { margin-top: 8px; }
.exp select { width: auto; max-width: 100%; }
.exp .foot { display: flex; gap: 12px; align-items: center; margin-top: 12px; font-size: 12.5px; color: var(--faint); flex-wrap: wrap; }
.exp .foot button { border: 0; background: none; padding: 0; color: var(--accent); cursor: pointer; font-size: 12.5px; }

/* Speaker colours: same palette order and hash as the Mac app's SpeakerPanel,
   so a speaker is the same colour on the Mac and on the web. */
.c0 { --spk: #007aff; } .c1 { --spk: #9a3fcb; } .c2 { --spk: #c45f00; } .c3 { --spk: #d6204a; }
.c4 { --spk: #1e8a9e; } .c5 { --spk: #1e9a33; } .c6 { --spk: #5856d6; } .c7 { --spk: #d70015; }
.c8 { --spk: #00897f; } .c9 { --spk: #8a6a45; } .cx { --spk: var(--muted); }
@media (prefers-color-scheme: dark) {
  .c0 { --spk: #0a84ff; } .c1 { --spk: #bf5af2; } .c2 { --spk: #ff9f0a; } .c3 { --spk: #ff375f; }
  .c4 { --spk: #40c8e0; } .c5 { --spk: #32d74b; } .c6 { --spk: #7d7aff; } .c7 { --spk: #ff453a; }
  .c8 { --spk: #63e6e2; } .c9 { --spk: #ac8e68; }
}
.block .name, .pinrow .pn { color: var(--spk); }
.spk .sw { background: var(--spk); }

@media (max-width: 900px) {
  .grid-home, .grid-job { grid-template-columns: minmax(0, 1fr); }
  .player { top: 52px; }
  .player video { max-height: 30vh; }
  .sticky { position: static; }
  main { padding: 14px; }
  .who { display: none; }
}
@media (max-width: 520px) {
  header.top { padding: 10px 14px; gap: 8px; }
  .pill { max-width: none; flex: 1 1 auto; }
  .top .spacer { display: none; }
  .wide { display: none; }
  .brand small { display: none; }
  .row2 { grid-template-columns: 1fr; }
  .actionbar #actionText { display: none; }
  .actionbar { padding: 8px; gap: 5px; }
  .actionbar .btn { padding: 5px 8px; }
  .actionbar .btn .ico { display: inline; }
  .actionbar .btn .ico + .lbl, .actionbar #spkSelBtn .lbl { display: none; }
  .actionbar #clipSelBtn { display: none !important; }
  .transcript { padding: 4px 12px 14px; }
}
</style>
</head>
<body>
<header class="top">
  <div class="brand" id="brand">StreamScribe<small>Transcription portal</small></div>
  <div class="spacer"></div>
  <span class="pill" id="enginePill"><span class="dot"></span><span id="engineText">Connecting…</span></span>
  <button class="btn sm hidden" id="pauseBtn"></button>
  <span class="who" id="who"></span>
</header>
<main id="main">
  <div class="banner hidden" id="banner"></div>
  <div id="view"></div>
</main>
<div class="actionbar hidden" id="actionbar">
  <span id="actionText">1 sentence selected</span>
  <button class="btn sm hidden" id="playSelBtn" title="Play from here"><span class="ico">▶</span><span class="lbl">Play</span></button>
  <button class="btn sm" id="pinSelBtn">Pin quote</button>
  <button class="btn sm" id="spkSelBtn" title="Move to another speaker">Speaker<span class="lbl"> ▾</span></button>
  <button class="btn sm" id="editSelBtn" title="Edit the text">Edit</button>
  <button class="btn sm hidden" id="clipSelBtn">Clip</button>
  <button class="btn sm" id="moreSelBtn" title="More"><span class="ico">⋯</span><span class="lbl">More ▾</span></button>
  <button class="btn sm" id="multiSelBtn" title="Select more sentences (or shift-click / ctrl-click)">+</button>
  <button class="btn sm" id="clearSelBtn" title="Clear selection"><span class="ico">✕</span><span class="lbl">Cancel</span></button>
</div>
<div class="toast hidden" id="toast"></div>
<script>
"use strict";

const S = {
  status: null,
  jobs: [],
  jobFilter: "all",
  mode: "url",
  file: null,
  uploading: false,
  view: null,
  jobId: null,
  job: null,
  epoch: "",
  rev: 0,
  segs: new Map(),
  order: [],
  speakers: [],
  pins: [],
  follow: true,
  sel: new Set(),       // selected segment ids
  selAnchor: null,      // last plain-clicked segment, for shift-click ranges
  multi: false,         // "+" mode: taps add/remove instead of replacing
  identities: null,     // {session, library, libraryLoaded} for the open job
  pollTimer: null,
  jobTimer: null,
  lastRenderKey: "",
  form: null,
  formReady: false,
  probe: null,
  probeTimer: null,
  followPlay: true,
  nowSeg: null,
  expOpen: false,
  exportPrefs: null
};

// ---------- helpers ----------
function $(id) { return document.getElementById(id); }

function h(tag, attrs, children) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const k of Object.keys(attrs)) {
      const v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") el.className = v;
      else if (k === "text") el.textContent = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "style") el.setAttribute("style", v);
      else if (v === true) el.setAttribute(k, "");
      else el.setAttribute(k, String(v));
    }
  }
  if (children !== undefined && children !== null) {
    const list = Array.isArray(children) ? children : [children];
    for (const c of list) {
      if (c === null || c === undefined || c === false) continue;
      el.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
  }
  return el;
}

async function api(path, opts) {
  const o = opts || {};
  const init = { method: o.method || "GET", headers: {}, credentials: "same-origin", cache: "no-store" };
  if (init.method !== "GET") init.headers["X-StreamScribe-Portal"] = "1";
  if (o.json !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(o.json);
  } else if (o.body !== undefined) {
    init.headers["Content-Type"] = "application/octet-stream";
    init.body = o.body;
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch (e) {
    const err = new Error("Can't reach the Mac Mini. If this keeps happening, reload the page (your sign-in may have expired).");
    err.network = true;
    throw err;
  }
  const type = res.headers.get("content-type") || "";
  if (!type.includes("application/json")) {
    if (!res.ok) throw Object.assign(new Error("Request failed (" + res.status + ")"), { status: res.status });
    // An HTML page where JSON was expected = Cloudflare Access login page.
    throw Object.assign(new Error("Your sign-in has expired. Reload the page to sign in again."), { network: true });
  }
  const data = await res.json();
  if (!res.ok) {
    throw Object.assign(new Error(data.error || ("Request failed (" + res.status + ")")), { status: res.status, data: data });
  }
  return data;
}

function fmtTime(sec) {
  if (sec === null || sec === undefined || !isFinite(sec)) return "";
  sec = Math.max(0, Math.floor(sec));
  const hh = Math.floor(sec / 3600), mm = Math.floor((sec % 3600) / 60), ss = sec % 60;
  const p = function (n) { return n < 10 ? "0" + n : String(n); };
  return hh > 0 ? hh + ":" + p(mm) + ":" + p(ss) : mm + ":" + p(ss);
}

function fmtBytes(n) {
  if (!isFinite(n)) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i === 0 ? n : n.toFixed(n < 10 ? 1 : 0)) + " " + u[i];
}

function relTime(iso) {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (!isFinite(t)) return "";
  const d = (Date.now() - t) / 1000;
  if (d < 45) return "just now";
  if (d < 3600) return Math.round(d / 60) + " min ago";
  if (d < 86400) return Math.round(d / 3600) + " h ago";
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

// Port of SpeakerPanel.speakerColor: 64-bit wrapping `hash &* 31 &+ scalar`
// over unicode scalars, then abs(hash) % 10 into the same 10-colour palette.
function speakerClass(label) {
  if (!label) return "cx";
  let hsh = 0n;
  for (const ch of String(label)) {
    hsh = BigInt.asIntN(64, hsh * 31n + BigInt(ch.codePointAt(0)));
  }
  if (hsh < 0n) hsh = -hsh;
  return "c" + Number(hsh % 10n);
}

let toastTimer = null;
function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(function () { t.classList.add("hidden"); }, 3800);
}

function banner(msg, info) {
  const b = $("banner");
  if (!msg) { b.classList.add("hidden"); return; }
  b.textContent = msg;
  b.className = "banner" + (info ? " info" : "");
}

const STATUS_LABEL = {
  queued: "Queued", preparing: "Starting", running: "Transcribing", finishing: "Finishing",
  completed: "Done", failed: "Failed", cancelled: "Cancelled", interrupted: "Interrupted"
};
function isTerminal(st) { return st === "completed" || st === "failed" || st === "cancelled" || st === "interrupted"; }
function isOnEngine(st) { return st === "preparing" || st === "running" || st === "finishing"; }

function jobProgress(j) {
  if (j.status === "running" && j.mode === "static" && j.durationSeconds > 0 && j.processedSeconds >= 0) {
    return Math.min(100, (j.processedSeconds / j.durationSeconds) * 100);
  }
  return null;
}

// ---------- status / header ----------
async function refreshStatus() {
  try {
    const st = await api("/api/status");
    const prevModels = S.status ? JSON.stringify([S.status.options.models, S.status.options.downloads]) : "";
    S.status = st;
    banner(null);
    renderHeader();
    if (!S.formReady) {
      initForm();
      if (S.view === "home") rebuildOptions();
    } else if (S.view === "home" && JSON.stringify([st.options.models, st.options.downloads]) !== prevModels) {
      // Only the model area: rebuilding the whole form every poll during a
      // download would snap shut any dropdown someone has open.
      refreshFormModels();
      rebuildModelArea();
    }
  } catch (e) {
    if (e.network) banner(e.message);
  }
}

function renderHeader() {
  const st = S.status;
  if (!st) return;
  $("who").textContent = st.me.isLocal ? "On the Mac Mini" : st.me.email;
  const pill = $("enginePill");
  let cls = "pill ok", text = "Ready";
  if (st.engine.busyWithMacSession) {
    cls = "pill warn";
    text = "Busy with a session started on the Mac";
  } else if (st.engine.active) {
    cls = "pill busy";
    text = (st.engine.label || "Working") + (st.engine.title ? " · " + st.engine.title : "");
  }
  const running = (st.queue.running || []).length;
  if (running > 1) {
    cls = "pill busy";
    text = "Transcribing " + running + " jobs";
  } else if (running === 1 && !st.engine.active) {
    cls = "pill busy";
    text = "Transcribing";
  }
  if (st.queue.paused) { cls = "pill warn"; text = "Queue paused" + (st.engine.active ? " · finishing current job" : ""); }
  if (st.queue.queued > 0) text += " · " + st.queue.queued + " waiting";
  pill.className = cls;
  $("engineText").textContent = text;
  const pb = $("pauseBtn");
  if (st.me.isAdmin) {
    pb.classList.remove("hidden");
    pb.textContent = "";
    pb.appendChild(document.createTextNode(st.queue.paused ? "Resume" : "Pause"));
    pb.appendChild(h("span", { class: "wide", text: "queue" }));
  } else {
    pb.classList.add("hidden");
  }
}

$("pauseBtn").addEventListener("click", async function () {
  if (!S.status) return;
  try {
    S.status = await api("/api/queue/pause", { method: "POST", json: { paused: !S.status.queue.paused } });
    renderHeader();
  } catch (e) { toast(e.message); }
});

// ---------- routing ----------
function route() {
  const m = location.hash.match(/^#\/job\/([0-9A-Fa-f-]{36})$/);
  stopJobPolling();
  closePopups();
  S.sel = new Set(); S.selAnchor = null; S.multi = false; S.identities = null;
  updateActionbar();
  if (m) {
    S.view = "job";
    S.jobId = m[1].toUpperCase();
    S.job = null; S.epoch = ""; S.rev = 0; S.segs = new Map(); S.order = []; S.speakers = []; S.pins = [];
    S.follow = true; S.lastRenderKey = ""; S.nowSeg = null;
    renderJobShell();
    pollJob();
  } else {
    S.view = "home";
    S.jobId = null;
    renderHome();
    refreshJobs();
  }
  window.scrollTo(0, 0);
}
window.addEventListener("hashchange", route);
$("brand").addEventListener("click", function () { location.hash = "#/"; });

// ---------- home ----------
function optionSelect(id, options, value) {
  const sel = h("select", { id: id });
  for (const o of options) {
    const opt = h("option", { value: o.id, text: o.label });
    if (o.id === value) opt.selected = true;
    sel.appendChild(opt);
  }
  return sel;
}

const ENGINE_HINT = {
  auto: "WhisperKit for recordings, Parakeet for live streams.",
  whisperKit: "Accurate and multilingual. Best for recordings.",
  parakeet: "Fastest, English only. Best for keeping up with live streams.",
  canary: "Highest accuracy, multilingual, punctuated. Slower than Parakeet."
};

function downloaded(engine) {
  const m = S.status && S.status.options.models ? S.status.options.models[engine] : null;
  return m || [];
}

// Form state lives in S.form (not the DOM) so it survives re-renders: switching
// Link/Upload, changing engine, or coming back from a job page.
function initForm() {
  const st = S.status;
  const d = st ? st.defaults : null;
  const prev = S.form;
  const pickModel = function (engine) {
    const list = downloaded(engine);
    const want = d && d.models ? d.models[engine] : null;
    if (want && list.some(function (o) { return o.id === want; })) return want;
    return list.length ? list[0].id : null;
  };
  S.form = {
    url: prev ? prev.url : "",
    sourceType: d ? d.mode : "auto",
    engine: "auto",
    models: { whisperKit: pickModel("whisperKit"), parakeet: pickModel("parakeet") },
    diarization: d ? d.diarization : "fluidAudio",
    language: d ? d.language : "en",
    expectedSpeakers: d && d.expectedSpeakers > 0 ? String(d.expectedSpeakers) : "",
    liveFromStart: d ? !!d.liveFromStart : false,
    cleanup: d ? !!d.cleanup : false,
    optsOpen: prev ? prev.optsOpen : false,
    advOpen: prev ? prev.advOpen : false
  };
  S.formReady = !!st;
}

// A model finished downloading (or vanished): fill in any engine whose model
// choice is empty, and drop a choice that's no longer on the Mini.
function refreshFormModels() {
  const f = S.form;
  if (!f) return;
  ["whisperKit", "parakeet"].forEach(function (engine) {
    const list = downloaded(engine);
    if (!list.some(function (o) { return o.id === f.models[engine]; })) {
      const want = S.status.defaults.models ? S.status.defaults.models[engine] : null;
      f.models[engine] = list.some(function (o) { return o.id === want; }) ? want : (list.length ? list[0].id : null);
    }
  });
}

function engineReady(engine) { return engine === "auto" || downloaded(engine).length > 0; }

function downloadPanel(engine) {
  const st = S.status;
  const d = st && st.options.downloads ? st.options.downloads[engine] : null;
  const name = { whisperKit: "WhisperKit", parakeet: "Parakeet", canary: "Canary" }[engine] || engine;
  const admin = st && st.me.isAdmin;
  if (d && (d.state === "downloading" || d.state === "loading")) {
    const pct = d.progress !== null && d.progress !== undefined ? d.progress * 100 : null;
    return h("div", { class: "dl" }, [
      h("div", { class: "dlh", text: (d.state === "loading" ? "Loading " : "Downloading ") + d.label + "…" }),
      h("div", { class: "progress" + (pct === null ? " ind" : "") }, h("div", { style: pct === null ? "" : "width:" + pct.toFixed(1) + "%" })),
      h("div", { class: "hint", text: pct === null ? "On the Mac Mini. This can take a few minutes." : Math.round(pct) + "% · on the Mac Mini" })
    ]);
  }
  const failed = d && d.state === "error";
  const kids = [
    h("div", { class: "dlh", text: failed ? "The download didn't finish." : name + " isn't downloaded on the Mac Mini yet." }),
    d ? h("div", { class: "hint", text: d.label }) : null,
    failed && d.message ? h("div", { class: "hint", text: d.message }) : null
  ];
  if (admin && d) {
    kids.push(h("button", { class: "btn sm", type: "button", text: failed ? "Try again" : "Download to the Mac Mini", onclick: function (e) { startDownload(engine, e.target); } }));
  } else if (!admin) {
    kids.push(h("div", { class: "hint", text: "Ask a portal admin to download it, or pick another engine." }));
  }
  return h("div", { class: "dl" + (failed ? " bad" : "") }, kids);
}

async function startDownload(engine, btn) {
  if (btn) btn.disabled = true;
  try {
    S.status = await api("/api/models/download", { method: "POST", json: { engine: engine } });
    rebuildModelArea();
  } catch (e) {
    toast(e.message);
    if (btn) btn.disabled = false;
  }
}

function syncSubmit() {
  const btn = $("submitBtn"), hint = $("submitHint");
  if (!btn || !S.form) return;
  const ready = engineReady(S.form.engine);
  if (!S.uploading) btn.disabled = !ready;
  if (hint) hint.textContent = ready ? "" : "Download the model first, or pick another engine.";
}

function segmented(id, options, value, onPick, isDisabled) {
  const wrap = h("div", { class: "tabs seg", id: id, role: "group" });
  for (const o of options) {
    const off = isDisabled ? isDisabled(o.id) : null;
    wrap.appendChild(h("button", {
      type: "button",
      class: o.id === value ? "on" : "",
      "aria-pressed": o.id === value ? "true" : "false",
      disabled: !!off,
      title: off || o.title || null,
      text: o.label,
      onclick: function () { onPick(o.id); }
    }));
  }
  return wrap;
}

function modelControl() {
  const f = S.form;
  if (f.engine === "auto") {
    const w = downloaded("whisperKit").find(function (o) { return o.id === f.models.whisperKit; });
    const p = downloaded("parakeet").find(function (o) { return o.id === f.models.parakeet; });
    return [
      h("select", { id: "o-model", disabled: true }, h("option", { text: "Chosen with the engine" })),
      h("div", { class: "hint", text: "Recordings: " + (w ? w.label : "WhisperKit default") + ". Live: " + (p ? p.label : "Parakeet default") + "." })
    ];
  }
  const list = downloaded(f.engine);
  if (!list.length) return [downloadPanel(f.engine)];
  if (f.engine === "canary") {
    return [h("select", { id: "o-model" }, list.map(function (o) { return h("option", { value: o.id, text: o.label }); }))];
  }
  const sel = optionSelect("o-model", list, f.models[f.engine]);
  sel.addEventListener("change", function (e) { f.models[f.engine] = e.target.value; });
  return [sel, h("div", { class: "hint", text: "Only models already downloaded on the Mac Mini are listed." })];
}

function buildOptions() {
  const st = S.status;
  const o = st ? st.options : { modes: [], engines: [], diarizers: [], languages: [] };
  if (!S.form) initForm();
  const f = S.form;

  const sourceTypes = [
    { id: "auto", label: "Auto", title: "Detect live stream vs. recording" },
    { id: "live", label: "Live" },
    { id: "static", label: "Recording", title: "Whole-file processing: best speaker labels" }
  ];
  const engines = (o.engines && o.engines.length) ? o.engines : [{ id: "auto", label: "Auto" }];

  const options = h("details", { class: "opts", id: "opts", open: f.optsOpen, ontoggle: function (e) { f.optsOpen = e.target.open; } }, [
    h("summary", { text: "Options" }),
    h("label", { class: "f", text: "Source type" }),
    segmented("o-mode", sourceTypes, f.sourceType, function (v) { f.sourceType = v; rebuildOptions(); }),
    h("label", { class: "f", text: "Transcription engine" }),
    segmented("o-engine", engines, f.engine, function (v) { f.engine = v; rebuildOptions(); }),
    h("div", { class: "hint", text: ENGINE_HINT[f.engine] || "" }),
    h("label", { class: "f", for: "o-model", text: "Model" }),
    h("div", { id: "modelArea" }, modelControl())
  ]);

  const diarSel = optionSelect("o-diar", o.diarizers, f.diarization);
  diarSel.addEventListener("change", function (e) { f.diarization = e.target.value; });
  const spk = h("input", { id: "o-spk", type: "number", min: "0", max: "60", inputmode: "numeric", placeholder: "Any", value: f.expectedSpeakers,
    oninput: function (e) { f.expectedSpeakers = e.target.value; } });
  const langSel = optionSelect("o-lang", o.languages, f.language);
  langSel.addEventListener("change", function (e) { f.language = e.target.value; });

  const advanced = h("details", { class: "opts", id: "adv", open: f.advOpen, ontoggle: function (e) { f.advOpen = e.target.open; } }, [
    h("summary", { text: "Advanced" }),
    h("div", { class: "row2" }, [
      h("div", null, [h("label", { class: "f", for: "o-diar", text: "Speaker labels" }), diarSel]),
      h("div", null, [h("label", { class: "f", for: "o-spk", text: "Expected speakers" }), spk])
    ]),
    h("div", { class: "hint", text: "Knowing how many people speak (e.g. a hearing roster) is the biggest single boost to speaker accuracy." }),
    h("label", { class: "f", for: "o-lang", text: "Language (WhisperKit only)" }), langSel,
    h("label", { class: "check" }, [
      h("input", { type: "checkbox", id: "o-backlog", checked: f.liveFromStart, onchange: function (e) { f.liveFromStart = e.target.checked; } }),
      h("span", null, ["Live streams: transcribe from the beginning", h("div", { class: "hint", text: "Otherwise transcription starts at the live edge." })])
    ]),
    h("label", { class: "check" }, [
      h("input", { type: "checkbox", id: "o-clean", checked: f.cleanup, onchange: function (e) { f.cleanup = e.target.checked; } }),
      h("span", null, ["AI cleanup pass", h("div", { class: "hint", text: "Fixes filler, numerals and punctuation after transcription." })])
    ])
  ]);
  return h("div", { id: "optsWrap" }, [options, advanced]);
}

function rebuildModelArea() {
  const el = $("modelArea");
  if (el) el.replaceWith(h("div", { id: "modelArea" }, modelControl()));
  syncSubmit();
}

function rebuildOptions() {
  const old = $("optsWrap");
  if (old) old.replaceWith(buildOptions());
  syncSubmit();
}

function readSettings() {
  const f = S.form;
  const s = {
    mode: f.sourceType,
    engine: f.engine,
    diarization: f.diarization,
    language: f.language,
    expectedSpeakers: Math.max(0, Math.min(60, parseInt(f.expectedSpeakers, 10) || 0)),
    liveFromStart: f.liveFromStart,
    cleanup: f.cleanup
  };
  if ((f.engine === "whisperKit" || f.engine === "parakeet") && f.models[f.engine]) s.model = f.models[f.engine];
  return s;
}

function renderHome() {
  const view = $("view");
  view.textContent = "";
  if (!S.form) initForm();

  const urlPane = h("div", { id: "pane-url", class: S.mode === "url" ? "" : "hidden" }, [
    h("label", { class: "f", for: "url", text: "Link" }),
    h("input", { id: "url", type: "url", placeholder: "https://www.youtube.com/watch?v=…", autocomplete: "off", value: S.form ? S.form.url : "",
      oninput: function (e) { if (S.form) { S.form.url = e.target.value; scheduleProbe(); } },
      onkeydown: function (e) { if (e.key === "Enter") submit(); } }),
    h("div", { class: "hint", text: "YouTube, House/Senate hearings, state legislatures, X, podcasts, direct audio/video links…" }),
    h("div", { id: "probe", class: "probe hidden", "aria-live": "polite" })
  ]);

  const fileInput = h("input", { id: "file", type: "file", class: "hidden", onchange: function (e) { pickFile(e.target.files[0]); } });
  const drop = h("div", {
    class: "drop", id: "drop",
    onclick: function () { if (!S.uploading) fileInput.click(); },
    ondragover: function (e) { e.preventDefault(); drop.classList.add("over"); },
    ondragleave: function () { drop.classList.remove("over"); },
    ondrop: function (e) { e.preventDefault(); drop.classList.remove("over"); if (e.dataTransfer.files.length) pickFile(e.dataTransfer.files[0]); }
  }, [h("div", { id: "dropText" }, dropContent())]);
  const upPane = h("div", { id: "pane-file", class: S.mode === "file" ? "" : "hidden" }, [
    fileInput, drop,
    h("div", { id: "upProg", class: "hidden", style: "margin-top:12px" }, [
      h("div", { class: "progress" }, h("div", { id: "upBar" })),
      h("div", { class: "hint", id: "upText" })
    ])
  ]);

  const tabs = h("div", { class: "tabs" }, [
    h("button", { class: S.mode === "url" ? "on" : "", text: "Link", onclick: function () { setMode("url"); } }),
    h("button", { class: S.mode === "file" ? "on" : "", text: "Upload a file", onclick: function () { setMode("file"); } })
  ]);

  // Not sticky: with Options and Advanced open the form is taller than a
  // laptop screen, and a pinned card that tall hides its own Transcribe button.
  const newCard = h("section", { class: "card" }, [
    h("div", { class: "hd" }, h("h2", { text: "New transcript" })),
    h("div", { class: "bd" }, [
      tabs, urlPane, upPane, buildOptions(),
      h("button", { class: "btn primary block", id: "submitBtn", text: "Transcribe", onclick: submit }),
      h("div", { class: "hint", id: "submitHint", style: "text-align:center" })
    ])
  ]);

  const filter = h("div", { class: "jobs-filter" }, h("div", { class: "tabs" }, [
    h("button", { class: S.jobFilter === "all" ? "on" : "", text: "Everyone", onclick: function () { S.jobFilter = "all"; renderJobs(); } }),
    h("button", { class: S.jobFilter === "mine" ? "on" : "", text: "Mine", onclick: function () { S.jobFilter = "mine"; renderJobs(); } })
  ]));
  const listCard = h("section", { class: "card" }, [
    h("div", { class: "hd", style: "padding-bottom:12px" }, [h("h2", { text: "Transcripts" }), filter]),
    h("ul", { class: "job-list", id: "jobList" }, h("li", { class: "empty", text: "Loading…" }))
  ]);

  view.appendChild(h("div", { class: "grid-home" }, [newCard, listCard]));
  syncSubmit();
  renderProbe();
  renderJobs();
}

function dropContent() {
  if (S.file) {
    return [h("strong", { text: S.file.name }), h("div", { class: "hint", text: fmtBytes(S.file.size) + " · click to choose a different file" })];
  }
  return [h("strong", { text: "Choose an audio or video file" }), h("div", { class: "hint", text: "or drag it here · up to 10 GB" })];
}

function setMode(m) {
  S.mode = m;
  renderHome();
}

// ---------- link check (probe) ----------
// Checks a pasted link on the Mini (live vs. recording, length, title) the way
// the Mac's URL field does. Debounced so typing doesn't fire a check per key;
// a result for a link that's no longer in the box is ignored.
function looksLikeLink(u) { return /^https?:\/\/[^\s\/]+\.[^\s]+$/i.test(u); }

function scheduleProbe() {
  clearTimeout(S.probeTimer);
  const u = (S.form ? S.form.url : "").trim();
  if (!looksLikeLink(u)) { S.probe = null; renderProbe(); return; }
  if (S.probe && S.probe.url === u && S.probe.state !== "error") { renderProbe(); return; }
  S.probe = { url: u, state: "waiting" };
  renderProbe();
  S.probeTimer = setTimeout(function () { runProbe(u); }, 600);
}

async function runProbe(u) {
  const current = function () { return S.form && S.form.url.trim() === u; };
  if (!current()) return;
  S.probe = { url: u, state: "checking" };
  renderProbe();
  let r;
  try {
    r = await api("/api/probe", { method: "POST", json: { url: u } });
  } catch (e) {
    if (!current()) return;
    S.probe = { url: u, state: "error", message: e.message };
    renderProbe();
    return;
  }
  if (!current()) return;
  if (r.kind === "busy") {
    S.probeTimer = setTimeout(function () { runProbe(u); }, 3000);
    return;
  }
  S.probe = { url: u, state: r.kind, data: r };
  renderProbe();
}

function renderProbe() {
  const el = $("probe");
  if (!el) return;
  const p = S.probe;
  el.textContent = "";
  if (!p || !S.form || p.url !== S.form.url.trim()) { el.className = "probe hidden"; return; }
  const d = p.data || {};
  const src = d.source && d.source !== "Unknown" ? " · " + d.source : "";
  let cls = "probe", head = [], msg = null;
  if (p.state === "waiting" || p.state === "checking") {
    head = [h("span", { class: "spin" }), "Checking link on the Mac Mini…"];
  } else if (p.state === "recording") {
    cls += " ok";
    head = ["✓ Recording" + (d.durationSeconds ? " · " + fmtTime(d.durationSeconds) : "") + src];
  } else if (p.state === "live") {
    cls += " live";
    head = ["● Live stream" + src];
  } else if (p.state === "failed") {
    cls += " bad";
    head = ["Couldn't read this link" + src];
    const reason = (d.message || "").trim();
    msg = (reason ? reason + (/[.!?…]$/.test(reason) ? " " : ". ") : "") + "You can still try transcribing it.";
  } else {
    cls += " bad";
    head = ["Couldn't check this link"];
    msg = p.message || "";
  }
  el.className = cls;
  el.appendChild(h("div", { class: "pl" }, head));
  if (d.title && (p.state === "recording" || p.state === "live" || p.state === "failed")) {
    el.appendChild(h("div", { class: "pt", title: d.title, text: d.title }));
  }
  if (msg) el.appendChild(h("div", { class: "pm", text: msg }));
}

function pickFile(f) {
  if (!f) return;
  const ext = (f.name.split(".").pop() || "").toLowerCase();
  const allowed = S.status ? S.status.options.uploadExtensions : [];
  if (allowed.length && allowed.indexOf(ext) < 0) { toast("That doesn't look like an audio or video file (." + ext + ")."); return; }
  if (S.status && f.size > S.status.options.maxUploadBytes) { toast("Files up to " + fmtBytes(S.status.options.maxUploadBytes) + " are supported."); return; }
  S.file = f;
  const dt = $("dropText");
  dt.textContent = "";
  for (const n of dropContent()) dt.appendChild(n);
}

async function submit() {
  const btn = $("submitBtn");
  if (!btn || btn.disabled) return;
  const settings = readSettings();
  btn.disabled = true;
  try {
    if (S.mode === "url") {
      const url = $("url").value.trim();
      if (!url) { toast("Paste a link first."); return; }
      const job = await api("/api/jobs", { method: "POST", json: { url: url, settings: settings } });
      S.form.url = "";
      S.probe = null;
      location.hash = "#/job/" + job.id;
    } else {
      if (!S.file) { toast("Choose a file first."); return; }
      const job = await upload(S.file, settings);
      S.file = null;
      location.hash = "#/job/" + job.id;
    }
  } catch (e) {
    toast(e.message);
  } finally {
    if ($("submitBtn")) $("submitBtn").disabled = false;
    syncSubmit();
  }
}

async function upload(file, settings) {
  S.uploading = true;
  const prog = $("upProg"), bar = $("upBar"), txt = $("upText");
  prog.classList.remove("hidden");
  const started = Date.now();
  const setP = function (sent) {
    const pct = file.size ? (sent / file.size) * 100 : 100;
    bar.style.width = pct.toFixed(1) + "%";
    const secs = (Date.now() - started) / 1000;
    const rate = secs > 1 ? sent / secs : 0;
    let eta = "";
    if (rate > 0 && sent < file.size) eta = " · about " + fmtTime((file.size - sent) / rate) + " left";
    txt.textContent = "Uploading " + fmtBytes(sent) + " of " + fmtBytes(file.size) + (rate > 0 ? " · " + fmtBytes(rate) + "/s" : "") + eta;
  };
  let uploadId = null;
  try {
    const created = await api("/api/uploads", { method: "POST", json: { filename: file.name, size: file.size, settings: settings } });
    uploadId = created.uploadId;
    const chunk = parseInt(created.chunkBytes, 10) || (16 * 1024 * 1024);
    let offset = 0;
    setP(0);
    while (offset < file.size) {
      const end = Math.min(file.size, offset + chunk);
      let attempt = 0;
      for (;;) {
        try {
          const r = await api("/api/uploads/" + uploadId + "/chunk?offset=" + offset, { method: "POST", body: file.slice(offset, end) });
          offset = parseInt(r.received, 10);
          break;
        } catch (e) {
          if (e.status === 409 && e.data && e.data.received !== undefined) { offset = parseInt(e.data.received, 10); break; }
          attempt++;
          if (attempt > 5 || (e.status && e.status < 500 && e.status !== 408 && e.status !== 429)) throw e;
          txt.textContent = "Connection hiccup — retrying (" + attempt + "/5)…";
          await new Promise(function (r) { setTimeout(r, 1000 * Math.pow(2, attempt)); });
        }
      }
      setP(offset);
    }
    txt.textContent = "Upload complete — adding to the queue…";
    const job = await api("/api/uploads/" + uploadId + "/finish", { method: "POST", json: { settings: settings } });
    return job;
  } catch (e) {
    if (uploadId) { api("/api/uploads/" + uploadId + "/abort", { method: "POST", json: {} }).catch(function () {}); }
    prog.classList.add("hidden");
    throw e;
  } finally {
    S.uploading = false;
  }
}

async function refreshJobs() {
  try {
    S.jobs = await api("/api/jobs");
    if (S.view === "home") renderJobs();
  } catch (e) {
    if (e.network) banner(e.message);
  }
}

function renderJobs() {
  const ul = $("jobList");
  if (!ul) return;
  // Re-sync the filter tab highlight.
  const tabs = document.querySelectorAll(".jobs-filter .tabs button");
  if (tabs.length === 2) {
    tabs[0].className = S.jobFilter === "all" ? "on" : "";
    tabs[1].className = S.jobFilter === "mine" ? "on" : "";
  }
  const me = S.status ? S.status.me.email : "";
  const list = S.jobs.filter(function (j) { return S.jobFilter === "all" || j.submittedBy === me; });
  ul.textContent = "";
  if (!list.length) {
    ul.appendChild(h("li", { class: "empty", text: S.jobFilter === "mine" ? "You haven't submitted anything yet." : "No transcripts yet. Paste a link to get started." }));
    return;
  }
  for (const j of list) {
    const pct = jobProgress(j);
    const meta = [
      h("span", { class: "chip " + j.status, text: STATUS_LABEL[j.status] || j.status }),
      j.queuePosition ? h("span", { text: "#" + j.queuePosition + " in line" }) : null,
      h("span", { text: (j.submittedBy === "local" ? "Mac Mini" : j.submittedBy) }),
      h("span", { text: relTime(j.createdAt) }),
      j.durationSeconds ? h("span", { text: fmtTime(j.durationSeconds) }) : null
    ];
    const li = h("li", null, h("a", { class: "job-item", href: "#/job/" + j.id }, [
      h("div", { class: "job-title", text: j.title || j.source }),
      h("div", { class: "job-meta" }, meta),
      isOnEngine(j.status) ? h("div", { class: "progress" + (pct === null ? " ind" : "") }, h("div", { style: pct === null ? "" : "width:" + pct.toFixed(1) + "%" })) : null
    ]));
    ul.appendChild(li);
  }
}

// ---------- job view ----------
function renderJobShell() {
  const view = $("view");
  view.textContent = "";
  const head = h("div", { class: "job-head", id: "jobHead" }, [
    h("a", { class: "back", href: "#/", text: "← All transcripts" }),
    h("h1", { id: "jobTitle", text: "Loading…" }),
    h("div", { class: "job-meta", id: "jobMeta" }),
    h("div", { id: "jobProg" }),
    h("div", { class: "actions", id: "jobActions" }),
    h("div", { id: "expWrap" }),
    h("div", { class: "msg", id: "jobMsg" })
  ]);
  const transcriptCard = h("section", { class: "card" }, [
    h("div", { class: "hd" }, [
      h("h2", { text: "Transcript" }),
      h("label", { class: "follow", id: "followWrap" }, [
        h("input", { type: "checkbox", id: "follow", checked: S.follow, onchange: function (e) { S.follow = e.target.checked; if (S.follow) scrollToEnd(); } }),
        "Follow live"
      ])
    ]),
    h("div", { class: "transcript", id: "transcript" }, h("div", { class: "empty", text: "Waiting for the transcript…" }))
  ]);
  const side = h("aside", { class: "side" }, [
    h("section", { class: "card", style: "margin-bottom:20px" }, [
      h("div", { class: "hd" }, h("h3", { text: "Speakers" })),
      h("div", { class: "bd", id: "speakers" }, h("div", { class: "hint", text: "Speakers appear as they're detected." }))
    ]),
    h("section", { class: "card" }, [
      h("div", { class: "hd" }, h("h3", { text: "Pinned quotes" })),
      h("div", { class: "bd", id: "pins" }, h("div", { class: "hint", text: "Tap any sentence in the transcript to pin it." }))
    ])
  ]);
  view.appendChild(head);
  const playerSlot = h("div", { id: "playerSlot" });
  view.appendChild(h("div", { class: "grid-job" }, [h("div", null, [playerSlot, transcriptCard]), h("div", { class: "sticky" }, side)]));
}

function stopJobPolling() {
  if (S.jobTimer) { clearTimeout(S.jobTimer); S.jobTimer = null; }
}

async function pollJob() {
  if (S.view !== "job") return;
  const id = S.jobId;
  let delay = 1500;
  try {
    const r = await api("/api/jobs/" + id + "/transcript?since=" + S.rev + "&epoch=" + encodeURIComponent(S.epoch));
    if (S.view !== "job" || S.jobId !== id) return;
    applyTranscript(r);
    banner(null);
    delay = (r.job.live || !isTerminal(r.job.status)) ? 1500 : 10000;
  } catch (e) {
    if (e.status === 404) { renderMissing(); return; }
    if (e.network) banner(e.message);
    delay = 5000;
  }
  if (S.view === "job" && S.jobId === id) S.jobTimer = setTimeout(pollJob, delay);
}

function renderMissing() {
  const view = $("view");
  view.textContent = "";
  view.appendChild(h("div", { class: "card" }, h("div", { class: "empty" }, [
    "This transcript no longer exists. ", h("a", { href: "#/", text: "Back to all transcripts" })
  ])));
}

function applyTranscript(r) {
  if (r.full) { S.segs = new Map(); }
  for (const s of r.segments) S.segs.set(s.id, s);
  if (r.order) {
    S.order = r.order;
    const keep = new Set(r.order);
    for (const k of Array.from(S.segs.keys())) if (!keep.has(k)) S.segs.delete(k);
  }
  const metaChanged = !!(r.speakers || r.pins);
  if (r.speakers) S.speakers = r.speakers;
  if (r.pins) S.pins = r.pins;
  const transcriptChanged = r.full || r.segments.length > 0 || !!r.order || metaChanged;
  S.epoch = r.epoch;
  S.rev = r.rev;
  S.job = r.job;
  renderJobHead();
  if (metaChanged || r.full) { renderSpeakers(); renderPins(); }
  if (transcriptChanged) { renderTranscript(r.full); if (S.sel.size) updateActionbar(); }
  if (metaChanged) S.identities = null;  // a new identity may have been added
}

function nameFor(label) {
  if (!label) return "Unknown Speaker";
  const s = S.speakers.find(function (x) { return x.label === label; });
  return s ? s.name : label;
}

function renderJobHead() {
  const j = S.job;
  if (!j) return;
  $("jobTitle").textContent = j.title || j.source;
  document.title = (j.title || "Transcript") + " · StreamScribe";
  const meta = $("jobMeta");
  meta.textContent = "";
  const srcNode = j.isUpload ? h("span", { text: "File: " + j.source })
    : h("a", { href: j.source, target: "_blank", rel: "noopener noreferrer", text: shortURL(j.source) });
  const bits = [
    h("span", { class: "chip " + j.status, text: STATUS_LABEL[j.status] || j.status }),
    j.queuePosition ? h("span", { text: "#" + j.queuePosition + " in line" }) : null,
    srcNode,
    h("span", { text: "by " + (j.submittedBy === "local" ? "Mac Mini" : j.submittedBy) }),
    h("span", { text: relTime(j.createdAt) }),
    j.mode ? h("span", { text: j.mode === "static" ? "Recording" : "Live" }) : null,
    j.durationSeconds ? h("span", { text: fmtTime(j.durationSeconds) }) : null,
    h("span", { text: S.order.length + " segments" })
  ];
  for (const b of bits) if (b) meta.appendChild(b);

  const prog = $("jobProg");
  prog.textContent = "";
  if (isOnEngine(j.status)) {
    const pct = jobProgress(j);
    prog.appendChild(h("div", { class: "progress" + (pct === null ? " ind" : ""), style: "margin-top:10px" },
      h("div", { style: pct === null ? "" : "width:" + pct.toFixed(1) + "%" })));
  }

  // Rebuilt only when something it shows changes — rebuilding every poll
  // would snap shut a format dropdown someone has open.
  const actKey = [j.id, j.status, j.canManage, S.order.length > 0].join("|");
  const act = $("jobActions");
  if (act.getAttribute("data-key") !== actKey) {
  act.setAttribute("data-key", actKey);
  act.textContent = "";
  if (j.canManage && (j.status === "queued" || isOnEngine(j.status))) {
    act.appendChild(h("button", { class: "btn danger", text: j.status === "queued" ? "Cancel" : "Stop", onclick: stopJob }));
  }
  if (S.order.length) {
    const formats = S.status ? S.status.options.exportFormats : [{ id: "docx", label: "Word Document (.docx)" }];
    const sel = optionSelect("fmt", formats, localStorage.getItem("ss.fmt") || "docx");
    act.appendChild(sel);
    act.appendChild(h("button", { class: "btn primary", text: "Download", onclick: function () {
      const f = $("fmt").value;
      try { localStorage.setItem("ss.fmt", f); } catch (e) {}
      window.location.href = exportURL(j.id, f);
    } }));
    act.appendChild(h("button", { class: "btn", id: "expBtn", "aria-expanded": S.expOpen ? "true" : "false", text: "Export options",
      onclick: function () { S.expOpen = !S.expOpen; renderExportPanel(); } }));
  }
  if (isTerminal(j.status)) {
    act.appendChild(h("button", { class: "btn", text: "Run again", onclick: retryJob }));
    if (j.canManage) act.appendChild(h("button", { class: "btn danger", text: "Delete", onclick: deleteJob }));
  }
  }

  renderExportPanel();
  renderPlayer();

  const msg = $("jobMsg");
  let m = j.message || "";
  if (j.status === "queued" && !m) m = "Waiting for the Mac Mini to finish the job ahead of this one.";
  if (j.live && isTerminal(j.status)) m = (m ? m + " · " : "") + "Still open on the Mac Mini — edits there show up here.";
  msg.textContent = m;
  msg.className = "msg" + (j.status === "failed" || j.status === "interrupted" ? " bad" : "");
  $("followWrap").classList.toggle("hidden", !isOnEngine(j.status));
}

// ---------- web miniplayer ----------
function playerReady() { return !!(S.job && S.job.media === "ready" && $("player")); }

function renderPlayer() {
  const slot = $("playerSlot");
  const j = S.job;
  if (!slot || !j) return;
  const want = j.media === "ready" ? "ready:" + j.id
    : j.media === "preparing" ? "preparing"
    : (isOnEngine(j.status) || j.status === "queued") ? "later" : "none";
  if (slot.getAttribute("data-state") === want) return;   // never rebuild a playing player
  slot.setAttribute("data-state", want);
  slot.textContent = "";
  if (want === "preparing") {
    slot.appendChild(h("div", { class: "card player-note", style: "margin-bottom:14px" }, "Preparing playback on the Mac Mini…"));
  } else if (want === "later") {
    slot.appendChild(h("div", { class: "card player-note", style: "margin-bottom:14px" }, "Playback will be available here when this transcript finishes."));
  } else if (want.indexOf("ready:") === 0) {
    const video = h("video", { id: "player", controls: true, preload: "metadata", playsinline: true, src: "/api/jobs/" + j.id + "/media" });
    const card = h("section", { class: "card player", id: "playerCard" }, [
      video,
      h("div", { class: "pc" }, [
        h("label", null, ["Speed",
          (function () {
            const sel = optionSelect("speed", [0.75, 1, 1.25, 1.5, 1.75, 2].map(function (r) { return { id: String(r), label: r + "×" }; }), "1");
            sel.addEventListener("change", function (e) { video.playbackRate = parseFloat(e.target.value); });
            return sel;
          })()]),
        h("span", { class: "grow" }),
        h("label", null, [
          h("input", { type: "checkbox", id: "followPlay", checked: S.followPlay, onchange: function (e) { S.followPlay = e.target.checked; } }),
          "Follow playback"
        ])
      ])
    ]);
    video.addEventListener("loadedmetadata", function () {
      // Audio-only media: no picture area, just the control bar.
      if (!video.videoWidth) card.classList.add("audio");
    });
    video.addEventListener("timeupdate", onPlayerTime);
    video.addEventListener("seeked", onPlayerTime);
    video.addEventListener("error", function () {
      slot.setAttribute("data-state", "error");
      slot.textContent = "";
      slot.appendChild(h("div", { class: "card player-note", style: "margin-bottom:14px" }, "This browser can't play the recording. The transcript and downloads still work."));
    });
    slot.appendChild(card);
    // Seek links and pin buttons depend on the player existing.
    renderTranscript();
    renderPins();
  }
}

function onPlayerTime() {
  const v = $("player");
  if (!v) return;
  const t = v.currentTime + 0.15;
  let now = null;
  for (const id of S.order) {
    const s = S.segs.get(id);
    if (!s) continue;
    if (s.start <= t) now = id; else break;
  }
  if (now === S.nowSeg) return;
  const prev = S.nowSeg ? document.querySelector('.seg[data-id="' + S.nowSeg + '"]') : null;
  if (prev) prev.classList.remove("now");
  S.nowSeg = now;
  const el = now ? document.querySelector('.seg[data-id="' + now + '"]') : null;
  if (!el) return;
  el.classList.add("now");
  if (S.followPlay && !v.paused) {
    const r = el.getBoundingClientRect();
    const card = $("playerCard");
    const top = card ? card.getBoundingClientRect().bottom + 8 : 70;
    if (r.top < top || r.bottom > window.innerHeight - 20) {
      const y = window.scrollY + r.top - top - Math.max(0, (window.innerHeight - top) / 3);
      window.scrollTo({ top: y, behavior: "smooth" });
    }
  }
}

function playFrom(t) {
  const v = $("player");
  if (!v || !isFinite(t)) return;
  v.currentTime = Math.max(0, t - 0.25);
  const p = v.play();
  if (p && p.catch) p.catch(function () {});
  const card = $("playerCard");
  if (card && card.getBoundingClientRect().top < 0) card.scrollIntoView({ block: "start" });
}

function downloadClip(start, end) {
  if (!S.job) return;
  const a = Math.max(0, start - 1), b = end + 1;
  if (b - a > 15 * 60) { toast("Clips can be up to 15 minutes long."); return; }
  toast("Preparing the clip on the Mac Mini…");
  window.location.href = "/api/jobs/" + S.job.id + "/clip?start=" + a.toFixed(2) + "&end=" + b.toFixed(2);
}

// ---------- export options ----------
// Start from the Mac Mini's Settings → Transcript Export; each browser keeps
// its own changes.
const EXPORT_KEYS = ["timestamps", "bold", "placement", "title", "source", "generated"];

function exportPrefs() {
  if (S.exportPrefs) return S.exportPrefs;
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem("ss.exportPrefs") || "null"); } catch (e) {}
  const d = S.status && S.status.defaults.export ? S.status.defaults.export : null;
  const base = d ? Object.assign({}, d) : { timestamps: true, bold: true, placement: "above", title: true, source: true, generated: true };
  S.exportPrefs = saved ? Object.assign(base, saved) : base;
  return S.exportPrefs;
}

function saveExportPrefs() {
  try { localStorage.setItem("ss.exportPrefs", JSON.stringify(S.exportPrefs)); } catch (e) {}
}

function exportURL(jobId, format) {
  const p = exportPrefs();
  const q = ["format=" + encodeURIComponent(format)];
  const b = function (v) { return v ? "1" : "0"; };
  q.push("ts=" + b(p.timestamps), "bold=" + b(p.bold), "placement=" + encodeURIComponent(p.placement),
         "title=" + b(p.title), "source=" + b(p.source), "generated=" + b(p.generated));
  return "/api/jobs/" + jobId + "/export?" + q.join("&");
}

function renderExportPanel() {
  const wrap = $("expWrap");
  if (!wrap) return;
  const btn = $("expBtn");
  if (btn) btn.setAttribute("aria-expanded", S.expOpen ? "true" : "false");
  const show = S.expOpen && !!$("fmt");
  if (!show) { wrap.textContent = ""; return; }
  if (wrap.firstChild) return;   // already open; keep the user's focus
  const p = exportPrefs();
  const box = function (key, label) {
    return h("label", { class: "check" }, [
      h("input", { type: "checkbox", checked: !!p[key], onchange: function (e) { p[key] = e.target.checked; saveExportPrefs(); } }),
      h("span", { text: label })
    ]);
  };
  const placements = S.status ? S.status.options.speakerPlacements : [{ id: "above", label: "Above each segment" }];
  const place = optionSelect("o-place", placements, p.placement);
  place.addEventListener("change", function (e) { p.placement = e.target.value; saveExportPrefs(); });
  wrap.appendChild(h("div", { class: "exp" }, [
    h("div", { class: "row2" }, [
      h("div", null, [box("timestamps", "Include timestamps"), box("bold", "Bold speaker labels")]),
      h("div", null, [box("title", "Include title"), box("source", "Include source link"), box("generated", "Include date generated")])
    ]),
    h("label", { class: "f", for: "o-place", text: "Speaker label placement" }), place,
    h("div", { class: "foot" }, [
      h("span", { text: "Saved in this browser. Subtitle (.srt, .vtt) and JSON downloads ignore these." }),
      h("button", { type: "button", text: "Reset to the Mac Mini's settings", onclick: function () {
        try { localStorage.removeItem("ss.exportPrefs"); } catch (e) {}
        S.exportPrefs = null;
        wrap.textContent = "";
        renderExportPanel();
      } })
    ])
  ]));
}

function shortURL(u) {
  try {
    const x = new URL(u);
    const p = x.pathname.length > 24 ? x.pathname.slice(0, 24) + "…" : x.pathname;
    return x.host + p;
  } catch (e) { return u; }
}

function renderTranscript(firstLoad) {
  const box = $("transcript");
  if (!box) return;
  const nearEnd = (window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 160);
  const pinned = new Set(S.pins.map(function (p) { return p.segmentId; }));
  box.textContent = "";
  if (!S.order.length) {
    const j = S.job;
    let t = "Waiting for the transcript…";
    if (j && j.status === "queued") t = "This job is in the queue. The transcript will appear here once it starts.";
    if (j && isTerminal(j.status)) t = "No transcript was produced.";
    box.appendChild(h("div", { class: "empty", text: t }));
    return;
  }
  const frag = document.createDocumentFragment();
  let block = null, para = null, current;
  for (const id of S.order) {
    const s = S.segs.get(id);
    if (!s) continue;
    const spk = s.speaker || "";
    if (block === null || spk !== current) {
      current = spk;
      para = h("p");
      block = h("div", { class: "block" }, [
        h("div", { class: "who2" }, [
          h("span", { class: "name " + speakerClass(s.speaker), text: nameFor(s.speaker) }),
          h("span", { class: "time" + (playerReady() ? " seek" : ""), "data-t": String(s.start),
            title: playerReady() ? "Play from here" : null, text: fmtTime(s.start) })
        ]),
        para
      ]);
      frag.appendChild(block);
    } else {
      para.appendChild(document.createTextNode(" "));
    }
    let cls = "seg";
    if (pinned.has(s.id)) cls += " pinned";
    if (S.sel.has(s.id)) cls += " sel";
    if (s.review) cls += " review";
    if (s.edited) cls += " edited";
    if (S.nowSeg === s.id) cls += " now";
    let title = fmtTime(s.start);
    if (s.review) title += " · flagged for review (too garbled to clean up)";
    if (s.edited) title += " · edited";
    if (s.restorable) title += " · original wording available (More ▸ Restore verbatim)";
    para.appendChild(h("span", { class: cls, "data-id": s.id, title: title, text: s.text }));
  }
  box.appendChild(frag);
  // Opening a live job lands at the live edge; after that, follow only while
  // the reader is already near the bottom (don't yank someone reading back).
  if (S.follow && S.job && isOnEngine(S.job.status) && (nearEnd || firstLoad)) scrollToEnd();
}

function scrollToEnd() { window.scrollTo(0, document.body.scrollHeight); }

document.addEventListener("click", function (e) {
  const t = e.target.closest ? e.target.closest(".time.seek") : null;
  if (t && S.view === "job") { playFrom(parseFloat(t.getAttribute("data-t"))); return; }
  const seg = e.target.closest ? e.target.closest(".seg") : null;
  if (!seg || S.view !== "job") return;
  const id = seg.getAttribute("data-id");
  if (e.shiftKey && S.selAnchor && S.segs.has(S.selAnchor)) {
    // Range: everything between the anchor and this sentence, in transcript order.
    const a = S.order.indexOf(S.selAnchor), b = S.order.indexOf(id);
    if (a >= 0 && b >= 0) {
      for (let i = Math.min(a, b); i <= Math.max(a, b); i++) S.sel.add(S.order[i]);
    } else {
      S.sel.add(id);
    }
  } else if (e.ctrlKey || e.metaKey || S.multi) {
    if (S.sel.has(id)) S.sel.delete(id); else S.sel.add(id);
    S.selAnchor = id;
  } else {
    const only = S.sel.size === 1 && S.sel.has(id);
    S.sel = new Set(only ? [] : [id]);
    S.selAnchor = only ? null : id;
  }
  if (window.getSelection && (e.shiftKey)) { try { window.getSelection().removeAllRanges(); } catch (x) {} }
  paintSelection();
  updateActionbar();
});

function paintSelection() {
  document.querySelectorAll(".seg").forEach(function (n) {
    n.classList.toggle("sel", S.sel.has(n.getAttribute("data-id")));
  });
}

function clearSelection() {
  S.sel = new Set();
  S.selAnchor = null;
  S.multi = false;
  paintSelection();
  updateActionbar();
}

/// Selected segments in transcript order (ids that vanished are dropped).
function selectedSegs() {
  const out = [];
  for (const id of S.order) if (S.sel.has(id) && S.segs.has(id)) out.push(S.segs.get(id));
  return out;
}

function updateActionbar() {
  const bar = $("actionbar");
  // Drop ids that no longer exist (deleted, or a full reload).
  for (const id of Array.from(S.sel)) if (!S.segs.has(id)) S.sel.delete(id);
  const segs = selectedSegs();
  if (!segs.length || S.view !== "job") { bar.classList.add("hidden"); closeMenus(); return; }
  const one = segs.length === 1 ? segs[0] : null;
  const isPinned = one ? S.pins.some(function (p) { return p.segmentId === one.id; }) : false;
  $("actionText").textContent = one ? (nameFor(one.speaker) + " · " + fmtTime(one.start))
    : (segs.length + " sentences · " + fmtTime(segs[0].start) + "–" + fmtTime(segs[segs.length - 1].end));
  $("pinSelBtn").textContent = isPinned ? "Unpin" : "Pin quote";
  $("pinSelBtn").classList.toggle("hidden", !one);
  $("editSelBtn").classList.toggle("hidden", !one);
  $("playSelBtn").classList.toggle("hidden", !playerReady());
  $("clipSelBtn").classList.toggle("hidden", !playerReady());
  $("multiSelBtn").classList.toggle("on", S.multi);
  bar.classList.remove("hidden");
}

$("playSelBtn").addEventListener("click", function () {
  const segs = selectedSegs();
  if (segs.length) playFrom(segs[0].start);
});
$("clipSelBtn").addEventListener("click", function () { clipSelection(); });
$("clearSelBtn").addEventListener("click", clearSelection);
$("multiSelBtn").addEventListener("click", function () {
  S.multi = !S.multi;
  $("multiSelBtn").classList.toggle("on", S.multi);
  if (S.multi) toast("Tap more sentences to add them to the selection.");
});

function clipSelection() {
  const segs = selectedSegs();
  if (segs.length) downloadClip(segs[0].start, segs[segs.length - 1].end);
}

$("pinSelBtn").addEventListener("click", async function () {
  const segs = selectedSegs();
  if (segs.length !== 1 || !S.jobId) return;
  const id = segs[0].id;
  const existing = S.pins.find(function (p) { return p.segmentId === id; });
  try {
    if (existing) {
      await api("/api/jobs/" + S.jobId + "/pins/" + existing.id + "/delete", { method: "POST", json: {} });
    } else {
      await api("/api/jobs/" + S.jobId + "/pins", { method: "POST", json: { segmentId: id } });
      toast("Pinned.");
    }
    clearSelection();
    refreshNow();
  } catch (e) { toast(e.message); }
});

// ---------- transcript editing (speaker reassignment, text, delete, restore) ----------
//
// Mirrors the Mac's transcript context menu. Every action posts to the Mini,
// which applies it to the live engine (so the Mac window changes too) or to
// the saved transcript, then the next poll redraws.

async function editCall(path, body, okMsg) {
  try {
    await api("/api/jobs/" + S.jobId + "/" + path, { method: "POST", json: body });
    if (okMsg) toast(okMsg);
    clearSelection();
    refreshNow();
    return true;
  } catch (e) { toast(e.message); return false; }
}

$("spkSelBtn").addEventListener("click", function (e) {
  const segs = selectedSegs();
  if (!segs.length) return;
  const ids = segs.map(function (s) { return s.id; });
  const labels = new Set(segs.map(function (s) { return s.speaker || ""; }));
  const uniform = labels.size === 1 ? Array.from(labels)[0] : null;
  const items = [{ header: segs.length === 1 ? "Move this sentence to" : "Move " + segs.length + " sentences to" }];
  for (const sp of S.speakers) {
    items.push({
      label: sp.name, sub: sp.name === sp.label ? null : sp.label, swatch: sp.label, checked: sp.label === uniform,
      onclick: function () {
        if (sp.label === uniform) return;
        editCall("segments/reassign", { segmentIds: ids, speaker: sp.label }, "Moved to " + sp.name + ".");
      }
    });
  }
  items.push("-");
  items.push({ label: "New speaker", sub: "split off as its own speaker", onclick: function () {
    editCall("segments/reassign", { segmentIds: ids, newSpeaker: true }, "Moved to a new speaker.");
  } });
  items.push({ label: "Identify as someone…", sub: "new speaker + name", onclick: function () {
    openIdentityPicker({
      title: segs.length === 1 ? "Identify this sentence" : "Identify " + segs.length + " sentences",
      hint: "The selection becomes its own speaker with this name — the same as the Mac's “Identify These Segments”.",
      onPick: function (name) { editCall("segments/reassign", { segmentIds: ids, newSpeaker: true, name: name }, "Identified as " + name + "."); }
    });
  } });
  showMenu(e.currentTarget, items);
});

$("editSelBtn").addEventListener("click", function () {
  const segs = selectedSegs();
  if (segs.length !== 1) return;
  openEditDialog(segs[0]);
});

$("moreSelBtn").addEventListener("click", function (e) {
  const segs = selectedSegs();
  if (!segs.length) return;
  const ids = segs.map(function (s) { return s.id; });
  const n = segs.length, noun = n === 1 ? "sentence" : "sentences";
  const restorable = segs.some(function (s) { return s.restorable; });
  const items = [];
  if (playerReady()) items.push({ label: "Download clip", sub: fmtTime(segs[0].start) + "–" + fmtTime(segs[n - 1].end), onclick: clipSelection });
  items.push({ label: "Restore verbatim", sub: restorable ? "undo cleanup / edits" : "nothing to restore", disabled: !restorable, onclick: function () {
    editCall("segments/restore", { segmentIds: ids }, "Original wording restored.");
  } });
  items.push("-");
  const mayDelete = !!(S.job && S.job.canManage);
  items.push({ label: "Delete " + (n === 1 ? "this sentence" : n + " sentences") + "…", danger: true, disabled: !mayDelete,
    sub: mayDelete ? null : "owner or admin only", onclick: function () {
    if (!confirm("Delete " + n + " " + noun + " from the transcript? This also changes the transcript on the Mac Mini and cannot be undone.")) return;
    editCall("segments/delete", { segmentIds: ids }, (n === 1 ? "Sentence" : n + " sentences") + " deleted.");
  } });
  showMenu(e.currentTarget, items);
});

function openEditDialog(seg) {
  const ta = h("textarea", { "aria-label": "Sentence text" });
  ta.value = seg.text;
  const dlg = showModal({
    title: "Edit text",
    hint: nameFor(seg.speaker) + " · " + fmtTime(seg.start) + ". The original wording is kept and can be restored later.",
    body: [ta],
    buttons: [
      h("button", { class: "btn", type: "button", text: "Cancel", onclick: function () { dlg.close(); } }),
      h("button", { class: "btn primary", type: "button", text: "Save", onclick: save })
    ]
  });
  ta.focus();
  ta.setSelectionRange(ta.value.length, ta.value.length);
  ta.addEventListener("keydown", function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); save(); }
  });
  async function save() {
    const text = ta.value.trim();
    if (text === seg.text.trim()) { dlg.close(); return; }
    if (!text && !(S.job && S.job.canManage)) { toast("Only the person who submitted this transcript (or an admin) can delete sentences."); return; }
    if (!text && !confirm("Empty text deletes this sentence. Delete it?")) return;
    dlg.close();
    editCall("segments/text", { segmentId: seg.id, text: text }, text ? "Saved." : "Sentence deleted.");
  }
}

// Speaker identity (voiceprint) — the Speakers panel's Identify / Clear.
async function identifySpeaker(label, name) {
  try {
    await api("/api/jobs/" + S.jobId + "/speakers/identify", { method: "POST", json: { label: label, name: name } });
    toast(name ? "Identified as " + name + "." : "Identity cleared.");
    refreshNow();
  } catch (e) { toast(e.message); }
}

/// opts: {title, hint, current, onPick(name), onClear}
function openIdentityPicker(opts) {
  const search = h("input", { type: "text", placeholder: "Search names…", "aria-label": "Search names", autocomplete: "off" });
  const list = h("div", { class: "idlist" }, h("div", { class: "none", text: "Loading names…" }));
  const buttons = [];
  if (opts.onClear) {
    buttons.push(h("button", { class: "btn danger", type: "button", text: "Clear identity", onclick: function () { dlg.close(); opts.onClear(); } }));
  }
  buttons.push(h("span", { class: "grow" }));
  buttons.push(h("button", { class: "btn", type: "button", text: "Cancel", onclick: function () { dlg.close(); } }));
  const dlg = showModal({ title: opts.title, hint: opts.hint, body: [search, list], buttons: buttons });
  // On a phone, focusing would raise the keyboard over the list; let them scroll first.
  if (!(window.matchMedia && window.matchMedia("(pointer: coarse)").matches)) search.focus();
  let first = null;
  function pick(name) { dlg.close(); opts.onPick(name); }
  function render() {
    const q = search.value.trim().toLowerCase();
    const ids = S.identities;
    list.textContent = "";
    first = null;
    if (!ids) { list.appendChild(h("div", { class: "none", text: "Loading names…" })); return; }
    let shown = 0;
    const seen = new Set();
    function section(name, names) {
      const hits = names.filter(function (n) { return !seen.has(n) && (!q || n.toLowerCase().includes(q)); });
      if (!hits.length) return;
      list.appendChild(h("div", { class: "mh", text: name }));
      for (const n of hits) {
        seen.add(n);
        const b = h("button", { type: "button", onclick: function () { pick(n); } }, [
          h("span", { text: n }),
          n === opts.current ? h("span", { class: "chk", text: "✓" }) : null
        ]);
        if (!first) { first = n; b.classList.add("first"); }
        list.appendChild(b);
        shown++;
        if (shown >= 400) return;
      }
    }
    if (ids.session.length) section("In this transcript", ids.session);
    for (const g of ids.library) { if (shown >= 400) break; section(g.name, g.names); }
    if (q && !seen.has(search.value.trim())) {
      list.appendChild(h("div", { class: "mh", text: shown ? "Or" : "No matching enrolled voice" }));
      const custom = search.value.trim();
      const b = h("button", { type: "button", onclick: function () { pick(custom); } }, h("span", { text: "Use “" + custom + "”" }));
      if (!first) { first = custom; b.classList.add("first"); }
      list.appendChild(b);
    } else if (!shown) {
      list.appendChild(h("div", { class: "none", text: ids.libraryLoaded ? "No enrolled voices." : "The enrolled voices haven't loaded on the Mac Mini yet — type a name to use it anyway." }));
    }
  }
  search.addEventListener("input", render);
  search.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && first) { e.preventDefault(); pick(first); }
  });
  render();
  if (!S.identities) {
    api("/api/jobs/" + S.jobId + "/identities").then(function (r) {
      S.identities = r;
      if (dlg.isOpen()) render();
    }).catch(function (e) {
      S.identities = { session: [], library: [], libraryLoaded: false };
      if (dlg.isOpen()) render();
      toast(e.message);
    });
  }
}

// ---------- popover menu + modal ----------
function closePopups() {
  document.querySelectorAll(".menu, .overlay").forEach(function (n) { n.remove(); });
  document.removeEventListener("keydown", popupKeys);
}
function closeMenus() {
  document.querySelectorAll(".menu").forEach(function (n) { n.remove(); });
}
function popupKeys(e) { if (e.key === "Escape") closePopups(); }

/// items: {label, sub, swatch, checked, danger, disabled, onclick} | {header} | "-"
function showMenu(anchor, items) {
  closePopups();
  const menu = h("div", { class: "menu", role: "menu" });
  for (const it of items) {
    if (it === "-") { menu.appendChild(h("hr")); continue; }
    if (it.header) { menu.appendChild(h("div", { class: "mh", text: it.header })); continue; }
    menu.appendChild(h("button", {
      type: "button", class: it.danger ? "danger" : null, disabled: !!it.disabled, role: "menuitem",
      onclick: function () { closePopups(); if (it.onclick) it.onclick(); }
    }, [
      it.swatch !== undefined ? h("span", { class: "sw " + speakerClass(it.swatch) }) : null,
      h("span", { text: it.label }),
      it.checked ? h("span", { class: "chk", text: "✓" }) : null,
      it.sub ? h("span", { class: "sub", text: it.sub }) : null
    ]));
  }
  document.body.appendChild(menu);
  const r = anchor.getBoundingClientRect();
  const w = menu.offsetWidth;
  menu.style.bottom = Math.max(8, window.innerHeight - r.top + 8) + "px";
  menu.style.left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8)) + "px";
  const f = menu.querySelector("button:not(:disabled)");
  if (f) f.focus();
  setTimeout(function () {
    document.addEventListener("click", function outside(e) {
      if (!menu.contains(e.target)) { closeMenus(); }
      document.removeEventListener("click", outside);
    });
  }, 0);
  document.addEventListener("keydown", popupKeys);
}

/// opts: {title, hint, body: [nodes], buttons: [nodes]}
function showModal(opts) {
  closePopups();
  const card = h("div", { class: "dlg", role: "dialog", "aria-modal": "true" }, [
    h("div", { class: "dh" }, [h("h3", { text: opts.title }), opts.hint ? h("div", { class: "hint", text: opts.hint }) : null]),
    h("div", { class: "db" }, opts.body),
    opts.buttons && opts.buttons.length ? h("div", { class: "df" }, opts.buttons) : null
  ]);
  const overlay = h("div", { class: "overlay", onclick: function (e) { if (e.target === overlay) closePopups(); } }, card);
  document.body.appendChild(overlay);
  document.addEventListener("keydown", popupKeys);
  return {
    close: function () { overlay.remove(); document.removeEventListener("keydown", popupKeys); },
    isOpen: function () { return overlay.isConnected; }
  };
}

function refreshNow() {
  stopJobPolling();
  pollJob();
}

function renderSpeakers() {
  const box = $("speakers");
  if (!box) return;
  const active = document.activeElement;
  // Don't clobber a name someone is typing.
  if (active && active.getAttribute && active.getAttribute("data-label") && box.contains(active)) return;
  box.textContent = "";
  if (!S.speakers.length) {
    box.appendChild(h("div", { class: "hint", text: "Speakers appear as they're detected." }));
    return;
  }
  for (const sp of S.speakers) {
    const input = h("input", {
      type: "text", value: sp.source === "rename" ? sp.name : "", placeholder: sp.source === "voiceprint" ? sp.name : sp.label,
      "data-label": sp.label, "aria-label": "Name for " + sp.label,
      onkeydown: function (e) { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = sp.source === "rename" ? sp.name : ""; e.target.blur(); } },
      onchange: function (e) { renameSpeaker(sp.label, e.target.value); }
    });
    let src = sp.label;
    if (sp.identity && sp.source === "rename") src = sp.label + " · renamed · voice: " + sp.identity;
    else if (sp.identity) src = sp.label + " · identified by voice";
    else if (sp.source === "rename") src = sp.label + " · renamed";
    box.appendChild(h("div", { class: "spk" }, [
      h("span", { class: "sw " + speakerClass(sp.label) }),
      input,
      h("span", { class: "cnt", text: String(sp.count) }),
      h("span", { class: "src" }, [
        src,
        h("button", { type: "button", class: "ident", text: sp.identity ? "Change" : "Identify", title: "Match this speaker to an enrolled voice",
          onclick: function () { openSpeakerIdentity(sp); } }),
        sp.identity ? h("button", { type: "button", class: "danger", text: "Clear", title: "Remove the voice identification",
          onclick: function () { identifySpeaker(sp.label, ""); } }) : null
      ])
    ]));
  }
}

function openSpeakerIdentity(sp) {
  openIdentityPicker({
    title: "Identify " + sp.label,
    hint: "Every sentence from this speaker takes the name" + (S.job && S.job.live ? ", including ones still to come." : "."),
    current: sp.identity || null,
    onPick: function (name) { identifySpeaker(sp.label, name); },
    onClear: sp.identity ? function () { identifySpeaker(sp.label, ""); } : null
  });
}

async function renameSpeaker(label, name) {
  try {
    await api("/api/jobs/" + S.jobId + "/speakers", { method: "POST", json: { label: label, name: name } });
    refreshNow();
  } catch (e) { toast(e.message); }
}

function renderPins() {
  const box = $("pins");
  if (!box) return;
  box.textContent = "";
  if (!S.pins.length) {
    box.appendChild(h("div", { class: "hint", text: "Tap any sentence in the transcript to pin it." }));
    return;
  }
  const sorted = S.pins.slice().sort(function (a, b) { return a.start - b.start; });
  for (const p of sorted) {
    box.appendChild(h("div", { class: "pinrow" }, [
      h("div", { class: "pm" }, [
        h("span", { class: "pn " + speakerClass(p.speaker), style: "font-weight:600", text: nameFor(p.speaker) }),
        h("span", { text: fmtTime(p.start) }),
        p.keyword ? h("span", { text: "· keyword: " + p.keyword }) : null,
        h("button", { class: "x", title: "Remove pin", text: "×", onclick: function () { unpin(p.id); } })
      ]),
      h("div", { class: "pt", text: p.text, onclick: function () { jumpTo(p.segmentId); } }),
      playerReady() ? h("div", { class: "pa" }, [
        h("button", { type: "button", text: "▶ Play", onclick: function () { playFrom(p.start); } }),
        h("button", { type: "button", text: "Download clip", onclick: function () { downloadClip(p.start, p.end); } })
      ]) : null
    ]));
  }
}

async function unpin(pinId) {
  try {
    await api("/api/jobs/" + S.jobId + "/pins/" + pinId + "/delete", { method: "POST", json: {} });
    refreshNow();
  } catch (e) { toast(e.message); }
}

function jumpTo(segId) {
  if (!segId) return;
  const el = document.querySelector('.seg[data-id="' + segId + '"]');
  if (!el) return;
  S.follow = false;
  if ($("follow")) $("follow").checked = false;
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  el.classList.add("sel");
  setTimeout(function () { if (!S.sel.has(segId)) el.classList.remove("sel"); }, 1600);
}

async function stopJob() {
  const j = S.job;
  if (!j) return;
  const verb = j.status === "queued" ? "Cancel" : "Stop";
  if (!confirm(verb + " this transcript?" + (j.status === "queued" ? "" : " What's been transcribed so far is kept."))) return;
  try {
    await api("/api/jobs/" + j.id + "/stop", { method: "POST", json: {} });
    refreshNow();
  } catch (e) { toast(e.message); }
}

async function retryJob() {
  const j = S.job;
  if (!j) return;
  try {
    const nj = await api("/api/jobs/" + j.id + "/retry", { method: "POST", json: {} });
    location.hash = "#/job/" + nj.id;
  } catch (e) { toast(e.message); }
}

async function deleteJob() {
  const j = S.job;
  if (!j) return;
  if (!confirm("Delete this transcript for everyone? This can't be undone.")) return;
  try {
    await api("/api/jobs/" + j.id + "/delete", { method: "POST", json: {} });
    location.hash = "#/";
  } catch (e) { toast(e.message); }
}

// ---------- background polling ----------
async function tick() {
  await refreshStatus();
  if (S.view === "home") await refreshJobs();
  const dls = S.status && S.status.options.downloads ? Object.values(S.status.options.downloads) : [];
  const downloading = dls.some(function (d) { return d.state === "downloading" || d.state === "loading"; });
  const busy = S.status && (S.status.engine.active || S.status.queue.queued > 0 || downloading);
  setTimeout(tick, document.hidden ? 15000 : (busy ? 3000 : 6000));
}
document.addEventListener("visibilitychange", function () {
  if (!document.hidden && S.view === "job") refreshNow();
});

(async function boot() {
  await refreshStatus();
  route();
  setTimeout(tick, 3000);
})();
</script>
</body>
</html>
"""#
}
