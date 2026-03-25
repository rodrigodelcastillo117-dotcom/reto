"""
╔══════════════════════════════════════════════════════════════╗
║           RETO 13M — App Standalone v1.0                    ║
║   Streamlit · Google Sheets · Multi-usuario · Analytics     ║
╚══════════════════════════════════════════════════════════════╝
requirements:
    streamlit>=1.32
    gspread>=5.12
    oauth2client>=4.1.3
    pandas>=2.0
    plotly>=5.20

secrets.toml:
    [gsheets]
    type = "service_account"
    project_id = "..."
    private_key_id = "..."
    private_key = "..."
    client_email = "..."
    ...
    spreadsheet_id = "TU_SPREADSHEET_ID"
"""

import streamlit as st
import gspread
import pandas as pd
import plotly.graph_objects as go
import plotly.express as px
from oauth2client.service_account import ServiceAccountCredentials
from datetime import datetime, date, timedelta
import json, math, random

# ─────────────────────────────────────────────────────────────
#  PAGE CONFIG
# ─────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Reto 13M",
    page_icon="💰",
    layout="wide",
    initial_sidebar_state="collapsed",
)

# ─────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────
RETO_GOAL   = 13_000_000
START_BANK  = 10_000.0
TAB_PICKS   = "sheet_picks"   # one tab per user  → "picks_{apodo}"
TAB_USERS   = "usuarios"

RANGOS = [
    {"min": 0,           "max": 50_000,      "icon": "🥉", "nombre": "Rookie",        "color": "#CD7F32"},
    {"min": 50_000,      "max": 200_000,     "icon": "🥈", "nombre": "Apostador",     "color": "#C0C0C0"},
    {"min": 200_000,     "max": 500_000,     "icon": "🥇", "nombre": "Pro",           "color": "#FFD700"},
    {"min": 500_000,     "max": 1_500_000,   "icon": "💎", "nombre": "Élite",         "color": "#00CFFF"},
    {"min": 1_500_000,   "max": 5_000_000,   "icon": "👑", "nombre": "Leyenda",       "color": "#9B6DFF"},
    {"min": 5_000_000,   "max": 13_000_000,  "icon": "🔥", "nombre": "Inmortal",      "color": "#FF6B00"},
    {"min": 13_000_000,  "max": float("inf"),"icon": "🏆", "nombre": "GRADUADO",      "color": "#FFD60A"},
]

# ─────────────────────────────────────────────────────────────
#  CSS
# ─────────────────────────────────────────────────────────────
def inject_css():
    st.markdown("""
<style>
@import url('https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@400;600;700;800;900&family=Inter:wght@400;500;600;700&display=swap');

:root {
  --bg:    #0A0A0B;
  --bg2:   #111113;
  --bg3:   #1A1A1E;
  --bg4:   #222228;
  --bg5:   #2A2A32;
  --orange:#FF6B00;
  --gold:  #FFD60A;
  --green: #22C55E;
  --red:   #EF4444;
  --blue:  #3B82F6;
  --purple:#9B6DFF;
  --text:  #F1F1F3;
  --text2: #A0A0AB;
  --text3: #6B6B78;
  --card-r:14px;
}

html, body, .stApp, [data-testid="stAppViewContainer"],
[data-testid="stMain"], .main { background:#0A0A0B !important; color:var(--text) !important; }

* { font-family:'Inter',sans-serif; box-sizing:border-box; }
h1,h2,h3,.barlow { font-family:'Barlow Condensed',sans-serif !important; }

/* hide streamlit chrome */
#MainMenu,footer,[data-testid="stToolbar"],
[data-testid="stDecoration"],[data-testid="stStatusWidget"] { display:none !important; }
header[data-testid="stHeader"] { display:none !important; }

/* block container */
.block-container { padding:0 16px 80px !important; max-width:900px !important; margin:0 auto; }

/* ── CARDS ── */
.card {
  background:var(--bg3);
  border:1px solid rgba(255,255,255,0.06);
  border-radius:var(--card-r);
  padding:18px;
  margin-bottom:14px;
}
.card-gold { border-color:rgba(255,214,10,0.25); background:linear-gradient(135deg,rgba(255,107,0,0.08),rgba(255,214,10,0.06)); }
.card-green { border-color:rgba(34,197,94,0.25); background:rgba(34,197,94,0.04); }
.card-red   { border-color:rgba(239,68,68,0.25);  background:rgba(239,68,68,0.04); }

/* ── HERO ── */
.hero-bank {
  font-family:'Barlow Condensed',sans-serif;
  font-size:3.2rem; font-weight:900; color:var(--gold); line-height:1;
}
.hero-label {
  font-size:0.6rem; font-weight:700; letter-spacing:3px;
  text-transform:uppercase; color:var(--text3); margin-bottom:4px;
}
.hero-meta { font-size:0.72rem; color:var(--text3); margin-top:4px; }

/* ── PROGRESS BAR ── */
.prog-wrap { background:rgba(255,255,255,0.06); border-radius:99px; height:10px; overflow:hidden; margin:10px 0 4px; }
.prog-fill { height:100%; border-radius:99px; background:linear-gradient(90deg,#FF6B00,#FFD60A); transition:width 0.6s; }

/* ── MILESTONE DOTS ── */
.ms-row { display:flex; justify-content:space-between; margin-top:6px; }
.ms-dot { display:flex; flex-direction:column; align-items:center; gap:2px; }
.ms-circle {
  width:10px; height:10px; border-radius:50%;
  border:2px solid rgba(255,255,255,0.15);
}
.ms-circle.reached { background:var(--gold); border-color:var(--gold); }
.ms-label { font-size:0.45rem; color:var(--text3); }

/* ── KPI GRID ── */
.kpi-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:14px; }
.kpi-box {
  background:var(--bg3); border:1px solid rgba(255,255,255,0.06);
  border-radius:10px; padding:12px 8px; text-align:center;
}
.kpi-val { font-family:'Barlow Condensed',sans-serif; font-size:1.45rem; font-weight:900; color:var(--text); }
.kpi-lbl { font-size:0.55rem; color:var(--text3); letter-spacing:1px; text-transform:uppercase; margin-top:2px; }

/* ── SECTION HEADING ── */
.sec-head {
  font-family:'Barlow Condensed',sans-serif;
  font-size:0.68rem; font-weight:800; letter-spacing:3px;
  text-transform:uppercase; color:var(--text3);
  display:flex; align-items:center; gap:8px;
  margin:22px 0 10px;
}
.sec-head::before {
  content:''; width:3px; height:14px;
  background:var(--orange); border-radius:2px; flex-shrink:0;
}

/* ── PICK CARDS ── */
.pick-card {
  background:var(--bg3); border:1px solid rgba(255,255,255,0.06);
  border-radius:10px; padding:12px 14px;
  display:flex; align-items:center; gap:12px;
  margin-bottom:8px;
}
.pick-badge {
  width:36px; height:36px; border-radius:50%;
  display:flex; align-items:center; justify-content:center;
  font-size:1rem; flex-shrink:0; font-weight:900;
}
.pick-badge.g { background:rgba(34,197,94,0.15); border:1px solid #22C55E; }
.pick-badge.p { background:rgba(239,68,68,0.15);  border:1px solid #EF4444; }
.pick-badge.n { background:rgba(107,114,128,0.15); border:1px solid #6B7280; }

/* ── BUTTONS ── */
div.stButton > button {
  background:linear-gradient(170deg,var(--bg4),var(--bg5)) !important;
  border:1px solid rgba(255,255,255,0.1) !important;
  color:var(--text) !important; border-radius:10px !important;
  font-weight:600 !important; transition:all .2s !important;
  width:100% !important;
}
div.stButton > button:hover {
  transform:translateY(-1px) !important;
  border-color:var(--orange) !important;
  box-shadow:0 4px 16px rgba(255,107,0,0.2) !important;
}
div.stButton > button[kind="primary"] {
  background:linear-gradient(135deg,var(--orange),#FF8C00) !important;
  border-color:var(--orange) !important; color:#000 !important; font-weight:800 !important;
}

/* ── INPUTS ── */
div[data-testid="stTextInput"] input,
div[data-testid="stSelectbox"] > div > div,
div[data-testid="stNumberInput"] input {
  background:var(--bg4) !important; border:1px solid rgba(255,255,255,0.1) !important;
  color:var(--text) !important; border-radius:8px !important;
}
div[data-testid="stDateInput"] input { background:var(--bg4) !important; color:var(--text) !important; }

/* ── TABS (top nav) ── */
div[data-testid="stTabs"] [role="tablist"] {
  background:var(--bg2) !important; border-radius:10px !important;
  border:1px solid rgba(255,255,255,0.06) !important;
  padding:4px !important; gap:2px !important;
}
div[data-testid="stTabs"] button[role="tab"] {
  background:transparent !important; border-radius:8px !important;
  color:var(--text2) !important; font-weight:600 !important;
  font-size:0.72rem !important;
}
div[data-testid="stTabs"] button[role="tab"][aria-selected="true"] {
  background:var(--bg4) !important; color:var(--orange) !important;
}

/* ── METRICS ── */
div[data-testid="stMetric"] { background:var(--bg3); border-radius:10px; padding:12px; border:1px solid rgba(255,255,255,0.06); }
div[data-testid="stMetricValue"] { font-family:'Barlow Condensed',sans-serif !important; font-size:1.6rem !important; }

/* ── EXPANDER ── */
div[data-testid="stExpander"] details { background:var(--bg3) !important; border:1px solid rgba(255,255,255,0.08) !important; border-radius:10px !important; }
div[data-testid="stExpander"] summary { color:var(--text) !important; }

/* ── SCROLLBAR ── */
::-webkit-scrollbar { width:4px; height:4px; }
::-webkit-scrollbar-track { background:transparent; }
::-webkit-scrollbar-thumb { background:var(--bg5); border-radius:99px; }

/* ── RANG BADGE ── */
.rang-badge {
  display:inline-flex; align-items:center; gap:6px;
  padding:4px 12px; border-radius:99px;
  font-family:'Barlow Condensed',sans-serif;
  font-size:0.85rem; font-weight:800; letter-spacing:1px;
}

/* ── RACHA ── */
.racha-row { display:flex; gap:4px; flex-wrap:wrap; margin:8px 0; }
.racha-dot {
  width:22px; height:22px; border-radius:50%;
  display:flex; align-items:center; justify-content:center;
  font-size:0.7rem; font-weight:800;
}
.racha-dot.g { background:rgba(34,197,94,0.2); border:1px solid #22C55E; color:#22C55E; }
.racha-dot.p { background:rgba(239,68,68,0.2);  border:1px solid #EF4444; color:#EF4444; }
.racha-dot.n { background:rgba(107,114,128,0.15); border:1px solid #6B7280; color:#6B7280; }

/* ── LEADERBOARD ── */
.lb-row {
  display:flex; align-items:center; gap:10px;
  padding:10px 14px; border-radius:10px;
  background:var(--bg3); border:1px solid rgba(255,255,255,0.06);
  margin-bottom:6px;
}
.lb-row.me { border-color:rgba(255,214,10,0.35); background:rgba(255,214,10,0.05); }
.lb-avatar {
  width:34px; height:34px; border-radius:50%;
  background:linear-gradient(135deg,#9B6DFF,#C9A84C);
  display:flex; align-items:center; justify-content:center;
  font-weight:900; font-size:0.85rem; color:#0A0A0B; flex-shrink:0;
}

/* ── CHALLENGE CARD ── */
.challenge-card {
  background:linear-gradient(135deg,rgba(155,109,255,0.12),rgba(255,107,0,0.08));
  border:1px solid rgba(155,109,255,0.3);
  border-radius:14px; padding:18px; text-align:center;
  margin-bottom:14px;
}

/* ── FORM CARD ── */
.form-card {
  background:var(--bg3); border:1px solid rgba(255,255,255,0.08);
  border-radius:14px; padding:20px; margin-bottom:14px;
}

/* ── TILT ALERT ── */
.tilt-alert {
  background:rgba(239,68,68,0.1); border:1px solid rgba(239,68,68,0.4);
  border-radius:10px; padding:12px 16px; margin-bottom:14px;
  font-size:0.8rem; color:#FCA5A5;
}

/* ── LEAGUE STAT ROW ── */
.league-row {
  display:flex; align-items:center; gap:10px;
  padding:8px 12px; border-radius:8px;
  background:var(--bg3); border:1px solid rgba(255,255,255,0.05);
  margin-bottom:5px;
}
.league-bar-wrap { flex:1; background:rgba(255,255,255,0.06); border-radius:99px; height:6px; overflow:hidden; }
.league-bar-fill { height:100%; border-radius:99px; }

/* ── CONFETTI ANIMATION ── */
@keyframes confettiFall {
  0%   { transform:translateY(-20px) rotate(0deg); opacity:1; }
  100% { transform:translateY(100vh) rotate(720deg); opacity:0; }
}
.confetti-piece {
  position:fixed; width:8px; height:8px; border-radius:2px;
  animation:confettiFall 2.5s ease-in forwards;
  z-index:9999; pointer-events:none;
}

/* ── WASTED ── */
@keyframes wastedFade {
  0%   { opacity:0; transform:scale(2); filter:blur(8px); }
  30%  { opacity:1; transform:scale(1); filter:blur(0); }
  80%  { opacity:1; }
  100% { opacity:0; }
}
.wasted-overlay {
  position:fixed; top:0; left:0; width:100%; height:100%;
  background:rgba(0,0,0,0.75); display:flex; align-items:center; justify-content:center;
  z-index:9999; animation:wastedFade 2.5s ease forwards;
  font-family:'Barlow Condensed',sans-serif; font-size:5rem; font-weight:900;
  color:#EF4444; letter-spacing:8px; pointer-events:none;
}
</style>
""", unsafe_allow_html=True)


# ─────────────────────────────────────────────────────────────
#  GOOGLE SHEETS
# ─────────────────────────────────────────────────────────────
SCOPE = [
    "https://spreadsheets.google.com/feeds",
    "https://www.googleapis.com/auth/drive",
]

@st.cache_resource(ttl=60)
def get_client():
    try:
        creds_dict = {k: v for k, v in st.secrets["gsheets"].items() if k != "spreadsheet_id"}
        creds = ServiceAccountCredentials.from_json_keyfile_dict(creds_dict, SCOPE)
        return gspread.authorize(creds)
    except Exception as e:
        return None

def get_spreadsheet():
    client = get_client()
    if not client:
        return None
    try:
        sid = st.secrets["gsheets"]["spreadsheet_id"]
        return client.open_by_key(sid)
    except Exception:
        return None

def ensure_tab(ss, tab_name: str, headers: list):
    """Create tab if missing, return worksheet."""
    try:
        ws = ss.worksheet(tab_name)
    except gspread.WorksheetNotFound:
        ws = ss.add_worksheet(title=tab_name, rows=1000, cols=len(headers))
        ws.append_row(headers)
    return ws

# ── Picks columns
PICKS_HEADERS = [
    "fecha","partido","liga","mercado","pick","momio",
    "apuesta","resultado","ganancia_neta","bankroll_post","notas"
]

def load_picks(apodo: str) -> pd.DataFrame:
    ss = get_spreadsheet()
    if not ss:
        return pd.DataFrame(columns=PICKS_HEADERS)
    tab = f"picks_{apodo.lower()}"
    ws  = ensure_tab(ss, tab, PICKS_HEADERS)
    data = ws.get_all_records()
    if not data:
        return pd.DataFrame(columns=PICKS_HEADERS)
    df = pd.DataFrame(data)
    df["fecha"] = pd.to_datetime(df["fecha"], errors="coerce")
    for col in ["momio","apuesta","ganancia_neta","bankroll_post"]:
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    return df

def save_pick(apodo: str, row: dict):
    ss = get_spreadsheet()
    if not ss:
        st.error("❌ Google Sheets no configurado")
        return False
    tab = f"picks_{apodo.lower()}"
    ws  = ensure_tab(ss, tab, PICKS_HEADERS)
    ws.append_row([str(row.get(h,"")) for h in PICKS_HEADERS])
    return True

def update_pick_result(apodo: str, row_idx: int, resultado: str, ganancia: float, bank_post: float):
    """row_idx is 0-based DataFrame index → sheet row = idx+2 (header=1)."""
    ss = get_spreadsheet()
    if not ss:
        return False
    tab = f"picks_{apodo.lower()}"
    ws  = ensure_tab(ss, tab, PICKS_HEADERS)
    sheet_row = row_idx + 2
    # resultado col = 8, ganancia_neta = 9, bankroll_post = 10
    ws.update_cell(sheet_row, 8,  resultado)
    ws.update_cell(sheet_row, 9,  round(ganancia, 2))
    ws.update_cell(sheet_row, 10, round(bank_post, 2))
    return True

def load_users() -> list:
    ss = get_spreadsheet()
    if not ss:
        return []
    ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","picks_ganados","picks_perdidos","created"])
    data = ws.get_all_records()
    return data

def upsert_user(apodo: str, bankroll: float, wins: int, losses: int):
    ss = get_spreadsheet()
    if not ss:
        return
    ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","picks_ganados","picks_perdidos","created"])
    records = ws.get_all_records()
    for i, r in enumerate(records):
        if r.get("apodo","").lower() == apodo.lower():
            ws.update(f"A{i+2}:E{i+2}", [[apodo, round(bankroll,2), wins, losses, r.get("created","")]])
            return
    ws.append_row([apodo, round(bankroll,2), wins, losses, str(date.today())])


# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────
def get_bankroll(df: pd.DataFrame) -> float:
    pend = df[df["resultado"] == "pendiente"]
    resolved = df[df["resultado"] != "pendiente"]
    if resolved.empty and pend.empty:
        return START_BANK
    if resolved.empty:
        return START_BANK
    last = resolved.sort_values("fecha").iloc[-1]
    bank = float(last["bankroll_post"]) if last["bankroll_post"] else START_BANK
    return bank

def get_rango(bank: float) -> dict:
    for r in RANGOS:
        if r["min"] <= bank < r["max"]:
            return r
    return RANGOS[-1]

def kelly_fraction(momio: float, win_pct: float = 0.55) -> float:
    """Simple Kelly. momio in decimal format."""
    if momio <= 1:
        return 0
    b = momio - 1
    q = 1 - win_pct
    kelly = (b * win_pct - q) / b
    return max(0, min(kelly * 0.25, 0.05))   # quarter-Kelly, max 5%

def racha_html(results: list) -> str:
    icons = {"ganado":"✓","perdido":"✗","nulo":"−","pendiente":"·"}
    cls   = {"ganado":"g","perdido":"p","nulo":"n","pendiente":"n"}
    dots  = "".join(
        '<div class="racha-dot {}">{}</div>'.format(cls.get(r,"n"), icons.get(r,"·"))
        for r in results[-12:]
    )
    return f'<div class="racha-row">{dots}</div>'

def confetti_html() -> str:
    colors = ["#FF6B00","#FFD60A","#22C55E","#9B6DFF","#3B82F6","#EC4899"]
    pieces = ""
    for i in range(60):
        c   = random.choice(colors)
        lft = random.randint(0, 100)
        dly = random.uniform(0, 1.5)
        rot = random.randint(-180, 180)
        pieces += (
            f'<div class="confetti-piece" style="left:{lft}%;background:{c};'
            f'animation-delay:{dly:.2f}s;transform:rotate({rot}deg)"></div>'
        )
    return pieces

def wasted_html() -> str:
    return '<div class="wasted-overlay">W A S T E D</div>'


# ─────────────────────────────────────────────────────────────
#  LOGIN SCREEN
# ─────────────────────────────────────────────────────────────
def render_login():
    st.markdown("""
<div style="text-align:center;padding:60px 20px 20px">
  <div style="font-family:'Barlow Condensed',sans-serif;font-size:3.5rem;font-weight:900;
       background:linear-gradient(135deg,#FF6B00,#FFD60A);-webkit-background-clip:text;
       -webkit-text-fill-color:transparent;line-height:1">RETO 13M</div>
  <div style="font-size:0.7rem;color:#6B7280;letter-spacing:4px;text-transform:uppercase;
       margin-top:4px">Apostador Graduado</div>
  <div style="font-size:2rem;margin:16px 0">💰</div>
  <div style="font-size:0.85rem;color:#A0A0AB;max-width:360px;margin:0 auto">
    Transforma <strong style="color:#FFD60A">$10,000</strong> en
    <strong style="color:#FFD60A">$13,000,000</strong> con disciplina y análisis.
  </div>
</div>
""", unsafe_allow_html=True)

    col = st.columns([1, 2, 1])[1]
    with col:
        apodo = st.text_input("", placeholder="Tu apodo (ej: RodrigoMX)", label_visibility="collapsed")
        if st.button("🚀 Entrar al Reto", type="primary"):
            if apodo.strip():
                st.session_state["apodo"] = apodo.strip()
                st.rerun()
            else:
                st.error("Escribe tu apodo")


# ─────────────────────────────────────────────────────────────
#  HEADER BAR
# ─────────────────────────────────────────────────────────────
def render_header(apodo: str, bank: float):
    rango = get_rango(bank)
    pct   = min(100, bank / RETO_GOAL * 100)

    # Milestones
    milestones = [100_000, 500_000, 1_000_000, 5_000_000, 13_000_000]
    ms_dots = ""
    for ms in milestones:
        reached = bank >= ms
        label   = f"${ms//1_000_000}M" if ms >= 1_000_000 else f"${ms//1_000}K"
        ms_dots += (
            f'<div class="ms-dot">'
            f'<div class="ms-circle {"reached" if reached else ""}"></div>'
            f'<div class="ms-label">{label}</div>'
            f'</div>'
        )

    st.markdown(f"""
<div class="card card-gold" style="margin-top:16px">
  <div style="display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:8px">
    <div>
      <div class="hero-label">Bankroll Actual</div>
      <div class="hero-bank">${bank:,.2f}</div>
      <div class="hero-meta">Meta: $13,000,000 MXN</div>
    </div>
    <div style="text-align:right">
      <div style="margin-bottom:4px">
        <span class="rang-badge" style="background:{rango['color']}22;border:1px solid {rango['color']}55;color:{rango['color']}">
          {rango['icon']} {rango['nombre']}
        </span>
      </div>
      <div style="font-size:0.7rem;color:#6B7280">Hola, <strong style="color:var(--gold)">{apodo}</strong></div>
      <div style="font-size:0.65rem;color:#6B7280;margin-top:2px">
        <span style="color:#A0A0AB;cursor:pointer;text-decoration:underline" onclick="window.location.reload()">
          Cambiar usuario
        </span>
      </div>
    </div>
  </div>
  <div class="prog-wrap"><div class="prog-fill" style="width:{pct:.4f}%"></div></div>
  <div style="display:flex;justify-content:space-between;align-items:center">
    <div style="font-size:0.6rem;color:#6B7280">{pct:.4f}% completado</div>
    <div style="font-size:0.6rem;color:#6B7280">${RETO_GOAL - bank:,.0f} restantes</div>
  </div>
  <div class="ms-row">{ms_dots}</div>
</div>
""", unsafe_allow_html=True)

    # Cambiar usuario button (hidden in sidebar)
    if st.sidebar.button("🚪 Cambiar usuario"):
        del st.session_state["apodo"]
        st.rerun()


# ─────────────────────────────────────────────────────────────
#  TAB 1 — REGISTRAR PICK
# ─────────────────────────────────────────────────────────────
def tab_registrar(apodo: str, df: pd.DataFrame, bank: float):
    st.markdown('<div class="sec-head">Registrar nuevo pick</div>', unsafe_allow_html=True)

    # Kelly suggestion
    kelly_pct = kelly_fraction(1.85)
    kelly_amt  = round(bank * kelly_pct, 2)

    with st.form("form_pick", clear_on_submit=True):
        c1, c2 = st.columns(2)
        with c1:
            partido  = st.text_input("Partido", placeholder="ej: Real Madrid vs Barça")
            liga     = st.selectbox("Liga", [
                "Premier League","La Liga","Serie A","Bundesliga","Ligue 1",
                "Liga MX","MLS","Champions League","Europa League","Copa Libertadores",
                "NBA","NFL","NHL","MLB","WNBA","Tenis","Otro"
            ])
            mercado  = st.selectbox("Mercado", [
                "ML (Ganador)","Over/Under","BTTS","Hándicap","Córners",
                "Resultado 1X2","Player Prop","Parlay","Otro"
            ])
        with c2:
            fecha_p  = st.date_input("Fecha del partido", value=date.today())
            momio    = st.number_input("Momio (decimal)", min_value=1.01, max_value=50.0, value=1.85, step=0.01)
            apuesta  = st.number_input(
                f"Apuesta ($MXN) — Kelly sugiere: ${kelly_amt:,.2f}",
                min_value=1.0, max_value=float(bank),
                value=min(kelly_amt, bank), step=100.0
            )
        pick_desc = st.text_input("Descripción del pick", placeholder="ej: Over 2.5 goles")
        notas     = st.text_area("Notas / análisis", placeholder="¿Por qué este pick?", height=80)

        submitted = st.form_submit_button("💾 Guardar pick", type="primary")

    if submitted:
        if not partido or not pick_desc:
            st.error("Llena Partido y Pick.")
        else:
            row = {
                "fecha":         str(fecha_p),
                "partido":       partido,
                "liga":          liga,
                "mercado":       mercado,
                "pick":          pick_desc,
                "momio":         momio,
                "apuesta":       apuesta,
                "resultado":     "pendiente",
                "ganancia_neta": 0,
                "bankroll_post": bank,
                "notas":         notas,
            }
            if save_pick(apodo, row):
                st.success("✅ Pick guardado en Google Sheets")
                st.rerun()

    # ── Picks pendientes (resolver)
    pendientes = df[df["resultado"] == "pendiente"].copy()
    if not pendientes.empty:
        st.markdown('<div class="sec-head">Resolver picks pendientes</div>', unsafe_allow_html=True)
        for idx, row in pendientes.iterrows():
            with st.expander(f"⏳  {row['partido']}  ·  {row['liga']}  ·  Momio {row['momio']}  ·  ${row['apuesta']:,.2f}"):
                c1, c2, c3 = st.columns(3)
                with c1:
                    if st.button("✅ Ganado", key=f"win_{idx}"):
                        gan = round(float(row["apuesta"]) * (float(row["momio"]) - 1), 2)
                        new_bank = round(bank + gan, 2)
                        update_pick_result(apodo, idx, "ganado", gan, new_bank)
                        st.session_state["fx"] = "confetti"
                        st.rerun()
                with c2:
                    if st.button("❌ Perdido", key=f"loss_{idx}"):
                        gan = -float(row["apuesta"])
                        new_bank = round(bank + gan, 2)
                        update_pick_result(apodo, idx, "perdido", gan, new_bank)
                        st.session_state["fx"] = "wasted"
                        st.rerun()
                with c3:
                    if st.button("➖ Nulo", key=f"null_{idx}"):
                        update_pick_result(apodo, idx, "nulo", 0, bank)
                        st.rerun()


# ─────────────────────────────────────────────────────────────
#  TAB 2 — HISTORIAL
# ─────────────────────────────────────────────────────────────
def tab_historial(df: pd.DataFrame):
    if df.empty:
        st.info("Sin picks registrados aún.")
        return

    # Filters
    c1, c2, c3 = st.columns(3)
    with c1:
        f_res = st.selectbox("Resultado", ["Todos","ganado","perdido","nulo","pendiente"])
    with c2:
        ligas_all = ["Todas"] + sorted(df["liga"].dropna().unique().tolist())
        f_liga = st.selectbox("Liga", ligas_all)
    with c3:
        f_merc = st.selectbox("Mercado", ["Todos"] + sorted(df["mercado"].dropna().unique().tolist()))

    filt = df.copy()
    if f_res  != "Todos":    filt = filt[filt["resultado"] == f_res]
    if f_liga != "Todas":    filt = filt[filt["liga"] == f_liga]
    if f_merc != "Todos":    filt = filt[filt["mercado"] == f_merc]

    filt = filt.sort_values("fecha", ascending=False)

    res_colors = {"ganado":"#22C55E","perdido":"#EF4444","nulo":"#6B7280","pendiente":"#F59E0B"}
    res_icons  = {"ganado":"✅","perdido":"❌","nulo":"➖","pendiente":"⏳"}

    for _, row in filt.iterrows():
        res = row.get("resultado","pendiente")
        clr = res_colors.get(res,"#888")
        ico = res_icons.get(res,"·")
        gan = float(row.get("ganancia_neta",0))
        gan_str = f'+${gan:,.2f}' if gan > 0 else f'${gan:,.2f}' if gan < 0 else "—"
        gan_color = "#22C55E" if gan > 0 else "#EF4444" if gan < 0 else "#6B7280"
        fecha_str = str(row.get("fecha",""))[:10]

        st.markdown(f"""
<div class="pick-card">
  <div class="pick-badge {res[0] if res in ('ganado','perdido') else 'n'}">{ico}</div>
  <div style="flex:1;min-width:0">
    <div style="font-size:0.82rem;font-weight:700;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
      {row.get('partido','')}
    </div>
    <div style="font-size:0.65rem;color:var(--text3);margin-top:2px">
      {row.get('liga','')} · {row.get('mercado','')} · {row.get('pick','')}
    </div>
    <div style="font-size:0.62rem;color:var(--text3)">{fecha_str}</div>
  </div>
  <div style="text-align:right;flex-shrink:0">
    <div style="font-family:'Barlow Condensed',sans-serif;font-size:1.1rem;font-weight:900;color:{gan_color}">{gan_str}</div>
    <div style="font-size:0.65rem;color:var(--text3)">Momio {row.get('momio','')} · ${float(row.get('apuesta',0)):,.0f}</div>
    <div style="font-size:0.6rem;color:{clr};font-weight:700">{res.upper()}</div>
  </div>
</div>
""", unsafe_allow_html=True)


# ─────────────────────────────────────────────────────────────
#  TAB 3 — ANALYTICS
# ─────────────────────────────────────────────────────────────
def tab_analytics(df: pd.DataFrame, bank: float):
    resolved = df[df["resultado"].isin(["ganado","perdido","nulo"])].copy()

    if resolved.empty:
        st.info("Necesitas al menos un pick resuelto para ver analytics.")
        return

    wins   = (resolved["resultado"] == "ganado").sum()
    losses = (resolved["resultado"] == "perdido").sum()
    total  = len(resolved)
    wr     = wins / total * 100 if total else 0
    roi    = resolved["ganancia_neta"].sum() / resolved["apuesta"].sum() * 100 if resolved["apuesta"].sum() else 0
    racha_list = resolved.sort_values("fecha")["resultado"].tolist()

    # Tilt alert
    last5 = racha_list[-5:]
    consec_losses = 0
    for r in reversed(last5):
        if r == "perdido":
            consec_losses += 1
        else:
            break
    if consec_losses >= 3:
        st.markdown(
            f'<div class="tilt-alert">🧠 <strong>Alerta de tilt:</strong> Llevas {consec_losses} pérdidas consecutivas. '
            f'Considera pausar y revisar tu estrategia.</div>',
            unsafe_allow_html=True
        )

    # ── KPIs
    st.markdown('<div class="sec-head">Resumen general</div>', unsafe_allow_html=True)
    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box">
    <div class="kpi-val">{total}</div>
    <div class="kpi-lbl">Total picks</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(34,197,94,0.2)">
    <div class="kpi-val" style="color:var(--green)">{wr:.1f}%</div>
    <div class="kpi-lbl">Win Rate</div>
  </div>
  <div class="kpi-box" style="border-color:rgba({'34,197,94' if roi>=0 else '239,68,68'},0.2)">
    <div class="kpi-val" style="color:{'var(--green)' if roi>=0 else 'var(--red)'}">
      {'+' if roi>=0 else ''}{roi:.1f}%
    </div>
    <div class="kpi-lbl">ROI</div>
  </div>
  <div class="kpi-box" style="border-color:rgba({'34,197,94' if resolved['ganancia_neta'].sum()>=0 else '239,68,68'},0.2)">
    <div class="kpi-val" style="color:{'var(--green)' if resolved['ganancia_neta'].sum()>=0 else 'var(--red)'}">
      ${resolved['ganancia_neta'].sum():,.0f}
    </div>
    <div class="kpi-lbl">Ganancia neta</div>
  </div>
</div>
""", unsafe_allow_html=True)

    # Racha
    st.markdown('<div class="sec-head">Racha reciente</div>', unsafe_allow_html=True)
    st.markdown(racha_html(racha_list), unsafe_allow_html=True)

    # ── Bankroll chart
    st.markdown('<div class="sec-head">Evolución del bankroll</div>', unsafe_allow_html=True)
    bank_df = resolved.sort_values("fecha").copy()
    bank_df["bankroll_post"] = pd.to_numeric(bank_df["bankroll_post"], errors="coerce")
    bank_data = [START_BANK] + bank_df["bankroll_post"].tolist()
    fig = go.Figure()
    fig.add_trace(go.Scatter(
        y=bank_data, mode="lines+markers",
        line=dict(color="#FF6B00", width=2),
        marker=dict(size=5, color="#FFD60A"),
        fill="tozeroy",
        fillcolor="rgba(255,107,0,0.08)",
    ))
    fig.add_hline(y=RETO_GOAL, line_dash="dot", line_color="#9B6DFF",
                  annotation_text="META $13M", annotation_font_color="#9B6DFF")
    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color="#A0A0AB"),
        margin=dict(l=10,r=10,t=10,b=10),
        height=220,
        xaxis=dict(showgrid=False, zeroline=False),
        yaxis=dict(showgrid=True, gridcolor="rgba(255,255,255,0.05)", zeroline=False),
    )
    st.plotly_chart(fig, use_container_width=True)

    # ── Stats por liga ────────────────────────────────────────
    st.markdown('<div class="sec-head">Rendimiento por liga</div>', unsafe_allow_html=True)

    liga_stats = []
    for liga, grp in resolved.groupby("liga"):
        g = (grp["resultado"] == "ganado").sum()
        p = (grp["resultado"] == "perdido").sum()
        t = len(grp)
        wr_l = g / t * 100 if t else 0
        roi_l = grp["ganancia_neta"].sum() / grp["apuesta"].sum() * 100 if grp["apuesta"].sum() else 0
        neto  = grp["ganancia_neta"].sum()
        liga_stats.append({"liga":liga,"g":g,"p":p,"t":t,"wr":wr_l,"roi":roi_l,"neto":neto})

    liga_stats.sort(key=lambda x: x["roi"], reverse=True)

    bar_colors = {
        range(0,200):    "#22C55E",
        range(-200,0):   "#EF4444",
    }

    for ls in liga_stats:
        wr_color = "#22C55E" if ls["wr"] >= 55 else "#F59E0B" if ls["wr"] >= 45 else "#EF4444"
        roi_color = "#22C55E" if ls["roi"] >= 0 else "#EF4444"
        bar_w = min(100, max(0, abs(ls["wr"])))
        bar_c = "#22C55E" if ls["wr"] >= 55 else "#F59E0B" if ls["wr"] >= 45 else "#EF4444"
        neto_str = f'+${ls["neto"]:,.0f}' if ls["neto"] >= 0 else f'${ls["neto"]:,.0f}'

        st.markdown(f"""
<div class="league-row">
  <div style="width:120px;font-size:0.72rem;font-weight:700;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
    {ls['liga']}
  </div>
  <div style="font-size:0.65rem;color:var(--text3);white-space:nowrap">
    {ls['g']}G/{ls['p']}P
  </div>
  <div class="league-bar-wrap">
    <div class="league-bar-fill" style="width:{bar_w}%;background:{bar_c}"></div>
  </div>
  <div style="font-size:0.72rem;font-weight:800;color:{wr_color};white-space:nowrap">
    {ls['wr']:.0f}%
  </div>
  <div style="font-size:0.72rem;font-weight:700;color:{roi_color};white-space:nowrap">
    ROI {'+' if ls['roi']>=0 else ''}{ls['roi']:.1f}%
  </div>
  <div style="font-size:0.72rem;font-weight:700;color:{roi_color};white-space:nowrap">
    {neto_str}
  </div>
</div>
""", unsafe_allow_html=True)

    # ── Stats por mercado
    st.markdown('<div class="sec-head">Rendimiento por mercado</div>', unsafe_allow_html=True)
    merc_stats = []
    for merc, grp in resolved.groupby("mercado"):
        g = (grp["resultado"] == "ganado").sum()
        p = (grp["resultado"] == "perdido").sum()
        t = len(grp)
        wr_m = g / t * 100 if t else 0
        roi_m = grp["ganancia_neta"].sum() / grp["apuesta"].sum() * 100 if grp["apuesta"].sum() else 0
        neto  = grp["ganancia_neta"].sum()
        merc_stats.append({"merc":merc,"g":g,"p":p,"t":t,"wr":wr_m,"roi":roi_m,"neto":neto})

    merc_stats.sort(key=lambda x: x["roi"], reverse=True)

    cols = st.columns(2)
    for i, ms in enumerate(merc_stats):
        roi_c = "#22C55E" if ms["roi"] >= 0 else "#EF4444"
        neto_str = f'+${ms["neto"]:,.0f}' if ms["neto"] >= 0 else f'${ms["neto"]:,.0f}'
        with cols[i % 2]:
            st.markdown(f"""
<div class="card" style="padding:12px">
  <div style="font-size:0.75rem;font-weight:800;color:var(--text)">{ms['merc']}</div>
  <div style="font-size:0.65rem;color:var(--text3);margin:2px 0">{ms['g']}G · {ms['p']}P · {ms['wr']:.0f}% WR</div>
  <div style="font-family:'Barlow Condensed',sans-serif;font-size:1.2rem;font-weight:900;color:{roi_c}">
    ROI {'+' if ms['roi']>=0 else ''}{ms['roi']:.1f}%
  </div>
  <div style="font-size:0.65rem;color:{roi_c}">{neto_str}</div>
</div>
""", unsafe_allow_html=True)

    # ── Stats por rango de momio
    st.markdown('<div class="sec-head">Win% por rango de momio</div>', unsafe_allow_html=True)
    bins = [(1.01,1.50,"1.01–1.50"),(1.51,2.00,"1.51–2.00"),
            (2.01,2.50,"2.01–2.50"),(2.51,3.50,"2.51–3.50"),(3.51,99,"3.51+")]
    for lo,hi,lbl in bins:
        grp = resolved[(resolved["momio"]>=lo)&(resolved["momio"]<hi)]
        if grp.empty:
            continue
        g = (grp["resultado"]=="ganado").sum()
        t = len(grp)
        wr_b = g/t*100 if t else 0
        roi_b = grp["ganancia_neta"].sum()/grp["apuesta"].sum()*100 if grp["apuesta"].sum() else 0
        bar_c = "#22C55E" if wr_b>=55 else "#F59E0B" if wr_b>=45 else "#EF4444"
        roi_c = "#22C55E" if roi_b>=0 else "#EF4444"
        st.markdown(f"""
<div style="display:flex;align-items:center;gap:10px;margin-bottom:5px">
  <div style="width:70px;font-size:0.65rem;color:var(--text3)">{lbl}</div>
  <div style="width:50px;font-size:0.65rem;color:var(--text3)">{g}/{t}</div>
  <div style="flex:1;background:rgba(255,255,255,0.06);border-radius:99px;height:6px;overflow:hidden">
    <div style="width:{wr_b:.0f}%;height:100%;border-radius:99px;background:{bar_c}"></div>
  </div>
  <div style="width:42px;font-size:0.7rem;font-weight:700;color:{bar_c}">{wr_b:.0f}%</div>
  <div style="width:60px;font-size:0.7rem;font-weight:700;color:{roi_c};text-align:right">
    {'+' if roi_b>=0 else ''}{roi_b:.1f}%
  </div>
</div>
""", unsafe_allow_html=True)


# ─────────────────────────────────────────────────────────────
#  TAB 4 — CHALLENGE DIARIO
# ─────────────────────────────────────────────────────────────
def tab_challenge(apodo: str, df: pd.DataFrame, bank: float):
    st.markdown('<div class="sec-head">Challenge del día</div>', unsafe_allow_html=True)
    today = str(date.today())

    # Load all users for leaderboard
    all_users = load_users()
    all_users.sort(key=lambda u: float(u.get("bankroll",0)), reverse=True)

    st.markdown(f"""
<div class="challenge-card">
  <div style="font-family:'Barlow Condensed',sans-serif;font-size:1.4rem;font-weight:900;color:#9B6DFF">
    ⚔️ PICK DEL DÍA
  </div>
  <div style="font-size:0.72rem;color:#A0A0AB;margin-top:6px">
    Registra tu pick del día y compite contra los demás apostadores.
    Los picks se revelan cuando todos hayan apostado o cuando empiece el partido.
  </div>
  <div style="font-size:0.65rem;color:#6B7280;margin-top:6px">{today}</div>
</div>
""", unsafe_allow_html=True)

    # Today's picks from this user
    today_picks = df[df["fecha"].dt.date == date.today()] if not df.empty and pd.api.types.is_datetime64_any_dtype(df["fecha"]) else pd.DataFrame()

    if today_picks.empty:
        st.info("No tienes ningún pick registrado hoy. Ve a **Registrar** para agregar uno.")
    else:
        st.markdown('<div class="sec-head">Tus picks de hoy</div>', unsafe_allow_html=True)
        for _, row in today_picks.iterrows():
            res = row.get("resultado","pendiente")
            res_c = {"ganado":"#22C55E","perdido":"#EF4444","nulo":"#6B7280","pendiente":"#F59E0B"}
            st.markdown(f"""
<div class="pick-card">
  <div style="flex:1">
    <div style="font-size:0.82rem;font-weight:700">{row.get('partido','')}</div>
    <div style="font-size:0.65rem;color:var(--text3)">{row.get('pick','')} · Momio {row.get('momio','')}</div>
  </div>
  <div style="font-size:0.7rem;font-weight:800;color:{res_c.get(res,'#888')}">{res.upper()}</div>
</div>
""", unsafe_allow_html=True)

    # ── Leaderboard
    st.markdown('<div class="sec-head">🏆 Leaderboard</div>', unsafe_allow_html=True)
    if not all_users:
        st.info("Sin datos de otros usuarios aún.")
    else:
        medals = ["🥇","🥈","🥉"]
        for i, u in enumerate(all_users[:10]):
            u_apodo  = u.get("apodo","?")
            u_bank   = float(u.get("bankroll", START_BANK))
            u_wins   = int(u.get("picks_ganados", 0))
            u_losses = int(u.get("picks_perdidos", 0))
            u_total  = u_wins + u_losses
            u_wr     = f"{u_wins/u_total*100:.0f}%" if u_total else "—"
            is_me    = u_apodo.lower() == apodo.lower()
            medal    = medals[i] if i < 3 else f"#{i+1}"
            rango    = get_rango(u_bank)
            st.markdown(f"""
<div class="lb-row {'me' if is_me else ''}">
  <div style="font-size:1rem;width:28px;text-align:center">{medal}</div>
  <div class="lb-avatar">{u_apodo[0].upper()}</div>
  <div style="flex:1">
    <div style="font-size:0.8rem;font-weight:800;color:{'var(--gold)' if is_me else 'var(--text)'}">
      {u_apodo.upper()} {'← Tú' if is_me else ''}
    </div>
    <div style="font-size:0.6rem;color:var(--text3)">{rango['icon']} {rango['nombre']} · {u_wr} WR</div>
  </div>
  <div style="text-align:right">
    <div style="font-family:'Barlow Condensed',sans-serif;font-size:1rem;font-weight:900;color:var(--gold)">
      ${u_bank:,.0f}
    </div>
  </div>
</div>
""", unsafe_allow_html=True)

    # Update user record in sheet
    resolved_u = df[df["resultado"].isin(["ganado","perdido"])].copy() if not df.empty else pd.DataFrame()
    w = (resolved_u["resultado"]=="ganado").sum() if not resolved_u.empty else 0
    l = (resolved_u["resultado"]=="perdido").sum() if not resolved_u.empty else 0
    upsert_user(apodo, bank, int(w), int(l))


# ─────────────────────────────────────────────────────────────
#  TAB 5 — SIMULADOR DE DESTINO
# ─────────────────────────────────────────────────────────────
def tab_simulador(df: pd.DataFrame, bank: float):
    st.markdown('<div class="sec-head">Simulador de destino</div>', unsafe_allow_html=True)

    resolved = df[df["resultado"].isin(["ganado","perdido"])].copy() if not df.empty else pd.DataFrame()

    # Derive real averages or defaults
    avg_momio   = float(resolved["momio"].mean()) if not resolved.empty else 1.85
    avg_apuesta_pct = float((resolved["apuesta"] / resolved["bankroll_post"].replace(0, START_BANK)).mean()) * 100 if not resolved.empty else 2.0
    real_wr     = float((resolved["resultado"]=="ganado").sum() / len(resolved) * 100) if not resolved.empty else 55.0

    c1, c2, c3 = st.columns(3)
    with c1:
        n_picks = st.slider("Picks siguientes", 1, 200, 30, 1)
    with c2:
        win_rate = st.slider("Win rate proyectado (%)", 30, 80, int(real_wr), 1)
    with c3:
        bet_pct = st.slider("% bankroll por pick", 0.5, 10.0, round(avg_apuesta_pct, 1), 0.5)

    momio_sim = st.slider("Momio promedio", 1.10, 5.00, round(avg_momio, 2), 0.05)

    # Monte Carlo — 200 runs
    runs    = 200
    results = []
    for _ in range(runs):
        b = bank
        traj = [b]
        for _ in range(n_picks):
            bet = b * (bet_pct / 100)
            if random.random() < win_rate / 100:
                b += bet * (momio_sim - 1)
            else:
                b -= bet
            b = max(b, 0)
            traj.append(b)
        results.append(traj)

    # Summary
    finals  = [r[-1] for r in results]
    p10     = sorted(finals)[int(runs * 0.1)]
    p50     = sorted(finals)[int(runs * 0.5)]
    p90     = sorted(finals)[int(runs * 0.9)]

    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box">
    <div class="kpi-val" style="color:var(--red)">${p10:,.0f}</div>
    <div class="kpi-lbl">Pesimista (P10)</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(255,214,10,0.3)">
    <div class="kpi-val" style="color:var(--gold)">${p50:,.0f}</div>
    <div class="kpi-lbl">Probable (P50)</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(34,197,94,0.3)">
    <div class="kpi-val" style="color:var(--green)">${p90:,.0f}</div>
    <div class="kpi-lbl">Optimista (P90)</div>
  </div>
  <div class="kpi-box">
    <div class="kpi-val">{sum(1 for f in finals if f >= RETO_GOAL)}/{runs}</div>
    <div class="kpi-lbl">Llegan a $13M</div>
  </div>
</div>
""", unsafe_allow_html=True)

    # Chart — median + p10/p90 band + goal line
    median_traj = [sorted([r[i] for r in results])[runs//2] for i in range(n_picks+1)]
    p10_traj    = [sorted([r[i] for r in results])[int(runs*0.1)] for i in range(n_picks+1)]
    p90_traj    = [sorted([r[i] for r in results])[int(runs*0.9)] for i in range(n_picks+1)]
    x_axis      = list(range(n_picks+1))

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=x_axis+x_axis[::-1], y=p90_traj+p10_traj[::-1],
        fill="toself", fillcolor="rgba(255,107,0,0.08)",
        line=dict(color="rgba(0,0,0,0)"), name="Rango P10–P90",
    ))
    fig.add_trace(go.Scatter(
        x=x_axis, y=median_traj, mode="lines",
        line=dict(color="#FF6B00", width=2), name="Mediana",
    ))
    fig.add_hline(y=RETO_GOAL, line_dash="dot", line_color="#9B6DFF",
                  annotation_text="META $13M", annotation_font_color="#9B6DFF")
    fig.add_hline(y=bank, line_dash="dash", line_color="#FFD60A", line_width=1,
                  annotation_text="Actual", annotation_font_color="#FFD60A")
    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color="#A0A0AB"),
        margin=dict(l=10,r=10,t=10,b=10), height=260,
        legend=dict(orientation="h", y=-0.15),
        xaxis=dict(title="Picks", showgrid=False, zeroline=False),
        yaxis=dict(title="Bankroll ($)", showgrid=True, gridcolor="rgba(255,255,255,0.05)"),
    )
    st.plotly_chart(fig, use_container_width=True)

    # Days to goal estimate
    if p50 > bank:
        growth_per_pick = (p50 / bank) ** (1 / n_picks) - 1
        if growth_per_pick > 0:
            picks_to_goal = math.log(RETO_GOAL / bank) / math.log(1 + growth_per_pick)
            st.markdown(
                f'<div style="text-align:center;font-size:0.75rem;color:#A0A0AB;margin-top:8px">'
                f'Con este ritmo necesitarías aproximadamente '
                f'<strong style="color:var(--gold)">{picks_to_goal:.0f} picks</strong> para llegar a $13M.</div>',
                unsafe_allow_html=True
            )


# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────
def main():
    inject_css()

    # FX (confetti / wasted) — show on rerun after resolving
    fx = st.session_state.pop("fx", None)
    if fx == "confetti":
        st.markdown(confetti_html(), unsafe_allow_html=True)
    elif fx == "wasted":
        st.markdown(wasted_html(), unsafe_allow_html=True)

    # Login gate
    if "apodo" not in st.session_state:
        render_login()
        return

    apodo = st.session_state["apodo"]

    # Load data
    with st.spinner("Cargando datos..."):
        df   = load_picks(apodo)
        bank = get_bankroll(df)

    # Header
    render_header(apodo, bank)

    # Tabs
    tab1, tab2, tab3, tab4, tab5 = st.tabs([
        "📝 Registrar", "📋 Historial", "📊 Analytics", "⚔️ Challenge", "🔮 Simulador"
    ])

    with tab1:
        tab_registrar(apodo, df, bank)
    with tab2:
        tab_historial(df)
    with tab3:
        tab_analytics(df, bank)
    with tab4:
        tab_challenge(apodo, df, bank)
    with tab5:
        tab_simulador(df, bank)


if __name__ == "__main__":
    main()
