"""
╔══════════════════════════════════════════════════════════════════╗
║          RETO 13M — v2.0  (ESPN + Auto-Calificar)               ║
║  Streamlit · Google Sheets · ESPN API · Multi-usuario           ║
╚══════════════════════════════════════════════════════════════════╝

requirements.txt:
    streamlit>=1.32
    gspread>=5.12
    oauth2client>=4.1.3
    pandas>=2.0
    plotly>=5.20
    requests>=2.31

secrets.toml:
    [gsheets]
    type            = "service_account"
    project_id      = "..."
    private_key_id  = "..."
    private_key     = "..."
    client_email    = "..."
    token_uri       = "https://oauth2.googleapis.com/token"
    spreadsheet_id  = "TU_SPREADSHEET_ID"
"""

import streamlit as st
import gspread
import pandas as pd
import plotly.graph_objects as go
import requests
import math, random, json, time
import pytz
from oauth2client.service_account import ServiceAccountCredentials
from datetime import datetime, date, timedelta, timezone

import time as _time_module

# Rate limiter para Google Sheets (evitar error 429)
_last_gs_read = {}

def _rate_limit_gs(key: str, min_seconds: float = 0.5):
    """Esperar para no exceder rate limit de Google Sheets"""
    now = _time_module.time()
    last = _last_gs_read.get(key, 0)
    elapsed = now - last
    if elapsed < min_seconds:
        _time_module.sleep(min_seconds - elapsed)
    _last_gs_read[key] = _time_module.time()



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
#  CONSTANTS
# ─────────────────────────────────────────────────────────────
RETO_GOAL  = 13_000_000
START_BANK = 1_500.0
TAB_USERS  = "usuarios"

RANGOS = [
    {"min": 0,          "max": 50_000,     "icon": "🥉", "nombre": "Rookie",    "color": "#CD7F32"},
    {"min": 50_000,     "max": 200_000,    "icon": "🥈", "nombre": "Apostador", "color": "#C0C0C0"},
    {"min": 200_000,    "max": 500_000,    "icon": "🥇", "nombre": "Pro",       "color": "#FFD700"},
    {"min": 500_000,    "max": 1_500_000,  "icon": "💎", "nombre": "Élite",     "color": "#00CFFF"},
    {"min": 1_500_000,  "max": 5_000_000,  "icon": "👑", "nombre": "Leyenda",   "color": "#9B6DFF"},
    {"min": 5_000_000,  "max": 13_000_000, "icon": "🔥", "nombre": "Inmortal",  "color": "#FF6B00"},
    {"min": 13_000_000, "max": float("inf"),"icon":"🏆", "nombre": "GRADUADO",  "color": "#FFD60A"},
]

# ESPN sport slugs → league display name → ESPN league slug
ESPN_LEAGUES_GROUPED = {
    "🌐 Todos los partidos de hoy": {
        "📅 Cargar todo":            ("all", "__all_today__"),
    },
    "⚽ Fútbol — Clubes": {
        "Premier League":        ("soccer", "eng.1"),
        "La Liga":               ("soccer", "esp.1"),
        "Serie A":               ("soccer", "ita.1"),
        "Bundesliga":            ("soccer", "ger.1"),
        "Ligue 1":               ("soccer", "fra.1"),
        "Liga MX":               ("soccer", "mex.1"),
        "MLS":                   ("soccer", "usa.1"),
        "Champions League":      ("soccer", "uefa.champions"),
        "Europa League":         ("soccer", "uefa.europa"),
        "Conference League":     ("soccer", "uefa.europa.conf"),
        "Copa Libertadores":     ("soccer", "conmebol.libertadores"),
        "Copa Sudamericana":     ("soccer", "conmebol.sudamericana"),
        "CONCACAF Champions":    ("soccer", "concacaf.champions"),
        "Brasileirão":           ("soccer", "bra.1"),
        "Eredivisie":            ("soccer", "ned.1"),
        "Liga Portugal":         ("soccer", "por.1"),
        "Superliga Argentina":   ("soccer", "arg.1"),
        "Liga MX Femenil":       ("soccer", "mex.w.1"),
    },
    "🌍 Fútbol — Selecciones": {
        "🔍 Buscar por equipo":         ("soccer", "__team_search__"),
        "Playoffs UEFA WC2026":          ("soccer", "fifa.worldq.uefa"),
        "Eliminatorias UEFA":            ("soccer", "fifa.worldq.6"),
        "Playoffs Eliminat. UEFA (alt)": ("soccer", "fifa.worldq.europe"),
        "Eliminatorias CONMEBOL":        ("soccer", "fifa.worldq.2"),
        "Eliminatorias CONCACAF":        ("soccer", "fifa.worldq.5"),
        "Eliminatorias AFC":             ("soccer", "fifa.worldq.3"),
        "Nations League UEFA":           ("soccer", "uefa.nations"),
        "Copa América":                  ("soccer", "conmebol.america"),
        "Eurocopa":                      ("soccer", "uefa.euro"),
        "Gold Cup":                      ("soccer", "concacaf.gold"),
        "Amistosos Internac.":           ("soccer", "fifa.friendly"),
        "Mundial de Clubes":             ("soccer", "fifa.cwc"),
        "Apostar":                       ("soccer", "fifa.worldq"),
    },
}

# Flat lookup by liga name
ESPN_LEAGUES = {
    liga: info
    for group in ESPN_LEAGUES_GROUPED.values()
    for liga, info in group.items()
}


MERCADOS = [
    "ML (Ganador)", "Over/Under Goles", "BTTS (Ambos Anotan)",
    "Hándicap Asiático", "Hándicap Europeo", "Córners",
    "Resultado 1X2", "Doble Oportunidad",
    "Player Prop", "Parlay", "Otro"
]

PICKS_HEADERS = [
    "fecha", "deporte", "liga", "partido", "event_id",
    "mercado", "pick_desc", "momio",
    "apuesta", "resultado", "ganancia_neta", "bankroll_post", "notas"
]

# ─────────────────────────────────────────────────────────────
#  CSS
# ─────────────────────────────────────────────────────────────
def inject_css():
    st.markdown("""
<style>
@import url('https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Rajdhani:wght@400;500;600;700&family=JetBrains+Mono:wght@400;700&display=swap');

:root {
  --bg:    #06060A;  --bg2: #0D0D14;  --bg3: #12121C;
  --bg4:   #1A1A28;  --bg5: #22223A;
  --neon:  #F0FF00;  --neon2:#00FFD1; --fire:#FF3D00;
  --gold:  #FFB800;  --green:#00FF88; --red: #FF2D55;
  --purple:#BF5FFF;  --blue: #00B4FF;
  --text:  #EEEEF5;  --text2:#8888AA; --text3:#44445A;
  --card-r:16px;
  --glow-y: 0 0 20px rgba(240,255,0,.35),  0 0 60px rgba(240,255,0,.12);
  --glow-c: 0 0 20px rgba(0,255,209,.35),  0 0 60px rgba(0,255,209,.12);
  --glow-f: 0 0 20px rgba(255,61,0,.4),    0 0 60px rgba(255,61,0,.15);
}

html,body,.stApp,[data-testid="stAppViewContainer"],[data-testid="stMain"],.main {
  background:var(--bg) !important; color:var(--text) !important;
}
* { box-sizing:border-box; }

body::before {
  content:''; position:fixed; inset:0; z-index:0; pointer-events:none;
  background-image:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,.07) 2px,rgba(0,0,0,.07) 4px);
  animation:scanMove 10s linear infinite; opacity:.35;
}
@keyframes scanMove { from{background-position:0 0} to{background-position:0 100px} }

body::after {
  content:''; position:fixed; inset:0; z-index:0; pointer-events:none;
  background:
    radial-gradient(ellipse 700px 400px at 85% 5%,  rgba(240,255,0,.035) 0%,transparent 70%),
    radial-gradient(ellipse 500px 350px at 5%  85%,  rgba(0,255,209,.035) 0%,transparent 70%),
    radial-gradient(ellipse 400px 300px at 50% 50%,  rgba(191,95,255,.025) 0%,transparent 70%);
}

*{font-family:'Rajdhani',sans-serif;}
.bbn{font-family:'Bebas Neue',sans-serif!important;}
.mono{font-family:'JetBrains Mono',monospace!important;}

#MainMenu,footer,[data-testid="stToolbar"],
[data-testid="stDecoration"],[data-testid="stStatusWidget"]{display:none!important;}
header[data-testid="stHeader"]{display:none!important;}
.block-container{padding:0 20px 80px!important;max-width:980px!important;margin:0 auto;position:relative;z-index:1;}

/* ── CARDS ── */
.card{
  background:linear-gradient(145deg,rgba(255,255,255,.04) 0%,rgba(255,255,255,.01) 100%);
  border:1px solid rgba(255,255,255,.07); border-radius:var(--card-r);
  padding:20px; margin-bottom:14px; backdrop-filter:blur(12px);
  box-shadow:0 1px 0 rgba(255,255,255,.06) inset,0 8px 32px rgba(0,0,0,.5);
  transform:perspective(800px) rotateX(.4deg); transition:transform .3s,box-shadow .3s;
}
.card:hover{transform:perspective(800px) rotateX(0deg) translateY(-2px);
  box-shadow:0 1px 0 rgba(255,255,255,.09) inset,0 16px 48px rgba(0,0,0,.6);}
.card-gold{border-color:rgba(255,184,0,.3);
  background:linear-gradient(145deg,rgba(255,184,0,.07) 0%,rgba(255,61,0,.04) 100%);
  box-shadow:0 0 0 1px rgba(255,184,0,.08) inset,0 8px 40px rgba(255,184,0,.09),0 8px 32px rgba(0,0,0,.5);}

/* ── HERO ── */
.hero-bank{font-family:'Bebas Neue',sans-serif!important;font-size:4rem;color:var(--gold);
  line-height:1;letter-spacing:2px;animation:pulseGold 3s ease-in-out infinite;}
@keyframes pulseGold{
  0%,100%{text-shadow:0 0 20px rgba(255,184,0,.4),0 0 60px rgba(255,184,0,.15);}
  50%    {text-shadow:0 0 40px rgba(255,184,0,.7),0 0 100px rgba(255,184,0,.3);}
}
.hero-label{font-family:'JetBrains Mono',monospace;font-size:.55rem;font-weight:700;
  letter-spacing:4px;text-transform:uppercase;color:var(--text3);margin-bottom:6px;}
.hero-meta{font-size:.72rem;color:var(--text2);margin-top:4px;font-family:'JetBrains Mono',monospace;}

/* ── PROGRESS ── */
.prog-wrap{background:rgba(255,255,255,.04);border-radius:99px;height:12px;
  overflow:hidden;margin:12px 0 4px;border:1px solid rgba(255,255,255,.05);
  box-shadow:inset 0 2px 4px rgba(0,0,0,.4);}
.prog-fill{height:100%;border-radius:99px;
  background:linear-gradient(90deg,#FF3D00 0%,#FFB800 50%,#F0FF00 100%);
  box-shadow:0 0 12px rgba(240,255,0,.6),0 0 24px rgba(255,184,0,.3);
  transition:width .8s cubic-bezier(.4,0,.2,1);position:relative;}
.prog-fill::after{content:'';position:absolute;right:0;top:0;bottom:0;width:20px;
  background:linear-gradient(90deg,transparent,rgba(255,255,255,.4));
  animation:shimmerProg 2.5s ease-in-out infinite;}
@keyframes shimmerProg{0%,100%{opacity:0}50%{opacity:1}}

/* ── MILESTONES ── */
.ms-row{display:flex;justify-content:space-between;margin-top:8px;}
.ms-dot{display:flex;flex-direction:column;align-items:center;gap:3px;}
.ms-circle{width:12px;height:12px;border-radius:50%;border:2px solid rgba(255,255,255,.12);transition:all .3s;}
.ms-circle.reached{background:var(--gold);border-color:var(--gold);
  box-shadow:0 0 8px rgba(255,184,0,.8),0 0 16px rgba(255,184,0,.4);}
.ms-label{font-family:'JetBrains Mono',monospace;font-size:.42rem;color:var(--text3);}

/* ── KPI GRID ── */
.kpi-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:16px;}
.kpi-box{
  background:linear-gradient(160deg,rgba(255,255,255,.05),rgba(255,255,255,.01));
  border:1px solid rgba(255,255,255,.07);border-radius:12px;
  padding:14px 10px;text-align:center;
  box-shadow:0 1px 0 rgba(255,255,255,.05) inset,0 4px 20px rgba(0,0,0,.4);
  transform:perspective(400px) rotateX(.8deg);transition:transform .2s,box-shadow .2s;
}
.kpi-box:hover{transform:perspective(400px) rotateX(0deg) translateY(-3px);
  box-shadow:0 8px 30px rgba(0,0,0,.5);}
.kpi-val{font-family:'Bebas Neue',sans-serif!important;font-size:1.8rem;color:var(--text);line-height:1;}
.kpi-lbl{font-family:'JetBrains Mono',monospace;font-size:.48rem;color:var(--text3);
  letter-spacing:2px;text-transform:uppercase;margin-top:4px;}

/* ── SECTION HEADING ── */
.sec-head{font-family:'Bebas Neue',sans-serif!important;font-size:1.1rem;letter-spacing:4px;
  text-transform:uppercase;color:var(--text2);display:flex;align-items:center;gap:10px;
  margin:26px 0 12px;}
.sec-head::before{content:'';width:4px;height:18px;
  background:linear-gradient(180deg,var(--neon),var(--neon2));border-radius:2px;flex-shrink:0;
  box-shadow:0 0 8px rgba(240,255,0,.6);}
.sec-head::after{content:'';flex:1;height:1px;
  background:linear-gradient(90deg,rgba(255,255,255,.08),transparent);}

/* ── PICK CARDS ── */
.pick-card{
  background:linear-gradient(135deg,rgba(255,255,255,.04),rgba(255,255,255,.01));
  border:1px solid rgba(255,255,255,.07);border-radius:12px;
  padding:14px 16px;display:flex;align-items:center;gap:14px;margin-bottom:8px;
  box-shadow:0 2px 12px rgba(0,0,0,.35),0 1px 0 rgba(255,255,255,.05) inset;
  transition:all .2s;
}
.pick-card:hover{border-color:rgba(255,255,255,.14);transform:translateX(3px);}
.pick-badge{width:40px;height:40px;border-radius:10px;
  display:flex;align-items:center;justify-content:center;font-size:1.1rem;flex-shrink:0;}
.pick-badge.g{background:rgba(0,255,136,.12);border:1px solid rgba(0,255,136,.5);
  box-shadow:0 0 12px rgba(0,255,136,.2);}
.pick-badge.p{background:rgba(255,45,85,.12);border:1px solid rgba(255,45,85,.5);
  box-shadow:0 0 12px rgba(255,45,85,.2);}
.pick-badge.n{background:rgba(136,136,170,.1);border:1px solid rgba(136,136,170,.3);}

/* ── TABS ── */
div[data-testid="stTabs"] [role="tablist"]{
  background:transparent!important;border:none!important;
  padding:0!important;gap:8px!important;display:flex!important;flex-wrap:wrap!important;}
div[data-testid="stTabs"] button[role="tab"]{
  background:linear-gradient(145deg,rgba(255,255,255,.04),rgba(255,255,255,.01))!important;
  border:1px solid rgba(255,255,255,.1)!important;border-radius:10px!important;
  color:var(--text2)!important;font-family:'Bebas Neue',sans-serif!important;
  font-size:1rem!important;letter-spacing:2px!important;padding:10px 20px!important;
  transition:all .2s!important;
  box-shadow:0 2px 8px rgba(0,0,0,.3),0 1px 0 rgba(255,255,255,.04) inset!important;
  flex:1!important;white-space:nowrap!important;}
div[data-testid="stTabs"] button[role="tab"]:hover{
  border-color:rgba(240,255,0,.35)!important;color:var(--neon)!important;
  box-shadow:0 0 14px rgba(240,255,0,.15),0 4px 14px rgba(0,0,0,.4)!important;
  transform:translateY(-2px)!important;}
div[data-testid="stTabs"] button[role="tab"][aria-selected="true"]{
  background:linear-gradient(145deg,rgba(240,255,0,.12),rgba(255,184,0,.08))!important;
  border-color:rgba(240,255,0,.55)!important;color:var(--neon)!important;
  box-shadow:0 0 18px rgba(240,255,0,.28),0 0 36px rgba(240,255,0,.1),
    0 4px 16px rgba(0,0,0,.4),0 1px 0 rgba(240,255,0,.2) inset!important;
  transform:translateY(-2px)!important;}
div[data-testid="stTabs"] [data-baseweb="tab-highlight"],
div[data-testid="stTabs"] [data-baseweb="tab-border"]{display:none!important;}

/* ── BUTTONS ── */
div.stButton>button{
  background:linear-gradient(145deg,rgba(255,255,255,.06),rgba(255,255,255,.02))!important;
  border:1px solid rgba(255,255,255,.15)!important;
  color:#EEEEF5 !important;
  -webkit-text-fill-color:#EEEEF5 !important;
  border-radius:10px!important;font-family:'Rajdhani',sans-serif!important;
  font-weight:700!important;font-size:.9rem!important;letter-spacing:1px!important;
  transition:all .2s!important;width:100%!important;
  box-shadow:0 2px 10px rgba(0,0,0,.3),0 1px 0 rgba(255,255,255,.05) inset!important;}
div.stButton>button:hover{
  transform:translateY(-2px)!important;border-color:rgba(240,255,0,.4)!important;
  box-shadow:0 0 16px rgba(240,255,0,.15),0 6px 20px rgba(0,0,0,.4)!important;
  color:var(--neon)!important;}
div.stButton>button[kind="primary"]{
  background:linear-gradient(135deg,#FF3D00,#FF8C00,#FFB800)!important;
  border-color:rgba(255,184,0,.6)!important;color:#000!important;font-weight:800!important;
  box-shadow:var(--glow-f),0 4px 16px rgba(0,0,0,.4)!important;}
div.stButton>button[kind="primary"]:hover{
  box-shadow:0 0 30px rgba(255,184,0,.5),0 0 60px rgba(255,61,0,.3),0 8px 24px rgba(0,0,0,.5)!important;
  transform:translateY(-3px) scale(1.01)!important;color:#000!important;}

/* ── INPUTS — máxima especificidad para sobreescribir Streamlit ── */
div[data-testid="stTextInput"] input,
div[data-testid="stTextInput"] input:focus,
div[data-testid="stTextInput"] input:active,
div[data-testid="stTextInput"] input:hover,
div[data-testid="stTextInput"] input:not([type]),
div[data-testid="stNumberInput"] input,
div[data-testid="stNumberInput"] input:focus,
div[data-baseweb="input"] input,
div[data-baseweb="base-input"] input,
.stTextInput input, .stNumberInput input {
  background-color: #1A1A28 !important;
  background: #1A1A28 !important;
  border: 1px solid rgba(255,255,255,.18) !important;
  color: #EEEEF5 !important;
  -webkit-text-fill-color: #EEEEF5 !important;
  border-radius: 10px !important;
  font-family: 'Rajdhani', sans-serif !important;
  font-size: 1rem !important;
  caret-color: #F0FF00 !important;
}
div[data-baseweb="input"],
div[data-baseweb="base-input"] {
  background-color: #1A1A28 !important;
  background: #1A1A28 !important;
}
/* placeholder */
div[data-testid="stTextInput"] input::placeholder,
div[data-baseweb="input"] input::placeholder,
.stTextInput input::placeholder {
  color: #44445A !important;
  -webkit-text-fill-color: #44445A !important;
  opacity: 1 !important;
}
/* selectbox */
div[data-testid="stSelectbox"] > div > div,
div[data-baseweb="select"] > div {
  background-color: #1A1A28 !important;
  background: #1A1A28 !important;
  border: 1px solid rgba(255,255,255,.15) !important;
  color: #EEEEF5 !important;
  border-radius: 10px !important;
}
div[data-baseweb="select"] span { color: #EEEEF5 !important; }
/* textarea */
div[data-testid="stTextArea"] textarea,
div[data-baseweb="textarea"] textarea {
  background-color: #1A1A28 !important;
  background: #1A1A28 !important;
  border: 1px solid rgba(255,255,255,.12) !important;
  color: #EEEEF5 !important;
  -webkit-text-fill-color: #EEEEF5 !important;
  border-radius: 10px !important;
  caret-color: #F0FF00 !important;
}
div[data-testid="stTextArea"] textarea::placeholder { color:#44445A!important; -webkit-text-fill-color:#44445A!important; }
/* date input */
div[data-testid="stDateInput"] input {
  background-color: #1A1A28 !important;
  color: #EEEEF5 !important;
  -webkit-text-fill-color: #EEEEF5 !important;
}
/* labels */
label, div[data-testid="stWidgetLabel"] p,
div[data-testid="stWidgetLabel"] {
  color: #8888AA !important;
  font-family: 'Rajdhani', sans-serif !important;
  font-weight: 600 !important;
}
/* focus glow */
div[data-testid="stTextInput"] input:focus,
div[data-testid="stNumberInput"] input:focus {
  border-color: rgba(240,255,0,.5) !important;
  box-shadow: 0 0 14px rgba(240,255,0,.12) !important;
  outline: none !important;
}

/* ── EXPANDER ── */
div[data-testid="stExpander"] details{
  background:rgba(255,255,255,.03)!important;
  border:1px solid rgba(255,255,255,.08)!important;border-radius:12px!important;}
div[data-testid="stExpander"] summary{color:var(--text)!important;font-family:'Rajdhani',sans-serif!important;font-weight:600!important;}

/* ── RADIO BUTTONS ── */
div[data-testid="stRadio"] label,
div[data-testid="stRadio"] label p,
div[data-testid="stRadio"] span {
  color: #EEEEF5 !important;
  font-family: 'Rajdhani', sans-serif !important;
  font-weight: 600 !important;
  font-size: 0.95rem !important;
}
div[data-testid="stRadio"] label:has(input:checked) span,
div[data-testid="stRadio"] label:has(input:checked) p {
  color: #F0FF00 !important;
}
div[data-testid="stRadio"] [data-testid="stWidgetLabel"] {
  display: none !important;
}
::-webkit-scrollbar-track{background:transparent;}
::-webkit-scrollbar-thumb{background:linear-gradient(180deg,var(--neon),var(--neon2));border-radius:99px;}

/* ── RANG BADGE ── */
.rang-badge{display:inline-flex;align-items:center;gap:6px;padding:5px 14px;border-radius:8px;
  font-family:'Bebas Neue',sans-serif;font-size:1rem;letter-spacing:2px;}

/* ── RACHA ── */
.racha-row{display:flex;gap:5px;flex-wrap:wrap;margin:10px 0;}
.racha-dot{width:26px;height:26px;border-radius:8px;display:flex;align-items:center;justify-content:center;
  font-family:'JetBrains Mono',monospace;font-size:.65rem;font-weight:700;}
.racha-dot.g{background:rgba(0,255,136,.15);border:1px solid rgba(0,255,136,.5);color:var(--green);box-shadow:0 0 8px rgba(0,255,136,.2);}
.racha-dot.p{background:rgba(255,45,85,.15);border:1px solid rgba(255,45,85,.5);color:var(--red);box-shadow:0 0 8px rgba(255,45,85,.2);}
.racha-dot.n{background:rgba(136,136,170,.1);border:1px solid rgba(136,136,170,.25);color:var(--text3);}

/* ── LEADERBOARD ── */
.lb-row{display:flex;align-items:center;gap:12px;padding:12px 16px;border-radius:12px;
  background:linear-gradient(135deg,rgba(255,255,255,.04),rgba(255,255,255,.01));
  border:1px solid rgba(255,255,255,.07);margin-bottom:7px;transition:all .2s;
  box-shadow:0 2px 12px rgba(0,0,0,.3);}
.lb-row:hover{transform:translateX(4px);border-color:rgba(255,255,255,.12);}
.lb-row.me{border-color:rgba(240,255,0,.35);
  background:linear-gradient(135deg,rgba(240,255,0,.06),rgba(255,184,0,.03));
  box-shadow:0 0 16px rgba(240,255,0,.1),0 4px 16px rgba(0,0,0,.4);}
.lb-avatar{width:36px;height:36px;border-radius:10px;
  background:linear-gradient(135deg,#BF5FFF,#FF3D00);
  display:flex;align-items:center;justify-content:center;
  font-family:'Bebas Neue',sans-serif;font-size:1rem;color:#fff;flex-shrink:0;
  box-shadow:0 0 12px rgba(191,95,255,.3);}

/* ── TILT ALERT ── */
.tilt-alert{background:rgba(255,45,85,.08);border:1px solid rgba(255,45,85,.4);
  border-left:3px solid var(--red);border-radius:10px;padding:14px 18px;margin-bottom:16px;
  font-size:.85rem;color:#FF8FA3;box-shadow:0 0 20px rgba(255,45,85,.1);}

/* ── LEAGUE ROW ── */
.league-row{display:flex;align-items:center;gap:10px;padding:10px 14px;border-radius:10px;
  background:linear-gradient(135deg,rgba(255,255,255,.04),rgba(255,255,255,.01));
  border:1px solid rgba(255,255,255,.06);margin-bottom:6px;transition:all .15s;}
.league-row:hover{border-color:rgba(255,255,255,.12);transform:translateX(3px);}
.league-bar-wrap{flex:1;background:rgba(255,255,255,.05);border-radius:99px;height:6px;overflow:hidden;}
.league-bar-fill{height:100%;border-radius:99px;}

/* ── GAME CARD (search results) ── */
.game-card{
  background:linear-gradient(135deg,rgba(255,255,255,.04),rgba(255,255,255,.01));
  border:1px solid rgba(255,255,255,.08);border-radius:12px;
  padding:12px 16px;margin-bottom:6px;cursor:pointer;transition:all .15s;
}
.game-card:hover{border-color:rgba(240,255,0,.35);box-shadow:0 0 14px rgba(240,255,0,.1);}
.game-card.selected{border-color:rgba(240,255,0,.6);
  background:linear-gradient(135deg,rgba(240,255,0,.08),rgba(255,184,0,.04));
  box-shadow:0 0 20px rgba(240,255,0,.15);}

/* ── STATUS BADGE ── */
.status-live{color:#FF3D00;font-family:'JetBrains Mono',monospace;font-size:.6rem;
  animation:blinkLive 1.2s ease-in-out infinite;}
@keyframes blinkLive{0%,100%{opacity:1}50%{opacity:.3}}
.status-final{color:var(--text3);font-family:'JetBrains Mono',monospace;font-size:.6rem;}
.status-pre{color:var(--neon2);font-family:'JetBrains Mono',monospace;font-size:.6rem;}

/* ── CONFETTI ── */
@keyframes confettiFall{
  0%  {transform:translateY(-20px) rotate(0deg) scale(1);opacity:1;}
  100%{transform:translateY(100vh) rotate(720deg) scale(.5);opacity:0;}}
.confetti-piece{position:fixed;border-radius:3px;
  animation:confettiFall 2.8s ease-in forwards;z-index:9999;pointer-events:none;}

/* ── WASTED ── */
@keyframes wastedFade{
  0%  {opacity:0;transform:scale(3) skewX(-5deg);filter:blur(12px);color:#fff;}
  25% {opacity:1;transform:scale(1) skewX(0);filter:blur(0);color:#FF2D55;}
  70% {opacity:1;transform:scale(1);}
  100%{opacity:0;transform:scale(.95);}}
.wasted-overlay{position:fixed;inset:0;background:rgba(0,0,0,.8);
  display:flex;align-items:center;justify-content:center;z-index:9999;
  animation:wastedFade 3s ease forwards;font-family:'Bebas Neue',sans-serif;
  font-size:6rem;color:var(--red);letter-spacing:12px;pointer-events:none;
  text-shadow:0 0 30px rgba(255,45,85,.8),0 0 80px rgba(255,45,85,.4);}

/* ── AUTO-GRADE BANNER ── */
.autobanner{background:rgba(0,255,136,.07);border:1px solid rgba(0,255,136,.3);
  border-left:3px solid var(--green);border-radius:10px;padding:12px 16px;margin-bottom:12px;
  font-size:.82rem;color:#6EFFC0;}

/* ── EXPANDERS — force dark theme ── */
[data-testid="stExpander"]{
  background:var(--bg3) !important;
  border:1px solid rgba(255,255,255,.08) !important;
  border-radius:12px !important;
  margin-bottom:6px !important;
}
/* Remove the _arrow text artifact completely */
[data-testid="stExpander"] details summary::before,
[data-testid="stExpander"] summary::before,
details[data-testid] summary::before { display:none !important; content:none !important; }

[data-testid="stExpander"] summary,
details summary {
  background: var(--bg3) !important;
  border-radius:12px !important;
  padding: 12px 16px !important;
}
/* Target the actual label text element */
[data-testid="stExpander"] summary > div,
[data-testid="stExpander"] summary > span,
[data-testid="stExpander"] summary p {
  color: var(--text) !important;
  font-family: 'Rajdhani', sans-serif !important;
  font-weight: 700 !important;
  font-size: .95rem !important;
  letter-spacing: .5px !important;
}
/* Arrow icon */
[data-testid="stExpander"] summary svg {
  color: var(--neon) !important;
  fill: var(--neon) !important;
  min-width: 14px !important;
}
[data-testid="stExpander"] summary:hover > div,
[data-testid="stExpander"] summary:hover > span,
[data-testid="stExpander"] summary:hover p {
  color: var(--neon) !important;
}
[data-testid="stExpander"] > div:last-child {
  background: var(--bg2) !important;
  border-top: 1px solid rgba(255,255,255,.05) !important;
  padding: 12px 8px !important;
}
/* Nested expander (liga inside sport group) */
[data-testid="stExpander"] [data-testid="stExpander"] {
  background: var(--bg4) !important;
  border: 1px solid rgba(191,95,255,.2) !important;
  margin: 4px 0 !important;
}
[data-testid="stExpander"] [data-testid="stExpander"] summary {
  background: var(--bg4) !important;
}
[data-testid="stExpander"] [data-testid="stExpander"] summary > div,
[data-testid="stExpander"] [data-testid="stExpander"] summary > span,
[data-testid="stExpander"] [data-testid="stExpander"] summary p {
  color: #BF5FFF !important;
  font-size: .82rem !important;
}
[data-testid="stExpander"] [data-testid="stExpander"] > div:last-child {
  background: var(--bg3) !important;
}

/* ── MOBILE RESPONSIVE ── */
@media (max-width: 768px) {
  /* Bigger touch targets */
  .stButton > button {
    min-height: 44px !important;
    font-size: .78rem !important;
  }
  /* Nav tabs full width */
  [data-testid="stHorizontalBlock"] { gap: 4px !important; }
  /* KPI grid 2 columns on mobile */
  .kpi-grid { grid-template-columns: repeat(2, 1fr) !important; gap: 8px !important; }
  .kpi-val  { font-size: 1.4rem !important; }
  /* Bankroll header smaller */
  .bank-val { font-size: 2rem !important; }
  /* Pick cards stack */
  [data-testid="column"] { min-width: 0 !important; }
  /* Number inputs larger */
  input[type="number"] { font-size: 1rem !important; min-height: 44px !important; }
  /* Hide sidebar padding */
  .block-container { padding: 0.5rem 0.75rem !important; }
}
@media (max-width: 480px) {
  .kpi-grid { grid-template-columns: repeat(2, 1fr) !important; }
  .bank-val { font-size: 1.6rem !important; }
  /* Stack save form columns */
  .stNumberInput input { font-size: .9rem !important; }
}
</style>
<script>
(function(){
  function fix(){
    document.querySelectorAll('input,textarea').forEach(function(el){
      el.style.setProperty('background-color','#1A1A28','important');
      el.style.setProperty('color','#EEEEF5','important');
      el.style.setProperty('-webkit-text-fill-color','#EEEEF5','important');
      el.style.setProperty('caret-color','#F0FF00','important');
    });
    document.querySelectorAll('[data-baseweb="input"],[data-baseweb="base-input"],[data-baseweb="textarea"]').forEach(function(el){
      el.style.setProperty('background-color','#1A1A28','important');
    });
  }
  fix();
  new MutationObserver(fix).observe(document.body,{childList:true,subtree:true});
})();
</script>
""", unsafe_allow_html=True)


# ─────────────────────────────────────────────────────────────
#  ESPN API HELPERS
# ─────────────────────────────────────────────────────────────
ESPN_BASE = "https://site.api.espn.com/apis/site/v2/sports"

# ─────────────────────────────────────────────────────────────
#  THE ODDS API
# ─────────────────────────────────────────────────────────────
ODDS_BASE = "https://api.the-odds-api.com/v4"

def _get_odds_key() -> str:
    try:
        return st.secrets.get("ODDS_API_KEY", "2d5024df981ff5f4a44eccc2ff61affd")
    except Exception:
        return "2d5024df981ff5f4a44eccc2ff61affd"

# Sport keys for The Odds API — verified keys
ODDS_SPORT_MAP = {
    # International soccer — WC qualifiers
    "fifa.worldq":         "soccer_fifa_world_cup_qualifier",
    "fifa.worldq.6":       "soccer_fifa_world_cup_qualifier_europe",
    "fifa.worldq.europe":  "soccer_fifa_world_cup_qualifier_europe",
    "fifa.worldq.uefa":    "soccer_fifa_world_cup_qualifier_europe",
    "uefa.qualifiers":     "soccer_fifa_world_cup_qualifier_europe",
    "fifa.worldq.2":       "soccer_conmebol_copa_america",
    "fifa.worldq.5":       "soccer_fifa_world_cup_qualifier_concacaf",
    "fifa.worldq.3":       "soccer_fifa_world_cup_qualifier_asia",
    "__team_search__":     "soccer_fifa_world_cup_qualifier_europe",
    # Club soccer
    "eng.1":               "soccer_epl",
    "esp.1":               "soccer_spain_la_liga",
    "ita.1":               "soccer_italy_serie_a",
    "ger.1":               "soccer_germany_bundesliga",
    "fra.1":               "soccer_france_ligue_one",
    "mex.1":               "soccer_mexico_ligamx",
    "usa.1":               "soccer_usa_mls",
    "uefa.champions":      "soccer_uefa_champs_league",
    "conmebol.libertadores":"soccer_conmebol_libertadores",
    "uefa.nations":        "soccer_uefa_nations_league",
    "fifa.friendly":       "soccer_international_friendlies",
    # Other sports
    "nba":                 "basketball_nba",
    "nfl":                 "americanfootball_nfl",
    "mlb":                 "baseball_mlb",
    "nhl":                 "icehockey_nhl",
}

# All WC qualifier sport keys to try — covers all paths/confederations
WC_QUALIFIER_KEYS = [
    "soccer_fifa_world_cup_qualifier_europe",
    "soccer_fifa_world_cup_qualifier_concacaf",
    "soccer_fifa_world_cup_qualifier_conmebol",
    "soccer_fifa_world_cup_qualifier_asia",
    "soccer_fifa_world_cup_qualifier_africa",
    "soccer_fifa_world_cup_qualifier_oceania",
    "soccer_international_friendlies",
    "soccer_uefa_nations_league",
]

# Odds API budget: ~500 requests/month free plan
# Strategy: only fetch odds ON DEMAND when user selects a specific league/sport
# NOT on load_all_today — that would burn the quota fast
# Each odds_fetch_sport call = 1 request, cached 6h in Google Sheets
# Safe budget: ~3-4 sport keys per day max = ~100 requests/month

ODDS_CACHE_TAB     = "odds_cache"
ODDS_CACHE_HEADERS = ["sport_key","fetched_at","event_id","home","away",
                       "date_raw","home_odds","away_odds","draw_odds","odds_sport"]
ODDS_CACHE_TTL_HRS = 12  # hours before Sheet cache is considered stale — conserves API quota

def _odds_sheet_read(sport_key: str) -> list:
    """Read cached odds from Google Sheet. Returns [] if stale or missing."""
    try:
        ss = get_ss()
        if not ss: return []
        ws = ensure_tab(ss, ODDS_CACHE_TAB, ODDS_CACHE_HEADERS)
        rows = _safe_get_records(ws)
        if not rows: return []
        # Find rows for this sport_key
        now = datetime.utcnow()
        sport_rows = [r for r in rows if r.get("sport_key","") == sport_key]
        if not sport_rows: return []
        # Check freshness — use fetched_at of first matching row
        try:
            fetched = datetime.fromisoformat(str(sport_rows[0].get("fetched_at","")))
            if (now - fetched).total_seconds() > ODDS_CACHE_TTL_HRS * 3600:
                return []  # stale
        except Exception:
            return []
        # Rebuild event list
        results = []
        for r in sport_rows:
            home = r.get("home",""); away = r.get("away","")
            date_raw = r.get("date_raw","")
            try:
                dt_mx = datetime.fromisoformat(date_raw.replace("Z","+00:00")) - timedelta(hours=6)
                d_str = dt_mx.strftime("%d %b %H:%M")
            except Exception:
                d_str = date_raw[:10]
            # Skip past events
            try:
                ev_dt = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                if ev_dt.replace(tzinfo=None) < datetime.utcnow() - timedelta(hours=2):
                    continue
            except Exception:
                pass
            results.append({
                "id":           f"odds_{r.get('event_id','')}",
                "name":         f"{away} @ {home}",
                "short":        f"{away} @ {home}",
                "home":         home, "away": away,
                "home_logo":    "", "away_logo": "",
                "home_flag":    _get_flag_url(home),
                "away_flag":    _get_flag_url(away),
                "home_score":   "", "away_score": "",
                "date":         d_str, "date_raw": date_raw,
                "status":       "STATUS_SCHEDULED", "status_state": "pre",
                "status_detail":"", "completed": False, "is_live": False,
                "sport":        "soccer", "odds_sport": sport_key,
                "home_odds":    round(float(r.get("home_odds",0) or 0), 2),
                "away_odds":    round(float(r.get("away_odds",0) or 0), 2),
                "draw_odds":    round(float(r.get("draw_odds",0) or 0), 2),
            })
        results.sort(key=lambda e: e["date_raw"])
        return results
    except Exception:
        return []

def _odds_sheet_write(sport_key: str, events: list):
    """Write odds to Google Sheet cache. Replaces existing rows for this sport_key."""
    try:
        ss = get_ss()
        if not ss: return
        ws  = ensure_tab(ss, ODDS_CACHE_TAB, ODDS_CACHE_HEADERS)
        all_rows = _safe_get_records(ws)
        now_str  = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")

        # Delete existing rows for this sport_key (bottom-up)
        rows_to_del = [i for i, r in enumerate(all_rows) if r.get("sport_key","") == sport_key]
        for idx in reversed(rows_to_del):
            try: ws.delete_rows(idx + 2)
            except Exception: pass

        # Write new rows
        new_rows = []
        for ev in events:
            new_rows.append([
                sport_key, now_str,
                ev["id"].replace("odds_",""),
                ev["home"], ev["away"],
                ev["date_raw"],
                ev.get("home_odds",0),
                ev.get("away_odds",0),
                ev.get("draw_odds",0),
                sport_key,
            ])
        if new_rows:
            ws.append_rows(new_rows)
    except Exception:
        pass


def get_live_odds(sport: str, home: str, away: str) -> tuple:
    """
    Get live odds ON DEMAND for a specific event when user is about to bet.
    Returns (away_odds, draw_odds, home_odds).
    Uses Sheet cache — only calls The Odds API if cache is stale (12h).
    """
    SPORT_KEY_MAP = {
        "basketball": ["basketball_nba"],
        "baseball":   ["baseball_mlb"],
        "hockey":     ["icehockey_nhl"],
        "football":   ["americanfootball_nfl"],
        "soccer":     [
            "soccer_epl","soccer_spain_la_liga","soccer_italy_serie_a",
            "soccer_germany_bundesliga","soccer_france_ligue_one",
            "soccer_mexico_ligamx","soccer_usa_mls",
            "soccer_uefa_champs_league","soccer_conmebol_libertadores",
            "soccer_international_friendlies",
            "soccer_fifa_world_cup_qualifier_europe",
            "soccer_fifa_world_cup_qualifier_concacaf",
            "soccer_fifa_world_cup_qualifier_conmebol",
            "soccer_uefa_nations_league",
            "soccer_uefa_europa_league",
        ],
    }

    def name_sim(a: str, b: str) -> bool:
        a, b = a.lower().strip(), b.lower().strip()
        if a == b or a in b or b in a: return True
        aw = [w for w in a.split() if len(w) > 4]
        bw = [w for w in b.split() if len(w) > 4]
        return (bool(aw) and any(w in b for w in aw)) or (bool(bw) and any(w in a for w in bw))

    keys = SPORT_KEY_MAP.get(sport, [])
    for sk in keys:
        try:
            events = odds_fetch_sport(sk)
            for ev in events:
                h_match = name_sim(ev.get("home",""), home)
                a_match = name_sim(ev.get("away",""), away)
                if h_match and a_match:
                    return float(ev.get("away_odds",0)), float(ev.get("draw_odds",0)), float(ev.get("home_odds",0))
                # Try reversed
                if name_sim(ev.get("home",""), away) and name_sim(ev.get("away",""), home):
                    return float(ev.get("home_odds",0)), float(ev.get("draw_odds",0)), float(ev.get("away_odds",0))
        except Exception:
            continue
    return 0.0, 0.0, 0.0


@st.cache_data(ttl=21600, show_spinner=False)  # 6-hour Streamlit cache
def odds_fetch_sport(sport_key: str) -> list:
    """
    Fetch ALL upcoming events + h2h odds for a sport.
    Priority: 1) Streamlit cache  2) Google Sheet cache  3) The Odds API (uses quota)
    """
    # Try Google Sheet cache first
    sheet_data = _odds_sheet_read(sport_key)
    if sheet_data:
        return sheet_data

    # Sheet cache miss — call The Odds API
    key = _get_odds_key()
    try:
        r = requests.get(
            f"{ODDS_BASE}/sports/{sport_key}/odds",
            params={
                "apiKey":     key,
                "regions":    "eu",
                "markets":    "h2h",
                "oddsFormat": "decimal",
                "dateFormat": "iso",
            },
            timeout=10
        )
        if r.status_code != 200:
            return []

        results = []
        for ev in r.json():
            home = ev.get("home_team","")
            away = ev.get("away_team","")
            eid  = ev.get("id","")
            date_raw = ev.get("commence_time","")

            # Skip past events
            try:
                ev_dt = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                if ev_dt.replace(tzinfo=None) < datetime.utcnow() - timedelta(hours=2):
                    continue
                dt_mx = ev_dt - timedelta(hours=6)
                d_str = dt_mx.strftime("%d %b %H:%M")
            except Exception:
                d_str = date_raw[:10]

            # Extract odds from first bookmaker
            home_odds = draw_odds = away_odds = 0.0
            for bk in ev.get("bookmakers",[]):
                for mkt in bk.get("markets",[]):
                    if mkt.get("key") == "h2h":
                        for oc in mkt.get("outcomes",[]):
                            if oc["name"] == home:     home_odds = float(oc["price"])
                            elif oc["name"] == away:   away_odds = float(oc["price"])
                            elif oc["name"] == "Draw": draw_odds = float(oc["price"])
                        break
                if home_odds: break

            results.append({
                "id":           f"odds_{eid}",
                "name":         f"{away} @ {home}",
                "short":        f"{away} @ {home}",
                "home":         home, "away": away,
                "home_logo":    "", "away_logo": "",
                "home_flag":    _get_flag_url(home),
                "away_flag":    _get_flag_url(away),
                "home_score":   "", "away_score": "",
                "date":         d_str, "date_raw": date_raw,
                "status":       "STATUS_SCHEDULED", "status_state": "pre",
                "status_detail":"", "completed": False, "is_live": False,
                "sport":        "soccer", "odds_sport": sport_key,
                "home_odds":    round(home_odds, 2),
                "away_odds":    round(away_odds, 2),
                "draw_odds":    round(draw_odds, 2),
            })

        results.sort(key=lambda e: e["date_raw"])

        # Save to Google Sheet cache for future requests
        if results:
            _odds_sheet_write(sport_key, results)

        return results

    except Exception:
        return []


def odds_search_events(league_slug: str, query: str = "") -> list:
    """
    Search events using cached sport data — NO extra API call per search.
    For international/WC qualifier searches, tries ALL confederation keys.
    """
    sport_key = ODDS_SPORT_MAP.get(league_slug, "")
    q_low     = query.strip().lower()

    # For international soccer, try ALL WC qualifier keys to find all paths
    is_international = league_slug in (
        "fifa.worldq", "fifa.worldq.6", "fifa.worldq.europe",
        "uefa.qualifiers", "__team_search__", "fifa.friendly",
        "fifa.worldq.2", "fifa.worldq.3", "fifa.worldq.5",
    )

    if is_international:
        sports = WC_QUALIFIER_KEYS  # try all confederations
    elif sport_key:
        sports = [sport_key]
    else:
        sports = WC_QUALIFIER_KEYS

    all_events = []
    seen = set()
    for sk in sports:
        cached = odds_fetch_sport(sk)
        for ev in cached:
            if ev["id"] not in seen:
                all_events.append(ev)
                seen.add(ev["id"])

    # Filter by query locally — no API call
    if q_low:
        all_events = [
            e for e in all_events
            if q_low in (e["home"] + " " + e["away"]).lower()
            or any(w in (e["home"] + " " + e["away"]).lower()
                   for w in q_low.split() if len(w) > 2)
        ]

    all_events.sort(key=lambda e: e["date_raw"])
    return all_events


def odds_get_markets(event_id: str, odds_sport: str) -> dict:
    """
    Get odds from already-cached event data — zero extra API calls.
    Just looks up the event in the cached list.
    """
    cached = odds_fetch_sport(odds_sport)
    for ev in cached:
        if ev.get("id") == event_id:
            return {
                "home_odds": ev.get("home_odds", 0),
                "away_odds": ev.get("away_odds", 0),
                "draw_odds": ev.get("draw_odds", 0),
            }
    return {}



def _get_flag_url(country_name: str) -> str:
    """Map country name to flag emoji URL via flagcdn."""
    code_map = {
        "turkey":"tr","turkiye":"tr","romania":"ro","italy":"it","northern ireland":"gb-nir",
        "ukraine":"ua","sweden":"se","poland":"pl","albania":"al","czechia":"cz",
        "czech republic":"cz","ireland":"ie","republic of ireland":"ie","denmark":"dk",
        "north macedonia":"mk","wales":"gb-wls","bosnia":"ba","bosnia and herzegovina":"ba",
        "slovakia":"sk","kosovo":"xk","finland":"fi","england":"gb-eng","france":"fr",
        "germany":"de","spain":"es","portugal":"pt","netherlands":"nl","belgium":"be",
        "croatia":"hr","switzerland":"ch","austria":"at","scotland":"gb-sct","serbia":"rs",
        "greece":"gr","bulgaria":"bg","hungary":"hu","norway":"no","mexico":"mx",
        "usa":"us","united states":"us","brazil":"br","argentina":"ar","colombia":"co",
        "japan":"jp","south korea":"kr","australia":"au","morocco":"ma","senegal":"sn",
    }
    key = country_name.lower().strip()
    code = code_map.get(key, "")
    if code:
        return f"https://flagcdn.com/w80/{code}.png"
    return ""



def _extract_competitor_info(comp: dict, sport: str) -> dict:
    """Extract name, logo, flag, score from a competitor dict."""
    team    = comp.get("team", {})
    athlete = comp.get("athlete", {})

    # ESPN tennis: competitor has displayName directly OR athlete.displayName
    # Also check top-level displayName on the competitor
    comp_display = comp.get("displayName","")

    # Tennis always uses athlete — also use athlete if team has no displayName
    use_athlete = (sport == "tennis") or (not team.get("displayName") and not team.get("name"))

    if not use_athlete and team:
        name  = team.get("displayName", team.get("name", ""))
        logos = team.get("logos", [])
        logo  = logos[0].get("href", "") if logos else team.get("logo", "")
        flag  = ""
        if not logo:
            logo = team.get("flag", {}).get("href", "")
    elif athlete:
        name  = (athlete.get("displayName","") or
                 athlete.get("fullName","") or
                 athlete.get("shortName",""))
        logo  = athlete.get("headshot", {}).get("href", "")
        if not logo:
            aid  = athlete.get("id", "")
            logo = (f"https://a.espncdn.com/combiner/i?img=/i/headshots/tennis/players/full/{aid}.png&w=96&h=70&cb=1"
                    if aid else "")
        flag  = (athlete.get("flag", {}).get("href", "") or
                 athlete.get("country", {}).get("flag", {}).get("href", ""))
    else:
        name = ""; logo = ""; flag = ""

    # Final fallback — use top-level displayName on competitor
    if not name and comp_display and comp_display.upper() not in ["TBD",""]:
        name = comp_display

    # Try links for headshot if no logo yet (tennis ESPN format)
    if not logo and sport == "tennis":
        for link in comp.get("links", []):
            if "headshot" in link.get("rel", []) or "headshot" in link.get("href",""):
                logo = link.get("href",""); break

    # ✅ MEJORADA: Buscar score en MÚLTIPLES LUGARES
    score = ""
    
    # Intento 1: score directo (más común)
    score = comp.get("score", "")
    
    # Intento 2: score en statistics
    if not score:
        stats = comp.get("statistics", [])
        if stats and isinstance(stats, list):
            for stat in stats:
                if stat.get("name") == "runs" or stat.get("name") == "goals":
                    score = stat.get("displayValue", "")
                    break
        # Si aún no hay score, toma el primer valor de statistics
        if not score and stats:
            score = stats[0].get("displayValue", "") if isinstance(stats[0], dict) else ""
    
    # Intento 3: busca en events o plays
    if not score:
        events = comp.get("events", [])
        if isinstance(events, list) and events:
            score = events[0].get("score", "")
    
    # Conversión final: si es número, convertir a string
    if isinstance(score, (int, float)):
        score = str(int(score))
    elif isinstance(score, str):
        score = score.strip()
    else:
        score = ""
    
    return {"name": name or "TBD", "logo": logo, "flag": flag, "score": score}


@st.cache_data(ttl=120, show_spinner=False)
def espn_search_by_team(sport: str, query: str) -> list:
    """
    Search ESPN by team name across all soccer leagues.
    Finds the team ID then gets their upcoming schedule.
    Works for national teams not covered by standard scoreboards.
    """
    results  = []
    seen_ids = set()
    q_low    = query.strip().lower()
    if not q_low:
        return []

    try:
        # Step 1: Find team ID by searching teams endpoint
        team_url = f"{ESPN_BASE}/{sport}/teams"
        r = requests.get(team_url, params={"limit": 1000}, timeout=8)
        if r.status_code != 200:
            return []

        teams_data = r.json().get("sports",[{}])[0].get("leagues",[{}])[0].get("teams",[])
        if not teams_data:
            # Try direct teams list
            teams_data = r.json().get("teams", [])

        matched_ids = []
        for t in teams_data:
            team = t.get("team", t)
            name = (team.get("displayName","") + " " +
                    team.get("name","") + " " +
                    team.get("abbreviation","")).lower()
            if q_low in name or any(w in name for w in q_low.split() if len(w) > 2):
                matched_ids.append(team.get("id",""))

        # Step 2: Get schedule for each matched team
        today     = date.today()
        tomorrow  = (today + timedelta(days=1)).strftime("%Y%m%d")
        two_weeks = (today + timedelta(days=14)).strftime("%Y%m%d")

        for tid in matched_ids[:3]:
            if not tid:
                continue
            sched_url = f"{ESPN_BASE}/{sport}/teams/{tid}/schedule"
            r2 = requests.get(sched_url, params={"dates": f"{tomorrow}-{two_weeks}"}, timeout=8)
            if r2.status_code != 200:
                continue
            for ev in r2.json().get("events", []):
                eid = ev.get("id","")
                if eid in seen_ids:
                    continue
                st_type   = ev.get("competitions",[{}])[0].get("status",{}).get("type",{})
                completed = st_type.get("completed", False) or st_type.get("state","pre") == "post"
                if completed:
                    continue
                comp0 = ev.get("competitions",[{}])[0]
                comps = comp0.get("competitors",[])
                home_c = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                away_c = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                home_i = _extract_competitor_info(home_c, sport)
                away_i = _extract_competitor_info(away_c, sport)
                date_raw = ev.get("date","")
                try:
                    dt     = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                    dt_mx  = dt - timedelta(hours=6)
                    d_str  = dt_mx.strftime("%d %b %H:%M")
                except Exception:
                    d_str = date_raw[:10]
                results.append({
                    "id": eid, "name": ev.get("name",""),
                    "short": ev.get("shortName",""),
                    "home": home_i["name"], "away": away_i["name"],
                    "home_logo": home_i["logo"], "away_logo": away_i["logo"],
                    "home_flag": home_i["flag"], "away_flag": away_i["flag"],
                    "home_score": "", "away_score": "",
                    "date": d_str, "date_raw": date_raw,
                    "status": "STATUS_SCHEDULED", "status_state": "pre",
                    "status_detail": "", "completed": False, "is_live": False,
                    "sport": sport,
                })
                seen_ids.add(eid)
    except Exception:
        pass

    return results


@st.cache_data(ttl=120, show_spinner=False)
def espn_search_events(sport: str, league: str, query: str) -> list:
    """
    Fetch events: 3 days back + 7 days ahead.
    Uses status.type.state ('pre'|'in'|'post') for accurate live detection.
    """
    results  = []
    seen_ids = set()

    def parse_event(ev: dict) -> dict | None:
        name  = ev.get("name", "")
        short = ev.get("shortName", name)
        q_low = query.strip().lower()

        comp0 = ev.get("competitions", [{}])[0]
        comps = comp0.get("competitors", [])
        
        # ✅ Si name está vacío, construir desde competitors
        if not name and comps:
            competitors_names = []
            for c in comps:
                # Intentar múltiples formas de obtener el nombre del team
                team_name = (
                    c.get("team", {}).get("displayName", "") or
                    c.get("team", {}).get("name", "") or
                    c.get("displayName", "") or
                    c.get("name", "") or
                    c.get("athlete", {}).get("displayName", "") or
                    c.get("athlete", {}).get("fullName", "") or
                    ""
                )
                if team_name:
                    competitors_names.append(team_name)
            
            if len(competitors_names) >= 2:
                name = f"{competitors_names[0]} vs {competitors_names[1]}"
            elif len(competitors_names) == 1:
                name = competitors_names[0]

        if q_low:
            all_text = (name + " " + short).lower()
            for c in comps:
                all_text += " " + c.get("team", {}).get("displayName", "").lower()
                all_text += " " + c.get("athlete", {}).get("displayName", "").lower()
            if q_low not in all_text:
                return None

        status_type  = ev.get("status", {}).get("type", {})
        state        = status_type.get("state", "pre")
        status_name  = status_type.get("name", "STATUS_SCHEDULED")
        status_short = status_type.get("shortDetail", "")
        completed    = (state == "post") or status_type.get("completed", False)
        
        # ✅ DETECCIÓN DE EN VIVO POR HORA (sin depender de ESPN)
        is_live = False
        try:
            # Parsear fecha del partido
            date_raw = ev.get("date_raw", "")
            if date_raw:
                dt = datetime.fromisoformat(date_raw.replace("Z", "+00:00"))
                dt_mx = dt - timedelta(hours=6)  # UTC → Mexico City
                now_mx = datetime.now(timezone.utc) - timedelta(hours=6)
                
                # Si pasaron entre 0 y 3.5 horas desde que empezó = EN VIVO
                time_diff_hours = (now_mx - dt_mx).total_seconds() / 3600
                
                # EN VIVO: si el partido empezó hace 0 a 3.5 horas
                if 0 <= time_diff_hours <= 3.5:
                    is_live = True
        except:
            pass

        # ── Skip completed (past) games — only show live or upcoming ──
        if completed and not is_live:
            return None

        home_comp = next((c for c in comps if c.get("homeAway") == "home"), comps[0] if comps else {})
        away_comp = next((c for c in comps if c.get("homeAway") == "away"), comps[1] if len(comps) > 1 else {})
        home_info = _extract_competitor_info(home_comp, sport)
        away_info = _extract_competitor_info(away_comp, sport)

        # Skip tennis matches with TBD players
        if sport == "tennis":
            if home_info["name"] in ("?","TBD","") or away_info["name"] in ("?","TBD",""):
                return None

        date_raw = ev.get("date", "")
        try:
            dt       = datetime.fromisoformat(date_raw.replace("Z", "+00:00"))
            dt_mx    = dt - timedelta(hours=6)   # UTC → Mexico City
            date_str = dt_mx.strftime("%d %b %H:%M")
        except Exception:
            date_str = date_raw[:10]

        return {
            "id":            ev.get("id", ""),
            "name":          name or f"{away_info['name']} vs {home_info['name']}",
            "short":         short,
            "home":          home_info["name"],
            "away":          away_info["name"],
            "home_logo":     home_info["logo"],
            "away_logo":     away_info["logo"],
            "home_flag":     home_info["flag"],
            "away_flag":     away_info["flag"],
            "home_score":    home_info["score"],
            "away_score":    away_info["score"],
            "date":          date_str,
            "date_raw":      date_raw,
            "status":        status_name,
            "status_state":  state,
            "status_detail": status_short,
            "completed":     completed,
            "is_live":       is_live,
            "sport":         sport,
        }

    try:
        url   = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
        today = date.today()

        # Build individual date requests: today + 14 days ahead
        dates_to_try = []
        for d in range(0, 15):
            dates_to_try.append((today + timedelta(days=d)).strftime("%Y%m%d"))
        # Range request
        dates_to_try.append(
            today.strftime("%Y%m%d") + "-" + (today + timedelta(days=14)).strftime("%Y%m%d")
        )
        # Bare scoreboard first (live/today)
        dates_to_try.insert(0, None)

        for dr in dates_to_try:
            try:
                params = {"limit": 100}
                if dr:
                    params["dates"] = dr
                r = requests.get(url, params=params, timeout=6)
                if r.status_code != 200:
                    continue
                for ev in r.json().get("events", []):
                    eid = ev.get("id", "")
                    if eid in seen_ids:
                        continue
                    parsed = parse_event(ev)
                    if parsed:
                        results.append(parsed)
                        seen_ids.add(eid)
            except Exception:
                continue

    except Exception:
        pass

    # ── Fallback: if no results and it's a soccer intl league, try alternate slugs ──
    if not results and sport == "soccer":
        FALLBACK_SLUGS = {
            "fifa.worldq.6":      ["fifa.worldq.europe", "uefa.worldq", "uefa.qualifiers", "fifa.worldq", "fifa.worldq.eu"],
            "fifa.worldq.europe": ["fifa.worldq.6", "uefa.worldq", "uefa.qualifiers", "fifa.worldq"],
            "uefa.qualifiers":    ["fifa.worldq.6", "fifa.worldq.europe", "uefa.worldq", "fifa.worldq"],
            "uefa.worldq":        ["fifa.worldq.6", "fifa.worldq.europe", "uefa.qualifiers", "fifa.worldq"],
            "fifa.worldq.2":      ["conmebol.worldq", "fifa.worldq"],
            "fifa.worldq.5":      ["concacaf.worldq", "fifa.worldq"],
            "fifa.worldq.3":      ["afc.worldq", "fifa.worldq"],
            "fifa.worldq":        ["fifa.worldq.6", "fifa.worldq.europe", "uefa.qualifiers",
                                   "fifa.worldq.2", "fifa.worldq.3", "fifa.worldq.5"],
            "fifa.friendly":      ["fifa.friendly.int", "soccer.friendly"],
        }
        tomorrow    = (date.today() + timedelta(days=1)).strftime("%Y%m%d")
        two_weeks   = (date.today() + timedelta(days=14)).strftime("%Y%m%d")
        date_range  = f"{tomorrow}-{two_weeks}"

        for alt_slug in FALLBACK_SLUGS.get(league, []):
            try:
                alt_url = f"{ESPN_BASE}/{sport}/{alt_slug}/scoreboard"
                for dr in [None, date.today().strftime("%Y%m%d"), date_range]:
                    params = {"limit": 100}
                    if dr: params["dates"] = dr
                    r = requests.get(alt_url, params=params, timeout=8)
                    if r.status_code == 200:
                        for ev in r.json().get("events", []):
                            eid = ev.get("id", "")
                            if eid in seen_ids: continue
                            parsed = parse_event(ev)
                            if parsed:
                                results.append(parsed)
                                seen_ids.add(eid)
                if results:
                    break
            except Exception:
                continue

    # ── Last resort: ESPN generic events endpoint with date range ──
    # Catches events not in standard scoreboard slugs (e.g. UEFA WC2026 playoffs)
    if not results and query.strip() and sport == "soccer":
        try:
            tomorrow  = (date.today() + timedelta(days=1)).strftime("%Y%m%d")
            two_weeks = (date.today() + timedelta(days=14)).strftime("%Y%m%d")
            for generic_slug in ["fifa.worldq", "fifa.worldq.6", "fifa.worldq.europe",
                                  "uefa.qualifiers", "fifa.worldq.2", "fifa.worldq.5"]:
                r_g = requests.get(
                    f"{ESPN_BASE}/soccer/{generic_slug}/scoreboard",
                    params={"dates": f"{tomorrow}-{two_weeks}", "limit": 100},
                    timeout=8
                )
                if r_g.status_code == 200:
                    for ev in r_g.json().get("events", []):
                        eid = ev.get("id","")
                        if eid in seen_ids: continue
                        parsed = parse_event(ev)
                        if parsed:
                            results.append(parsed)
                            seen_ids.add(eid)
                if results:
                    break
        except Exception:
            pass

    def sort_key(ev):
        if ev["is_live"]:       return "0_" + ev["date_raw"]
        if not ev["completed"]: return "1_" + ev["date_raw"]
        return "2_" + ev["date_raw"]

    results.sort(key=sort_key)
    return results


@st.cache_data(ttl=60, show_spinner=False)
def espn_get_event(sport: str, league: str, event_id: str) -> dict:
    """Fetch single event details — used for auto-grading."""
    try:
        url = f"{ESPN_BASE}/{sport}/{league}/summary"
        r = requests.get(url, params={"event": event_id}, timeout=8)
        if r.status_code != 200:
            return {}
        return r.json()
    except Exception:
        return {}


def parse_result_from_event(event_data: dict, pick_desc: str, mercado: str) -> str | None:
    """
    Given a completed ESPN event and the pick description,
    return 'ganado', 'perdido', or None if can't determine.
    pick_desc examples: "New York Yankees ML", "Over 8.5", "BTTS ambos anotan", "Lakers -5.5"
    """
    if not event_data:
        return None

    try:
        import re as _re

        # ── Extract scores and team names — header is the reliable source ──
        home_score, away_score = 0.0, 0.0
        home_name,  away_name  = "", ""

        # Primary: header.competitions[0].competitors — scores are HERE
        comps_list = (event_data.get("header",{})
                                .get("competitions",[{}])[0]
                                .get("competitors",[]))
        for c in comps_list:
            side  = c.get("homeAway","")
            team  = c.get("team",{})
            name  = (team.get("displayName","") or team.get("name","") or
                     team.get("shortDisplayName","") or c.get("name",""))
            score_raw = str(c.get("score","") or "")
            try: score = float(score_raw) if score_raw.strip() else 0.0
            except: score = 0.0
            if side == "home":   home_score = score; home_name = name.lower()
            elif side == "away": away_score = score; away_name = name.lower()

        # Fallback: boxscore.teams for names if header didn't have them
        if not home_name or not away_name:
            for t in event_data.get("boxscore",{}).get("teams",[]):
                side  = t.get("homeAway","")
                name  = (t.get("team",{}).get("displayName","") or
                         t.get("team",{}).get("name",""))
                score_raw = str(t.get("score","") or "")
                try: score = float(score_raw) if score_raw.strip() else 0.0
                except: score = 0.0
                if side == "home" and not home_name:
                    home_score = score; home_name = name.lower()
                elif side == "away" and not away_name:
                    away_score = score; away_name = name.lower()

        total = home_score + away_score

        # Clean pick_desc — strip emojis and suffixes
        import unicodedata
        def strip_emojis(s: str) -> str:
            return "".join(c for c in s if unicodedata.category(c) not in ("So","Sk","Sm") and ord(c) < 0x10000).strip()

        pick_low   = strip_emojis(pick_desc.strip()).lower()
        pick_clean = (pick_low
                      .replace(" ml","").replace(" gana","").replace(" wins","")
                      .replace(" money line","").replace("🏆","").replace("🎯","")
                      .replace("⚽","").replace("🏀","").replace("⚾","").replace("🏒","")
                      .strip())
        merc_low   = mercado.strip().lower()

        def name_match(team: str, pick: str) -> bool:
            if not team or not pick: return False
            if team == pick: return True
            if team in pick or pick in team: return True
            # Word overlap — meaningful words only (>3 chars)
            t_words = [w for w in team.split() if len(w) > 3]
            p_words = [w for w in pick.split() if len(w) > 3]
            if t_words and any(w in pick for w in t_words): return True
            if p_words and any(w in team for w in p_words): return True
            return False

        # ── ML / Ganador ──
        is_ml = ("ml" in merc_low or "ganador" in merc_low or
                 "1x2" in merc_low or "resultado" in merc_low or
                 "money" in merc_low or merc_low == "")

        if is_ml or name_match(home_name, pick_clean) or name_match(away_name, pick_clean):
            if name_match(home_name, pick_clean):
                if home_score > away_score: return "ganado"
                if home_score < away_score: return "perdido"
                return "nulo"
            if name_match(away_name, pick_clean):
                if away_score > home_score: return "ganado"
                if away_score < home_score: return "perdido"
                return "nulo"
            if "empate" in pick_low or "draw" in pick_low:
                return "ganado" if home_score == away_score else "perdido"

        # ── Over / Under ──
        if "over" in pick_low or "under" in pick_low or "o/u" in merc_low:
            nums = _re.findall(r"[\d]+\.?[\d]*", pick_desc)
            if nums:
                line = float(nums[0])
                if "over" in pick_low:
                    return "ganado" if total > line else ("nulo" if total == line else "perdido")
                else:
                    return "ganado" if total < line else ("nulo" if total == line else "perdido")

        # ── BTTS ──
        if ("btts" in merc_low or "ambos" in merc_low or
            "btts" in pick_low or "ambos" in pick_low):
            both = home_score > 0 and away_score > 0
            if "no" in pick_low and "anotan" not in pick_low:
                return "ganado" if not both else "perdido"
            return "ganado" if both else "perdido"

        # ── Handicap ──
        if "hándicap" in merc_low or "handicap" in merc_low or "spread" in merc_low:
            nums = _re.findall(r"[+-]?[\d.]+", pick_desc)
            if nums:
                hcap = float(nums[-1])
                if name_match(home_name, pick_clean):
                    adj = home_score + hcap
                    if adj > away_score: return "ganado"
                    if adj == away_score: return "nulo"
                    return "perdido"
                if name_match(away_name, pick_clean):
                    adj = away_score + hcap
                    if adj > home_score: return "ganado"
                    if adj == home_score: return "nulo"
                    return "perdido"

    except Exception:
        pass
    return None


# ─────────────────────────────────────────────────────────────
#  GOOGLE SHEETS
# ─────────────────────────────────────────────────────────────
SCOPE = ["https://spreadsheets.google.com/feeds", "https://www.googleapis.com/auth/drive"]

@st.cache_resource(ttl=1800)
def get_client():
    try:
        creds_dict = {k: v for k, v in st.secrets["gsheets"].items() if k != "spreadsheet_id"}
        creds = ServiceAccountCredentials.from_json_keyfile_dict(creds_dict, SCOPE)
        return gspread.authorize(creds)
    except Exception:
        return None

def get_ss():
    """Get spreadsheet — auto-reconnect if OAuth token expired."""
    c = get_client()
    if not c: return None
    try:
        return c.open_by_key(st.secrets["gsheets"]["spreadsheet_id"])
    except Exception:
        # Token likely expired — clear cache and rebuild
        try:
            get_client.clear()
            c2 = get_client()
            if c2:
                return c2.open_by_key(st.secrets["gsheets"]["spreadsheet_id"])
        except Exception:
            pass
        return None

def ensure_tab(ss, name: str, headers: list):
    if ss is None:
        raise ValueError("No spreadsheet connection")
    try:
        ws = ss.worksheet(name)
        try:
            current = ws.row_values(1)
            if not current:
                ws.update("A1", [headers])
            elif current != headers:
                # Header mismatch (old format) — update to correct headers
                ws.update("A1", [headers])
        except Exception:
            pass
        return ws
    except gspread.WorksheetNotFound:
        ws = ss.add_worksheet(title=name, rows=2000, cols=max(len(headers), 20))
        ws.append_row(headers)
        return ws
    except Exception as e:
        try:
            get_client.clear()
            ss2 = get_ss()
            if ss2:
                return ensure_tab(ss2, name, headers)
        except Exception:
            pass
        raise e

def load_picks(apodo: str) -> pd.DataFrame:
    ss = get_ss()
    if not ss: return pd.DataFrame(columns=PICKS_HEADERS)
    ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
    try:
        data = ws.get_all_records(expected_headers=PICKS_HEADERS)
    except Exception:
        try:
            # Fallback: read raw and build DataFrame manually
            all_vals = ws.get_all_values()
            if len(all_vals) < 2:
                return pd.DataFrame(columns=PICKS_HEADERS)
            raw_headers = all_vals[0]
            rows = all_vals[1:]
            df_raw = pd.DataFrame(rows, columns=raw_headers)
            # Add missing columns
            for col in PICKS_HEADERS:
                if col not in df_raw.columns:
                    df_raw[col] = ""
            data = df_raw[PICKS_HEADERS].to_dict("records")
        except Exception:
            return pd.DataFrame(columns=PICKS_HEADERS)
    if not data: return pd.DataFrame(columns=PICKS_HEADERS)
    df = pd.DataFrame(data)
    # Ensure all expected columns exist
    for col in PICKS_HEADERS:
        if col not in df.columns:
            df[col] = ""
    df["fecha"] = pd.to_datetime(df["fecha"], errors="coerce")
    for col in ["momio","apuesta","ganancia_neta","bankroll_post"]:
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    return df

def save_pick(apodo: str, row: dict) -> bool:
    ss = get_ss()
    if not ss: return False
    try:
        ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
        ws.append_row([str(row.get(h, "")) for h in PICKS_HEADERS])
        return True
    except Exception:
        return False

def delete_pick(apodo: str, df_idx: int):
    """Delete a pick row from the sheet (df_idx = 0-based DataFrame index)."""
    ss = get_ss()
    if not ss: return False
    try:
        ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
        ws.delete_rows(df_idx + 2)  # +2: header row + 0-based index
        return True
    except Exception:
        return False

def update_pick_row(apodo: str, df_idx: int, resultado: str, ganancia: float, bank_post: float):
    ss = get_ss()
    if not ss: return False
    try:
        ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
        sheet_row = df_idx + 2
        ws.update_cell(sheet_row, 10, resultado)
        ws.update_cell(sheet_row, 11, round(ganancia, 2))
        ws.update_cell(sheet_row, 12, round(bank_post, 2))
        return True
    except Exception:
        return False

def load_users() -> list:
    try:
        ss = get_ss()
        if not ss: return []
        ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","wins","losses","created"])
        return _safe_get_records(ws)
    except Exception:
        return []

def upsert_user(apodo: str, bankroll: float, wins: int, losses: int):
    ss = get_ss()
    if not ss: return
    try:
        ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","wins","losses","created"])
        records = _safe_get_records(ws)
        found = [(i, r) for i, r in enumerate(records)
                 if r.get("apodo","").lower() == apodo.lower()]
        # Remove duplicates if any (keep first)
        if len(found) > 1:
            for dup_i, _ in reversed(found[1:]):
                try: ws.delete_rows(dup_i + 2)
                except Exception: pass
            records = _safe_get_records(ws)
            found = [(i, r) for i, r in enumerate(records)
                     if r.get("apodo","").lower() == apodo.lower()]
        if found:
            i, r = found[0]
            ws.update(f"A{i+2}:E{i+2}",
                      [[apodo, round(bankroll,2), wins, losses, r.get("created","")]])
        else:
            ws.append_row([apodo, round(bankroll,2), wins, losses, str(date.today())])
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────
#  AUTO-GRADER
# ─────────────────────────────────────────────────────────────
def format_partido_para_display(partido: str, deporte: str) -> str:
    """
    ✅ Formatear partido SEGÚN ESPN para mostrar en tarjetas
    Soccer: "Home vs Away" (Local vs Visitante - HOME PRIMERO)
    NBA/NHL/MLB/NFL: "Away@Home" (Visitante@Local con @)
    
    Nota: Guardamos siempre como "Away@Home" internamente
    """
    if not partido:
        return partido
    
    deporte = str(deporte).lower().strip()
    partido = str(partido).strip()
    
    # Dividir por @ o vs (formato interno es siempre Away@Home)
    if "@" in partido:
        partes = partido.split("@")
    elif " vs " in partido:
        partes = partido.split(" vs ")
    else:
        return partido
    
    if len(partes) != 2:
        return partido
    
    # En nuestro formato interno: partes[0]=Away (visitante), partes[1]=Home (local)
    away = partes[0].strip()
    home = partes[1].strip()
    
    if deporte == "soccer":
        # Soccer: Home vs Away (LOCAL vs VISITANTE - home primero)
        return f"{home} vs {away}"
    else:
        # NBA/NHL/MLB/NFL: Away@Home (VISITANTE@LOCAL con @)
        return f"{away}@{home}"




def puede_registrar_pick_hoy(apodo: str, ronda_id: str) -> tuple[bool, str]:
    """
    ✅ Validar si el usuario ya registró 1 pick hoy
    Solo permite 1 pick por día
    """
    try:
        ss = get_ss()
        if not ss:
            return False, "❌ Error: No hay conexión a Google Sheets"
        
        ws_picks = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
        _rate_limit_gs("pit_picks_check")  # Rate limit
        all_picks = _safe_get_records(ws_picks)
        
        today_cdmx = datetime.now(pytz.timezone('America/Mexico_City')).date()
        
        # Contar picks de hoy para este usuario en esta ronda
        picks_hoy = [p for p in all_picks 
                     if str(p.get("ronda_id","")).strip() == str(ronda_id) and
                        str(p.get("apodo","")).lower().strip() == apodo.lower().strip() and
                        str(p.get("fecha","")).startswith(str(today_cdmx))]
        
        if len(picks_hoy) >= 1:
            return False, f"❌ Ya registraste 1 pick hoy en esta ronda. Solo se permite 1 por día."
        
        return True, "✅ Puedes registrar tu pick"
    except Exception as e:
        return False, f"❌ Error al validar: {str(e)[:100]}"


# ═══════════════════════════════════════════════════════════════
# 🚀 CALIFICACIÓN AUTOMÁTICA ULTRA-ROBUSTA 24/7
# ═══════════════════════════════════════════════════════════════
@st.cache_resource(ttl=300)  # Ejecutar cada 5 minutos
def auto_grade_all_picks_master():
    """
    ✅ CALIFICACIÓN MAESTRA GLOBAL - FUNCIONA PARA TODOS LOS USUARIOS
    
    - Corre cada 5 minutos automáticamente
    - Busca TODOS los picks pendientes (de TODOS los usuarios)
    - Usa event_id como identificador principal
    - Califica automáticamente cuando partido termina
    - Maneja REGISTRAR + THE PIT
    """
    try:
        ss = get_ss()
        if not ss:
            return
        
        # ═══════════════════════════════════════════════════════════════
        # PARTE 1: Calificar picks de REGISTRAR (todas las hojas picks_*)
        # ═══════════════════════════════════════════════════════════════
        try:
            for sheet in ss.worksheets():
                # Solo procesar hojas picks_APODO
                if not sheet.title.startswith("picks_"):
                    continue
                
                # Saltar pit_picks (lo manejamos aparte)
                if sheet.title == "pit_picks":
                    continue
                
                try:
                    records = _safe_get_records(sheet)
                    
                    for idx, row in enumerate(records):
                        resultado = row.get("resultado", "").strip().lower()
                        
                        # Solo procesar picks PENDIENTES
                        if resultado == "pendiente":
                            _calificar_pick_robusto(sheet, idx + 2, row)
                except:
                    pass
        except:
            pass
        
        # ═══════════════════════════════════════════════════════════════
        # PARTE 2: Calificar picks de THE PIT
        # ═══════════════════════════════════════════════════════════════
        try:
            ws_pit = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            pit_records = _safe_get_records(ws_pit)
            
            for idx, row in enumerate(pit_records):
                resultado = row.get("resultado", "").strip().lower()
                
                # Solo procesar picks PENDIENTES
                if resultado == "pendiente":
                    _calificar_pick_robusto(ws_pit, idx + 2, row)
        except:
            pass
        
    except Exception as e:
        pass  # Silenciar errores - función no debe fallar nunca


def _calificar_pick_robusto(sheet, row_idx: int, pick_row: dict):
    """
    Califica UN pick con máxima robustez
    
    Estrategia:
    1. Intentar por EVENT_ID (más preciso y rápido)
    2. Si falla, buscar por NOMBRE del partido
    3. Si falla, no hace nada (esperar a siguiente ciclo)
    """
    try:
        partido = pick_row.get("partido", "").strip()
        deporte = pick_row.get("deporte", "soccer").strip().lower()
        pick_desc = pick_row.get("pick_desc", "").strip().lower()
        event_id = pick_row.get("event_id", "").strip()
        
        if not partido or not pick_desc:
            return
        
        resultado = None
        
        # ─── ESTRATEGIA 1: Buscar por EVENT_ID (SI EXISTE) ───
        if event_id:
            espn_data = _find_resultado_por_event_id(event_id, deporte)
            if espn_data.get("found"):
                # ¡ENCONTRADO POR EVENT_ID!
                if espn_data.get("completed"):
                    away_team = espn_data.get("away_team", "")
                    home_team = espn_data.get("home_team", "")
                    away_score = espn_data.get("away_score", -1)
                    home_score = espn_data.get("home_score", -1)
                    
                    resultado = _calificar_resultado(away_team, home_team, away_score, home_score, pick_desc)
        
        # ─── ESTRATEGIA 2: Si NO hay event_id, BUSCARLO por NOMBRE ───
        if not resultado and not event_id:
            # Buscar event_id automáticamente por nombre del partido
            found_event_id = _buscar_event_id_por_partido(partido, deporte)
            if found_event_id:
                # ✅ GUARDAR event_id encontrado en Google Sheets
                try:
                    _actualizar_event_id_en_sheets(sheet, row_idx, found_event_id)
                except:
                    pass
                
                espn_data = _find_resultado_por_event_id(found_event_id, deporte)
                if espn_data.get("found") and espn_data.get("completed"):
                    away_team = espn_data.get("away_team", "")
                    home_team = espn_data.get("home_team", "")
                    away_score = espn_data.get("away_score", -1)
                    home_score = espn_data.get("home_score", -1)
                    
                    resultado = _calificar_resultado(away_team, home_team, away_score, home_score, pick_desc)
        
        # ─── ESTRATEGIA 3: Buscar por NOMBRE (ÚLTIMO FALLBACK) ───
        if not resultado:
            resultado = _find_resultado_robusto(partido, deporte, pick_desc)
        
        # ─── ACTUALIZAR en Google Sheets ───
        if resultado:  # "ganado" o "perdido"
            try:
                col_resultado = 10  # Columna de resultado
                sheet.update_cell(row_idx, col_resultado, resultado)
            except:
                pass
    except:
        pass


def _auto_qualify_pit_robust(sheet, row_idx: int, pick_row: dict):
    """
    (Deprecated) Usar _calificar_pick_robusto en su lugar
    """
    _calificar_pick_robusto(sheet, row_idx, pick_row)


def _actualizar_event_id_en_sheets(sheet, row_idx: int, event_id: str):
    """
    Actualiza el event_id en Google Sheets cuando se encuentra automáticamente
    """
    try:
        if event_id and event_id.strip():
            col_event_id = 5  # Columna event_id (5 en picks_*, 7 en pit_picks)
            sheet.update_cell(row_idx, col_event_id, event_id)
    except:
        pass


def _buscar_event_id_por_partido(partido: str, deporte: str = "soccer") -> str:
    """
    Busca el event_id en ESPN usando el nombre del partido
    
    Retorna el event_id si lo encuentra, sino retorna ""
    """
    import requests
    
    try:
        def norm(s):
            import unicodedata
            s = unicodedata.normalize('NFD', s)
            s = ''.join(char for char in s if unicodedata.category(char) != 'Mn')
            return s.lower().replace(' ', '').replace('.', '')
        
        sports_map = {
            "soccer": ["eng.1", "esp.1", "ita.1", "ger.1", "fra.1", "mex.1", "usa.1", "bra.1", "international-friendly"],
            "basketball": ["nba"],
            "hockey": ["nhl"],
            "baseball": ["mlb"],
        }
        
        deporte = deporte.lower().strip()
        leagues = sports_map.get(deporte, [])
        
        partido_norm = norm(partido.replace("@", " vs "))
        
        for league in leagues:
            try:
                url = f"https://site.api.espn.com/apis/site/v2/sports/{deporte}/{league}/events"
                r = requests.get(url, timeout=3)
                
                if r.status_code == 200:
                    data = r.json()
                    for evt in data.get("events", []):
                        comp = evt.get("competitions", [{}])[0]
                        competitors = comp.get("competitors", [])
                        
                        if len(competitors) >= 2:
                            away = competitors[1].get("team", {}).get("name", "")
                            home = competitors[0].get("team", {}).get("name", "")
                            match_norm_1 = norm(f"{away} vs {home}")
                            match_norm_2 = norm(f"{home} vs {away}")
                            
                            if partido_norm == match_norm_1 or partido_norm == match_norm_2:
                                # ¡ENCONTRADO! Retornar event_id
                                return evt.get("id", "")
            except:
                continue
        
        return ""  # No encontrado
        
    except Exception as e:
        return ""


def _find_resultado_por_event_id(event_id: str, deporte: str = "soccer") -> dict:
    """
    Busca resultado en ESPN usando event_id directamente (MÁS RÁPIDO Y PRECISO)
    
    Retorna dict con:
    - found: bool
    - away_team: str
    - home_team: str
    - away_score: int
    - home_score: int
    - status: str (completado, en vivo, etc)
    """
    import requests
    
    try:
        # Convertir a string si es int
        event_id = str(event_id).strip()
        
        if not event_id or event_id == "":
            return {"found": False, "debug": "Event ID vacío"}
        
        sports_map = {
            "soccer": ["eng.1", "esp.1", "ita.1", "ger.1", "fra.1", "mex.1", "usa.1", "bra.1", "international-friendly"],
            "basketball": ["nba"],
            "hockey": ["nhl"],
            "baseball": ["mlb"],
        }
        
        deporte = deporte.lower().strip()
        leagues = sports_map.get(deporte, ["eng.1"])
        
        # Intentar cada liga
        for league in leagues:
            try:
                url = f"https://site.api.espn.com/apis/site/v2/sports/{deporte}/{league}/events/{event_id}"
                r = requests.get(url, timeout=5)
                
                if r.status_code == 200:
                    evt = r.json()
                    comp = evt.get("competitions", [{}])[0]
                    competitors = comp.get("competitors", [])
                    status = comp.get("status", {}).get("type", "")
                    
                    if len(competitors) >= 2:
                        away_team = competitors[1].get("team", {}).get("name", "")
                        home_team = competitors[0].get("team", {}).get("name", "")
                        away_score = int(competitors[1].get("score", -1))
                        home_score = int(competitors[0].get("score", -1))
                        
                        return {
                            "found": True,
                            "away_team": away_team,
                            "home_team": home_team,
                            "away_score": away_score,
                            "home_score": home_score,
                            "status": status,
                            "completed": status == "STATUS_FINAL",
                            "debug": f"✅ Encontrado en {league}: {away_team} {away_score} - {home_score} {home_team} (Status: {status})"
                        }
                    else:
                        return {
                            "found": False,
                            "debug": f"⚠️ {league}: Encontrado evento pero sin datos de competidores (len={len(competitors)})"
                        }
                elif r.status_code == 404:
                    continue  # Intentar siguiente liga
            except Exception as e:
                continue
        
        return {
            "found": False,
            "debug": f"❌ Event ID {event_id} no encontrado en ninguna liga"
        }
        
    except Exception as e:
        return {
            "found": False,
            "debug": f"❌ Error: {str(e)[:50]}"
        }


def _find_resultado_robusto(partido: str, deporte: str, pick_desc: str) -> str:
    """
    ✅ BÚSQUEDA ROBUSTA: Encuentra CUALQUIER resultado
    Intenta múltiples estrategias hasta encontrar
    """
    import requests
    import re as re_mod
    
    # Normalizar nombre
    def norm(text):
        text = ''.join(c for c in __import__('unicodedata').normalize('NFD', text)
                      if __import__('unicodedata').category(c) != 'Mn')
        return re_mod.sub(r'[^a-z0-9\s]', '', text.lower().strip())
    
    try:
        # ─── ESTRATEGIA 1: Búsqueda por NOMBRE ───
        all_today = {}
        sports_map = {
            "soccer": ["eng.1", "esp.1", "ita.1", "ger.1", "fra.1", "mex.1", "usa.1", "bra.1", "international-friendly"],
            "basketball": ["nba"],
            "hockey": ["nhl"],
            "baseball": ["mlb"],
        }
        
        for sport, leagues in sports_map.items():
            for league in leagues:
                try:
                    url = f"https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/events"
                    r = requests.get(url, timeout=3)
                    if r.status_code == 200:
                        data = r.json()
                        for evt in data.get("events", []):
                            comp = evt.get("competitions", [{}])[0]
                            competitors = comp.get("competitors", [])
                            
                            if len(competitors) >= 2:
                                away = competitors[1].get("team", {}).get("name", "")
                                home = competitors[0].get("team", {}).get("name", "")
                                away_score = competitors[1].get("score", -1)
                                home_score = competitors[0].get("score", -1)
                                
                                # Matchear partido - INTENTAR AMBAS DIRECCIONES
                                partido_norm = norm(partido.replace("@", " vs "))
                                match_norm_1 = norm(f"{away} vs {home}")  # Dirección original
                                match_norm_2 = norm(f"{home} vs {away}")  # Dirección invertida
                                
                                if (partido_norm == match_norm_1 or partido_norm == match_norm_2) and away_score >= 0 and home_score >= 0:
                                    # ¡ENCONTRADO! Calificar
                                    return _calificar_resultado(away, home, away_score, home_score, pick_desc)
                except:
                    pass
        
        # ─── ESTRATEGIA 2: Si falla nombre, buscar por similaridad ───
        # (Implementar si es necesario)
        
        return ""  # No encontrado
        
    except Exception as e:
        return ""


def _calificar_resultado(away: str, home: str, away_score: int, home_score: int, pick_desc: str) -> str:
    """
    Determina si el pick GANÓ o PERDIÓ basado en resultado real
    """
    try:
        pick_desc = pick_desc.lower().strip()
        
        # Determinar ganador
        if home_score > away_score:
            winner = "home"
        elif away_score > home_score:
            winner = "away"
        else:
            winner = "draw"
        
        # Matchear pick
        away_norm = away.lower().replace(' ', '').replace('.', '')
        home_norm = home.lower().replace(' ', '').replace('.', '')
        
        if "empate" in pick_desc or "draw" in pick_desc:
            return "ganado" if winner == "draw" else "perdido"
        elif any(w in pick_desc for w in away_norm.split() if len(w) > 2):
            return "ganado" if winner == "away" else "perdido"
        elif any(w in pick_desc for w in home_norm.split() if len(w) > 2):
            return "ganado" if winner == "home" else "perdido"
        else:
            # Fallback: primer 4 caracteres
            if away_norm[:4] in pick_desc:
                return "ganado" if winner == "away" else "perdido"
            elif home_norm[:4] in pick_desc:
                return "ganado" if winner == "home" else "perdido"
        
        return ""
    except:
        return ""


def auto_grade_pending(apodo: str, df: pd.DataFrame, bank: float) -> tuple[pd.DataFrame, int, float]:
    """
    ✅ AUTO-GRADE: Busca por NOMBRE de partido (no event_id que NO funciona)
    - Carga todos los partidos de ESPN
    - Busca por nombre de partido
    - Respeta formato según deporte
    - Califica automáticamente
    """
    pending = df[df["resultado"].isin(["pendiente", "nulo"])].copy()
    if pending.empty:
        return df, 0, bank

    graded = 0
    current_bank = bank

    try:
        import requests
        import re as re_mod
        
        # Cargar todos los partidos de hoy
        all_today = {}
        sports_map = {
            "soccer": ["eng.1", "esp.1", "ita.1", "ger.1", "fra.1", "mex.1", "usa.1", "bra.1"],
            "basketball": ["nba"],
            "hockey": ["nhl"],
            "baseball": ["mlb"],
        }
        
        for sport, leagues in sports_map.items():
            all_today[sport] = {}
            for league_slug in leagues:
                try:
                    url = f"https://site.api.espn.com/apis/site/v2/sports/{sport}/{league_slug}/events"
                    resp = requests.get(url, timeout=5)
                    if resp.status_code == 200:
                        data = resp.json()
                        events = data.get("events", [])
                        league_events = []
                        for evt in events:
                            comp = evt.get("competitions", [{}])[0]
                            competitors = comp.get("competitors", [])
                            if len(competitors) >= 2:
                                away = competitors[1].get("team", {}).get("name", "?")
                                home = competitors[0].get("team", {}).get("name", "?")
                                away_score = int(competitors[1].get("score", -1)) if competitors[1].get("score") is not None else -1
                                home_score = int(competitors[0].get("score", -1)) if competitors[0].get("score") is not None else -1
                                league_events.append({
                                    "away": away, "home": home,
                                    "away_score": away_score, "home_score": home_score,
                                })
                        all_today[sport][league_slug] = league_events
                except Exception:
                    all_today[sport][league_slug] = []
        
        def normalize_name(name: str) -> str:
            """Quita acentos, caracteres especiales, espacios"""
            name = ''.join(c for c in __import__('unicodedata').normalize('NFD', name)
                          if __import__('unicodedata').category(c) != 'Mn')
            name = re_mod.sub(r'[^a-z0-9\s]', '', name.lower().strip())
            return name
        
        def find_match(partido, deporte, all_today_events):
            """Busca match según deporte. Soccer usa 'vs', otros usan '@'"""
            if deporte.lower() == "soccer":
                partido_clean = partido.replace("@", " vs ").lower().strip()
                sep = " vs "
            else:
                partido_clean = partido.replace(" vs ", "@").lower().strip()
                sep = "@"
            
            if sep not in partido_clean:
                return (False, -1, -1)
            
            try:
                parts = partido_clean.split(sep)
                away_guardado = parts[0].strip()
                home_guardado = parts[1].strip()
            except:
                return (False, -1, -1)
            
            away_norm = normalize_name(away_guardado)
            home_norm = normalize_name(home_guardado)
            
            for sport_key, leagues_dict in all_today_events.items():
                for league_slug, events_list in leagues_dict.items():
                    for event in events_list:
                        away_espn = event.get('away', '?')
                        home_espn = event.get('home', '?')
                        
                        away_espn_norm = normalize_name(away_espn)
                        home_espn_norm = normalize_name(home_espn)
                        
                        if away_norm == away_espn_norm and home_norm == home_espn_norm:
                            home_score = event.get("home_score", -1)
                            away_score = event.get("away_score", -1)
                            return (True, home_score, away_score)
                        
                        if (away_norm in away_espn_norm or away_espn_norm in away_norm) and \
                           (home_norm in home_espn_norm or home_espn_norm in home_norm):
                            home_score = event.get("home_score", -1)
                            away_score = event.get("away_score", -1)
                            if home_score != -1 and away_score != -1:
                                return (True, home_score, away_score)
            
            return (False, -1, -1)
        
        for idx, row in pending.iterrows():
            resultado_actual = str(row.get("resultado", "")).lower().strip()
            if resultado_actual not in ["pendiente", "nulo", ""]:
                continue
            
            partido = str(row.get("partido", ""))
            deporte = str(row.get("deporte", "soccer")).lower()
            
            if not partido or ("@" not in partido and " vs " not in partido):
                continue
            
            found, home_score, away_score = find_match(partido, deporte, all_today)
            
            if not found or home_score == -1 or away_score == -1:
                continue
            
            pick_desc = str(row.get("pick_desc", ""))
            momio = float(row.get("momio", 1.0)) if row.get("momio") else 1.0
            apuesta = float(row.get("apuesta", 0)) if row.get("apuesta") else 0
            
            if home_score > away_score:
                ganador = "Home"
            elif away_score > home_score:
                ganador = "Away"
            else:
                ganador = "Tie"
            
            resultado = ""
            ganancia = 0
            
            if "Home" in pick_desc and ganador == "Home":
                resultado = "ganado"
                ganancia = round(apuesta * (momio - 1), 2)
            elif "Away" in pick_desc and ganador == "Away":
                resultado = "ganado"
                ganancia = round(apuesta * (momio - 1), 2)
            elif ganador == "Tie":
                resultado = "nulo"
                ganancia = 0
            else:
                resultado = "perdido"
                ganancia = -apuesta
            
            new_bank = round(current_bank + ganancia, 2)
            try:
                update_pick_row(apodo, idx, resultado, ganancia, new_bank)
            except:
                pass
            
            df.at[idx, "resultado"] = resultado
            df.at[idx, "ganancia_neta"] = ganancia
            df.at[idx, "bankroll_post"] = new_bank
            current_bank = new_bank
            graded += 1
        
        return df, graded, current_bank
    
    except Exception:
        return df, 0, bank



# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────
def get_bankroll(df: pd.DataFrame) -> float:
    resolved = df[df["resultado"] != "pendiente"]
    if resolved.empty:
        return START_BANK
    last = resolved.sort_values("fecha").iloc[-1]
    v = float(last["bankroll_post"])
    return v if v > 0 else START_BANK

def get_rango(bank: float) -> dict:
    for r in RANGOS:
        if r["min"] <= bank < r["max"]: return r
    return RANGOS[-1]

def kelly(momio: float, wr: float = 0.55) -> float:
    if momio <= 1: return 0
    b = momio - 1
    k = (b * wr - (1 - wr)) / b
    return max(0, min(k * 0.25, 0.05))

def racha_html(results: list) -> str:
    icons = {"ganado": "✓", "perdido": "✗", "nulo": "−", "pendiente": "·"}
    clses = {"ganado": "g", "perdido": "p", "nulo": "n", "pendiente": "n"}
    dots  = "".join(
        '<div class="racha-dot {}">{}</div>'.format(clses.get(r, "n"), icons.get(r, "·"))
        for r in results[-15:]
    )
    return f'<div class="racha-row">{dots}</div>'

def confetti_html() -> str:
    colors = ["#F0FF00","#FFB800","#00FF88","#BF5FFF","#00B4FF","#FF3D00"]
    pieces = ""
    for _ in range(70):
        c = random.choice(colors)
        l = random.randint(0, 100)
        d = random.uniform(0, 1.8)
        w = random.randint(6, 12)
        h = random.randint(6, 12)
        pieces += f'<div class="confetti-piece" style="left:{l}%;width:{w}px;height:{h}px;background:{c};animation-delay:{d:.2f}s"></div>'
    return pieces


# ─────────────────────────────────────────────────────────────
#  RENDER: LOGIN
# ─────────────────────────────────────────────────────────────
def render_login():
    st.markdown("""
<div style="text-align:center;padding:70px 20px 30px">
  <div style="font-family:'JetBrains Mono',monospace;font-size:.6rem;letter-spacing:6px;
       color:rgba(240,255,0,.5);text-transform:uppercase;margin-bottom:16px">◈ SISTEMA ACTIVO ◈</div>
  <div style="font-family:'Bebas Neue',sans-serif;font-size:5.5rem;line-height:.9;
       background:linear-gradient(135deg,#FF3D00 0%,#FFB800 50%,#F0FF00 100%);
       -webkit-background-clip:text;-webkit-text-fill-color:transparent;
       filter:drop-shadow(0 0 30px rgba(255,184,0,.4));letter-spacing:6px">
    RETO<br>13M
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.55rem;color:rgba(255,255,255,.2);
       letter-spacing:8px;text-transform:uppercase;margin:12px 0 28px">APOSTADOR ▸ GRADUADO</div>
  <div style="display:inline-flex;gap:36px;margin-bottom:36px;padding:16px 32px;
       background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.07);border-radius:14px">
    <div style="text-align:center">
      <div style="font-family:'Bebas Neue',sans-serif;font-size:1.8rem;color:#F0FF00;
           text-shadow:0 0 16px rgba(240,255,0,.5)">$1,500</div>
      <div style="font-size:.5rem;color:rgba(255,255,255,.3);font-family:'JetBrains Mono',monospace;letter-spacing:2px">INICIO</div>
    </div>
    <div style="display:flex;align-items:center;color:rgba(255,255,255,.2);font-size:1.4rem;font-family:'Bebas Neue',sans-serif">▶</div>
    <div style="text-align:center">
      <div style="font-family:'Bebas Neue',sans-serif;font-size:1.8rem;color:#00FFD1;
           text-shadow:0 0 16px rgba(0,255,209,.5)">$13M</div>
      <div style="font-size:.5rem;color:rgba(255,255,255,.3);font-family:'JetBrains Mono',monospace;letter-spacing:2px">META</div>
    </div>
  </div>
</div>
""", unsafe_allow_html=True)

    # Load existing users from Sheet
    existing_users = []
    # Load users — cache in session_state to survive gspread hiccups
    if "login_users" not in st.session_state:
        try:
            users_data = load_users()
            st.session_state["login_users"] = [
                u["apodo"] for u in users_data if u.get("apodo","").strip()
            ]
        except Exception:
            st.session_state["login_users"] = []
    existing_users = st.session_state.get("login_users", [])

    col = st.columns([1, 2, 1])[1]
    with col:
        if existing_users:
            # Mode toggle
            mode = st.radio(
                "",
                ["👤 Soy usuario existente", "➕ Soy nuevo"],
                horizontal=True,
                label_visibility="collapsed",
                key="login_mode"
            )

            if mode == "👤 Soy usuario existente":
                sel = st.selectbox(
                    "",
                    options=existing_users,
                    label_visibility="collapsed",
                    key="login_select"
                )
                if st.button("⚡ ENTRAR AL RETO", type="primary", key="btn_login_existing"):
                    st.session_state["apodo"] = sel
                    st.session_state.pop("login_users", None)
                    st.rerun()
            else:
                # JS to disable autocomplete
                st.markdown("""
<script>
setTimeout(function(){
  var inp = document.querySelectorAll('input[type="text"], input:not([type])');
  inp.forEach(function(el){ el.setAttribute('autocomplete','off'); el.setAttribute('autocomplete','new-password'); });
},300);
</script>""", unsafe_allow_html=True)
                nuevo = st.text_input(
                    "", placeholder="Elige tu apodo",
                    label_visibility="collapsed", key="login_nuevo"
                )
                if st.button("⚡ CREAR Y ENTRAR", type="primary", key="btn_login_new"):
                    if nuevo.strip():
                        st.session_state["apodo"] = nuevo.strip()
                        st.session_state.pop("login_users", None)
                        st.rerun()
                    else:
                        st.error("Escribe tu apodo")
        else:
            # No users yet — just text input
            st.markdown("""
<script>
setTimeout(function(){
  var inp = document.querySelectorAll('input');
  inp.forEach(function(el){ el.setAttribute('autocomplete','new-password'); });
},300);
</script>""", unsafe_allow_html=True)
            apodo = st.text_input(
                "", placeholder="Elige tu apodo para el Reto",
                label_visibility="collapsed", key="login_first"
            )
            if st.button("⚡ ENTRAR AL RETO", type="primary", key="btn_login_first"):
                if apodo.strip():
                    st.session_state["apodo"] = apodo.strip()
                    st.session_state.pop("login_users", None)
                    st.rerun()
                else:
                    st.error("Escribe tu apodo")


# ─────────────────────────────────────────────────────────────
#  RENDER: HEADER
# ─────────────────────────────────────────────────────────────
def render_header(apodo: str, bank: float):
    rango = get_rango(bank)
    pct   = min(100, bank / RETO_GOAL * 100)

    milestones = [50_000, 200_000, 500_000, 1_500_000, 5_000_000, 13_000_000]
    ms_dots    = ""
    for ms in milestones:
        reached = bank >= ms
        if ms >= 1_000_000:
            label = f"${ms//1_000_000}M"
        else:
            label = f"${ms//1_000}K"
        ms_dots += (
            f'<div class="ms-dot">'
            f'<div class="ms-circle {"reached" if reached else ""}"></div>'
            f'<div class="ms-label">{label}</div>'
            f'</div>'
        )

    st.markdown(f"""
<div class="card card-gold" style="margin-top:16px;position:relative;overflow:hidden">
  <div style="position:absolute;inset:0;pointer-events:none;
       background-image:linear-gradient(rgba(255,184,0,.025) 1px,transparent 1px),
       linear-gradient(90deg,rgba(255,184,0,.025) 1px,transparent 1px);
       background-size:28px 28px;border-radius:16px"></div>
  <div style="display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:10px;position:relative">
    <div>
      <div class="hero-label">💰 BANKROLL ACTUAL</div>
      <div class="hero-bank">${bank:,.2f}</div>
      <div class="hero-meta">META → $13,000,000 MXN</div>
    </div>
    <div style="text-align:right">
      <span class="rang-badge" style="background:{rango['color']}18;border:1px solid {rango['color']}55;color:{rango['color']};box-shadow:0 0 14px {rango['color']}25">
        {rango['icon']} {rango['nombre']}
      </span>
      <div style="font-family:'JetBrains Mono',monospace;font-size:.62rem;color:#8888AA;margin-top:6px">
        APOSTADOR: <span style="color:var(--neon)">{apodo.upper()}</span>
      </div>
    </div>
  </div>
  <div class="prog-wrap" style="position:relative">
    <div class="prog-fill" style="width:{pct:.4f}%"></div>
  </div>
  <div style="display:flex;justify-content:space-between;position:relative">
    <span style="font-family:'JetBrains Mono',monospace;font-size:.52rem;color:var(--text3)">{pct:.4f}% COMPLETADO</span>
    <span style="font-family:'JetBrains Mono',monospace;font-size:.52rem;color:var(--text3)">${RETO_GOAL-bank:,.0f} RESTANTES</span>
  </div>
  <div class="ms-row" style="position:relative">{ms_dots}</div>
</div>
""", unsafe_allow_html=True)

    st.sidebar.markdown(f"### 👤 {apodo}")
    if st.sidebar.button("🚪 Cambiar usuario"):
        del st.session_state["apodo"]
        st.rerun()


# ─────────────────────────────────────────────────────────────
#  ALL TODAY — Load all games across all sports
# ─────────────────────────────────────────────────────────────

# All leagues to scan for "today" view — ordered by sport
ALL_TODAY_LEAGUES = [
    # Soccer clubs
    ("⚽ Fútbol — Clubes", "Premier League",      "soccer", "eng.1"),
    ("⚽ Fútbol — Clubes", "La Liga",              "soccer", "esp.1"),
    ("⚽ Fútbol — Clubes", "Serie A",              "soccer", "ita.1"),
    ("⚽ Fútbol — Clubes", "Bundesliga",           "soccer", "ger.1"),
    ("⚽ Fútbol — Clubes", "Ligue 1",              "soccer", "fra.1"),
    ("⚽ Fútbol — Clubes", "Liga MX",              "soccer", "mex.1"),
    ("⚽ Fútbol — Clubes", "MLS",                  "soccer", "usa.1"),
    ("⚽ Fútbol — Clubes", "Champions League",     "soccer", "uefa.champions"),
    ("⚽ Fútbol — Clubes", "Europa League",        "soccer", "uefa.europa"),
    ("⚽ Fútbol — Clubes", "Copa Libertadores",    "soccer", "conmebol.libertadores"),
    ("⚽ Fútbol — Clubes", "Brasileirão",          "soccer", "bra.1"),
    ("⚽ Fútbol — Clubes", "Eredivisie",           "soccer", "ned.1"),
    ("⚽ Fútbol — Clubes", "Liga Portugal",        "soccer", "por.1"),
    ("⚽ Fútbol — Clubes", "Superliga Argentina",  "soccer", "arg.1"),
    # Soccer selecciones — try multiple slugs for UEFA playoffs
    ("🌍 Fútbol — Selecciones", "Playoffs UEFA WC2026",   "soccer", "fifa.worldq.uefa"),
    ("🌍 Fútbol — Selecciones", "Eliminatorias UEFA",     "soccer", "fifa.worldq.6"),
    ("🌍 Fútbol — Selecciones", "Eliminatorias CONMEBOL", "soccer", "fifa.worldq.2"),
    ("🌍 Fútbol — Selecciones", "Eliminatorias CONCACAF", "soccer", "fifa.worldq.5"),
    ("🌍 Fútbol — Selecciones", "Nations League UEFA",    "soccer", "uefa.nations"),
    ("🌍 Fútbol — Selecciones", "Amistosos Internac.",    "soccer", "fifa.friendly"),
    ("🌍 Fútbol — Selecciones", "Apostar",                 "soccer", "fifa.worldq"),
    # Basketball
    ("🏀 Basketball", "NBA",  "basketball", "nba"),
    # Baseball
    ("⚾ Baseball",   "MLB",  "baseball",   "mlb"),
    # Hockey
    ("🏒 Hockey",     "NHL",  "hockey",     "nhl"),
    # Tennis — atp and wta cover all active tournaments including Miami Open
]

@st.cache_data(ttl=1800, show_spinner=False)
def load_all_today() -> dict:
    """
    Fetch all games happening today and tomorrow only (Mexico City time, UTC-6).
    Returns dict: {sport_group: {liga: [events]}}
    Cached 30 min to avoid hammering ESPN.
    """
    # Always use Mexico City time (UTC-6) — Streamlit Cloud runs in UTC
    now_mx    = datetime.utcnow() - timedelta(hours=6)
    today     = now_mx.date()
    tomorrow  = today + timedelta(days=1)
    # Cutoff: nothing after end of tomorrow in MX time (= end of tomorrow UTC+0 = 06:00 UTC day after tomorrow)
    cutoff_mx = datetime(tomorrow.year, tomorrow.month, tomorrow.day, 23, 59, 59)
    # Convert cutoff back to UTC for comparison with ESPN dates
    cutoff_utc = cutoff_mx + timedelta(hours=6)

    today_str    = today.strftime("%Y%m%d")
    tomorrow_str = tomorrow.strftime("%Y%m%d")
    result   = {}
    seen_ids = set()

    for sport_group, liga_name, sport, league_slug in ALL_TODAY_LEAGUES:
        try:
            url = f"{ESPN_BASE}/{sport}/{league_slug}/scoreboard"
            events_found = []

            date_params = [today_str, tomorrow_str]

            for dt_str in date_params:
                params = {"limit": 200, "dates": dt_str}
                r = requests.get(url, params=params, timeout=8)
                if r.status_code != 200:
                    continue
                for ev in r.json().get("events", []):
                    eid = ev.get("id","")
                    if eid in seen_ids:
                        continue
                    st_type   = ev.get("status",{}).get("type",{})
                    state     = st_type.get("state","pre")
                    completed = (state == "post") or st_type.get("completed", False)
                    if completed:
                        continue
                    # Strict date filter — skip anything after end of tomorrow (MX time)
                    date_raw = ev.get("date","")
                    try:
                        dt_ev = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                        dt_ev_utc = dt_ev.replace(tzinfo=None)  # ESPN dates are UTC
                        if dt_ev_utc > cutoff_utc:
                            continue
                        dt_mx = dt_ev - timedelta(hours=6)
                        d_str = dt_mx.strftime("%d %b %H:%M")
                    except Exception:
                        d_str = date_raw[:10]
                    comp0 = ev.get("competitions",[{}])[0]
                    comps = comp0.get("competitors",[])
                    home_c = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                    away_c = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                    home_i = _extract_competitor_info(home_c, sport)
                    away_i = _extract_competitor_info(away_c, sport)
                    is_live = (state == "in") and not completed
                    # Skip if both names TBD/unknown
                    if home_i["name"] in ("?","TBD","") and away_i["name"] in ("?","TBD",""):
                        continue
                    # For tennis: also skip if EITHER player is TBD (unconfirmed matchup)
                    if sport == "tennis":
                        if home_i["name"] in ("?","TBD","") or away_i["name"] in ("?","TBD",""):
                            continue
                    # For tennis, extract tournament name from event name
                    display_liga = liga_name
                    if sport == "tennis":
                        ev_name = ev.get("name", "")
                        # ESPN tennis event name format: "Player A vs Player B"
                        # Tournament is in the league/season node
                        league_node = ev.get("league", {})
                        if not league_node:
                            league_node = ev.get("competitions",[{}])[0].get("league",{})
                        tournament = league_node.get("name","") or league_node.get("abbreviation","")
                        if tournament and tournament.upper() not in ["ATP","WTA"]:
                            display_liga = tournament
                        # Also try season
                        season = ev.get("season",{}).get("type",{}).get("name","")
                        if not tournament and season:
                            display_liga = f"{liga_name.split()[0]} — {season}"

                    events_found.append({
                        "id": eid, "home": home_i["name"], "away": away_i["name"],
                        "home_logo": home_i["logo"], "away_logo": away_i["logo"],
                        "home_flag": home_i["flag"], "away_flag": away_i["flag"],
                        "date": d_str, "date_raw": date_raw,
                        "is_live": is_live, "completed": completed,
                        "sport": sport, "liga": display_liga,
                        "status_state": state,
                        "home_score": home_i["score"], "away_score": away_i["score"],
                        "home_odds": 0.0, "away_odds": 0.0, "draw_odds": 0.0,
                    })
                    seen_ids.add(eid)

            if events_found:
                events_found.sort(key=lambda e: e["date_raw"])
                if sport_group not in result:
                    result[sport_group] = {}
                # Group tennis by tournament name
                if sport == "tennis":
                    for ev in events_found:
                        t_name = ev.get("liga", liga_name)
                        if t_name not in result[sport_group]:
                            result[sport_group][t_name] = []
                        result[sport_group][t_name].append(ev)
                else:
                    result[sport_group][liga_name] = events_found

        except Exception:
            continue

    # Merge Odds API momios into ESPN events + add any extras not in ESPN
    try:
        intl_events = []
        seen_intl = set()
        for sk in WC_QUALIFIER_KEYS:
            try:
                evs = odds_fetch_sport(sk)
                for e in evs:
                    if e["id"] not in seen_intl:
                        intl_events.append(e)
                        seen_intl.add(e["id"])
            except Exception:
                continue

        if intl_events:
            # Build name lookup for all ESPN events already in result
            def normalize(s: str) -> str:
                return s.lower().strip().replace("  "," ")

            # Inject odds into matching ESPN events by team name
            for grp_key, ligas_dict in result.items():
                for liga_key, evs_list in ligas_dict.items():
                    for ev in evs_list:
                        if ev.get("home_odds", 0) > 0:
                            continue  # already has odds
                        for odds_ev in intl_events:
                            h_match = normalize(ev["home"])[:6] in normalize(odds_ev["home"])
                            a_match = normalize(ev["away"])[:6] in normalize(odds_ev["away"])
                            if h_match and a_match:
                                ev["home_odds"] = odds_ev.get("home_odds", 0)
                                ev["away_odds"] = odds_ev.get("away_odds", 0)
                                ev["draw_odds"] = odds_ev.get("draw_odds", 0)
                                break

            # Add Odds API events NOT already in ESPN (by name match)
            all_espn_names = set()
            for ligas_dict in result.values():
                for evs_list in ligas_dict.values():
                    for ev in evs_list:
                        all_espn_names.add(normalize(ev["home"])[:6] + normalize(ev["away"])[:6])

            new_evs = []
            for e in intl_events:
                key = normalize(e["home"])[:6] + normalize(e["away"])[:6]
                if key not in all_espn_names:
                    new_evs.append(e)

            if new_evs:
                grp  = "🌍 Fútbol — Selecciones"
                liga = "Otros Internacionales"
                if grp not in result:
                    result[grp] = {}
                result[grp][liga] = sorted(new_evs, key=lambda e: e["date_raw"])
    except Exception:
        pass

    return result


def render_all_today(apodo: str):
    """Render all today's games grouped by sport → league → time."""

    st.markdown(
        '<div class="sec-head">📅 Todos los partidos de hoy y mañana</div>',
        unsafe_allow_html=True
    )

    # Load / refresh button
    col_r = st.columns([8,1])[1]
    with col_r:
        if st.button("🔄", key="all_today_refresh", help="Actualizar partidos"):
            load_all_today.clear()
            st.session_state.pop("all_today_data", None)
            st.rerun()

    # Cache in session_state so it doesn't reload on every click
    if "all_today_data" not in st.session_state:
        with st.spinner("⚡ Cargando partidos de todos los deportes…"):
            st.session_state["all_today_data"] = load_all_today()
    data = st.session_state["all_today_data"]

    if not data:
        st.info("No se encontraron partidos para hoy/mañana.")
        return

    total_games = sum(len(evs) for ligas in data.values() for evs in ligas.values())
    st.markdown(
        f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.6rem;'
        f'color:var(--text3);margin-bottom:16px">'
        f'{total_games} PARTIDOS ENCONTRADOS</div>',
        unsafe_allow_html=True
    )

    selected = st.session_state.get("selected_event", None)

    for sport_group, ligas in data.items():
        total_in_group = sum(len(evs) for evs in ligas.values())
        label = f"{sport_group}  ·  {total_in_group} partidos"
        with st.expander(label, expanded=True):
            for liga_name, events in ligas.items():
                # League as nested expander — collapsed by default if many
                with st.expander(f"▸ {liga_name}  ·  {len(events)} partidos", expanded=len(events) <= 6):
                    is_tennis = events[0].get("sport") == "tennis" if events else False
                    brad      = "50%" if is_tennis else "8px"

                    for row_start in range(0, len(events), 3):
                        row_evs = events[row_start:row_start+3]
                        cols    = st.columns(3)
                        for col_idx in range(3):
                            with cols[col_idx]:
                                if col_idx >= len(row_evs):
                                    st.empty(); continue
                                ev      = row_evs[col_idx]
                                is_live = ev.get("is_live", False)
                                is_sel  = selected and selected.get("id") == ev["id"]
                                away    = ev["away"]; home = ev["home"]
                                sport   = ev.get("sport", "soccer")  # ← AGREGADO
                                # Formatear según deporte
                                formatted = format_partido_para_display(f"{away}@{home}", sport)
                                if sport.lower() == "soccer":
                                    # Soccer: formatted devuelve "Home vs Away"
                                    parts = formatted.split(" vs ")
                                    home_disp, away_disp = parts[0], parts[1]  # ← INVERTIR
                                else:
                                    # NBA/etc: "Away@Home"
                                    away_disp, home_disp = formatted.split("@")
                                s_txt   = "● LIVE" if is_live else ev["date"]
                                s_col   = "#FF3D00" if is_live else "#00FFD1"
                                border  = "rgba(240,255,0,.6)" if is_sel else ("rgba(255,61,0,.4)" if is_live else "rgba(255,255,255,.09)")
                                bg      = "rgba(240,255,0,.05)" if is_sel else "rgba(255,255,255,.02)"
                                a_lg    = mk_logo(ev.get("away_logo",""), ev.get("away_flag",""), away, 36, brad)
                                h_lg    = mk_logo(ev.get("home_logo",""), ev.get("home_flag",""), home, 36, brad)

                                # Odds badges
                                odds_html = ""
                                if ev.get("home_odds",0) > 1:
                                    odds_html = (
                                        f'<div style="display:flex;gap:4px;justify-content:center;'
                                        f'margin-top:4px;font-family:\'JetBrains Mono\',monospace;font-size:.5rem">'
                                        f'<span style="background:rgba(0,255,136,.12);color:#00FF88;'
                                        f'padding:1px 5px;border-radius:4px">{ev["away_odds"]}</span>'
                                    )
                                    if ev.get("draw_odds",0) > 1:
                                        odds_html += (
                                            f'<span style="background:rgba(255,184,0,.12);color:#FFB800;'
                                            f'padding:1px 5px;border-radius:4px">{ev["draw_odds"]}</span>'
                                        )
                                    odds_html += (
                                        f'<span style="background:rgba(0,180,255,.12);color:#00B4FF;'
                                        f'padding:1px 5px;border-radius:4px">{ev["home_odds"]}</span>'
                                        f'</div>'
                                    )

                                # Para soccer, invertir visual para que Home esté a la izquierda
                                if sport.lower() == "soccer":
                                    # Soccer: mostrar Home@Away visualmente (local@visitante)
                                    logo_left, logo_right = h_lg, a_lg
                                    team_left, team_right = home_disp, away_disp
                                else:
                                    # NBA/etc: mostrar Away@Home visualmente (visitante@local)
                                    logo_left, logo_right = a_lg, h_lg
                                    team_left, team_right = away_disp, home_disp

                                # Build score text if live
                                score_text = ""
                                if is_live and ev.get("away_score") is not None and ev.get("home_score") is not None:
                                    away_score = ev.get("away_score", "")
                                    home_score = ev.get("home_score", "")
                                    score_text = f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.65rem;font-weight:700;color:#FFD700;margin-top:2px">{away_score} - {home_score}</div>'
                                
                                st.markdown(
                                    f'<div style="background:{bg};border:1px solid {border};'
                                    f'border-radius:12px;padding:10px 8px;text-align:center">'
                                    f'<div style="display:flex;align-items:center;justify-content:center;'
                                    f'gap:5px;margin-bottom:5px">'
                                    f'<div style="display:flex;flex-direction:column;align-items:center;gap:2px;flex:1">'
                                    f'{logo_left}<div style="font-size:.58rem;font-weight:700;color:#EEEEF5;'
                                    f'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:80px">'
                                    f'{team_left}</div></div>'
                                    f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.7rem;color:#44445A">VS</div>'
                                    f'<div style="display:flex;flex-direction:column;align-items:center;gap:2px;flex:1">'
                                    f'{logo_right}<div style="font-size:.58rem;font-weight:700;color:#EEEEF5;'
                                    f'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:80px">'
                                    f'{team_right}</div></div></div>'
                                    f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.48rem;'
                                    f'color:{s_col}">{s_txt}</div>'
                                    f'{score_text}'
                                    f'{odds_html}</div>',
                                    unsafe_allow_html=True
                                )
                                lbl = "⚡ SELECCIONADO" if is_sel else "✔ Seleccionar"
                                if st.button(lbl, key=f"at_{ev['id'][:12]}", type="primary" if is_sel else "secondary"):
                                    st.session_state["selected_event"] = ev
                                    st.rerun()


# ─────────────────────────────────────────────────────────────
#  SHARED UI HELPERS
# ─────────────────────────────────────────────────────────────
def mk_logo(url: str, flag: str, name: str, sz: int = 40, brad: str = "8px") -> str:
    """Return HTML img tag with initials fallback for team/player logos."""
    src      = url or flag
    initials = (name[:2] if len(name) >= 2 else name).upper()
    if src:
        return (
            f'<img src="{src}" style="width:{sz}px;height:{sz}px;object-fit:contain;'
            f'border-radius:{brad};background:rgba(255,255,255,.04);'
            f'border:1px solid rgba(255,255,255,.08)" '
            f'onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'flex\'">'
            f'<div style="display:none;width:{sz}px;height:{sz}px;border-radius:{brad};'
            f'background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1);'
            f'align-items:center;justify-content:center;font-family:\'Bebas Neue\',sans-serif;'
            f'font-size:{sz//2}px;color:#8888AA">{initials}</div>'
        )
    return (
        f'<div style="width:{sz}px;height:{sz}px;border-radius:{brad};'
        f'background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1);'
        f'display:flex;align-items:center;justify-content:center;'
        f'font-family:\'Bebas Neue\',sans-serif;font-size:{sz//2}px;color:#8888AA">{initials}</div>'
    )


# ─────────────────────────────────────────────────────────────
#  TAB 1 — REGISTRAR PICK
# ─────────────────────────────────────────────────────────────
def tab_registrar(apodo: str, df: pd.DataFrame, bank: float):

    SPORT_TABS = {
        "🌐 Todos": "__all_today__",
        "⚽ Soccer": "soccer",
        "🏀 NBA":    "basketball",
        "⚾ MLB":    "baseball",
        "🏒 NHL":    "hockey",
        "🏈 NFL":    "football",
    }
    SPORT_ICONS = {"soccer":"⚽","basketball":"🏀","baseball":"⚾","hockey":"🏒","football":"🏈"}

    # ── Top sport filter tabs ─────────────────────────────────
    tab_names = list(SPORT_TABS.keys())
    active_sport = st.session_state.get("reg_sport_tab", "🌐 Todos")

    cols = st.columns(len(tab_names))
    for i, tname in enumerate(tab_names):
        with cols[i]:
            is_active = (active_sport == tname)
            if st.button(tname,
                         key=f"sporttab_{i}",
                         type="primary" if is_active else "secondary",
                         use_container_width=True):
                st.session_state["reg_sport_tab"] = tname
                st.session_state.pop("search_events", None)
                st.session_state.pop("selected_event", None)
                st.session_state.pop("reg_query", None)
                st.rerun()

    active_sport = st.session_state.get("reg_sport_tab", "🌐 Todos")
    sport_key = SPORT_TABS[active_sport]

    # ── Search bar (optional filter) ─────────────────────────
    query = st.text_input("🔍 Filtrar equipo...", placeholder="ej: Lakers, Italy, Yankees",
                          key="reg_query", label_visibility="collapsed")

    # ── Load events ──────────────────────────────────────────
    @st.cache_data(ttl=1800, show_spinner=False)
    def _get_today_by_sport(sport_filter: str) -> list:
        """Get today's events for a specific sport from load_all_today cache."""
        data = load_all_today()
        events = []
        for grp, ligas in data.items():
            for liga_name, evs in ligas.items():
                for ev in evs:
                    sp = ev.get("sport","")
                    if sport_filter == "__all_today__" or sp == sport_filter:
                        ev_copy = dict(ev)
                        ev_copy["_liga_label"] = liga_name
                        events.append(ev_copy)
        events.sort(key=lambda e: (e.get("sport",""), e.get("date_raw","")))
        return events

    with st.spinner("Cargando partidos..."):
        all_evs = _get_today_by_sport(sport_key)

    # Filter by query
    if query.strip():
        q = query.strip().lower()
        all_evs = [e for e in all_evs
                   if q in e["home"].lower() or q in e["away"].lower()]

    if not all_evs:
        st.info("No hay partidos disponibles. Intenta con otro deporte o actualiza con 🔄")
        return

    # Count + header
    now_mx_hdr = datetime.utcnow() - timedelta(hours=6)
    today_mx   = now_mx_hdr.date()
    tomorrow_mx = today_mx + timedelta(days=1)
    st.markdown(
        f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.55rem;'
        f'color:var(--text3);margin:4px 0 8px">'
        f'{len(all_evs)} PARTIDOS  ·  '
        f'Hoy {today_mx.strftime("%d %b")} + Mañana {tomorrow_mx.strftime("%d %b")} '
        f'(hora CDMX)</div>',
        unsafe_allow_html=True
    )
    
    # ═══════════════════════════════════════════════════════════════
    # 🔍 DEBUG PANEL - Ver qué datos recibe ESPN
    # ═══════════════════════════════════════════════════════════════
    with st.expander("🔍 DEBUG: Datos de ESPN (para troubleshooting)", expanded=True):
        if all_evs:
            # Mostrar primeros 10 partidos con TODOS sus datos
            st.write(f"**Total: {len(all_evs)} partidos. Mostrando primeros 10:**")
            for i, ev in enumerate(all_evs[:10]):
                with st.expander(f"Partido {i+1}: {ev.get('away', '?')} vs {ev.get('home', '?')} - Score: {ev.get('away_score', '?')} - {ev.get('home_score', '?')} - Live: {ev.get('is_live', False)}"):
                    col1, col2 = st.columns(2)
                    with col1:
                        st.write("**Básico:**")
                        st.write(f"- id: {ev.get('id', '?')}")
                        st.write(f"- name: {ev.get('name', '?')}")
                        st.write(f"- sport: {ev.get('sport', '?')}")
                        st.write(f"- is_live: {ev.get('is_live', False)}")
                        st.write(f"- status_state: {ev.get('status_state', '?')}")
                        st.write(f"- status_detail: {ev.get('status_detail', '?')}")
                    with col2:
                        st.write("**Score:**")
                        st.write(f"- away_score: '{ev.get('away_score', '?')}' (tipo: {type(ev.get('away_score')).__name__})")
                        st.write(f"- home_score: '{ev.get('home_score', '?')}' (tipo: {type(ev.get('home_score')).__name__})")
                        st.write(f"- away: {ev.get('away', '?')}")
                        st.write(f"- home: {ev.get('home', '?')}")
                        st.write(f"- date: {ev.get('date', '?')}")
                        st.write(f"- completed: {ev.get('completed', False)}")

    # ── Group by liga ─────────────────────────────────────────
    from collections import defaultdict
    by_liga = defaultdict(list)
    for ev in all_evs:
        liga_lbl = ev.get("_liga_label", ev.get("liga",""))
        if not liga_lbl or "cargar" in liga_lbl.lower():
            sp = ev.get("sport","")
            liga_lbl = {"soccer":"⚽ Fútbol","basketball":"🏀 NBA",
                        "baseball":"⚾ MLB","hockey":"🏒 NHL","football":"🏈 NFL"}.get(sp, sp.upper())
        by_liga[liga_lbl].append(ev)

    # 🔍 DEBUG: Estadísticas generales
    st.write(f"**📊 Total de partidos cargados: {len(all_evs)}**")
    st.write(f"**⚡ Partidos EN VIVO (detectados por hora): {len([e for e in all_evs if e.get('is_live', False)])}**")
    with st.expander("📈 Breakdown por liga:"):
        for liga_lbl in sorted(by_liga.keys()):
            count = len(by_liga[liga_lbl])
            live = len([e for e in by_liga[liga_lbl] if e.get('is_live', False)])
            st.write(f"- {liga_lbl}: {count} partidos ({live} EN VIVO)")

    # Any open pick form?
    open_ids = {ev["id"] for ev in all_evs
                if st.session_state.get(f"qp_val_{ev['id']}") or
                   st.session_state.get(f"ou_pending_{ev['id'][:10]}")}

    FRIENDLY_LIMIT = 50  # Mostrar TODOS los amistosos

    for liga_lbl, liga_evs in sorted(by_liga.items(), key=lambda x: -len([e for e in x[1] if e.get("is_live")])):
        # Cap friendlies
        is_friendly = any(w in liga_lbl.lower() for w in ["amistoso","friendly","internac"])
        display_evs = liga_evs[:FRIENDLY_LIMIT] if is_friendly else liga_evs
        n = len(display_evs)
        n_total = len(liga_evs)
        label = f"{liga_lbl}  ·  {n} partidos" + (f"  (de {n_total})" if n_total > n else "")

        has_live   = any(e.get("is_live") for e in display_evs)
        has_open   = bool(open_ids & {e["id"] for e in display_evs})
        # Auto-expand: live games, open picks, or small leagues
        default_open = has_live or has_open or n <= 8

        with st.expander(label, expanded=default_open):
            cols_per_row = 3 if n > 12 else 2
            for row_start in range(0, len(display_evs), cols_per_row):
                row_evs = display_evs[row_start:row_start+cols_per_row]
                grid = st.columns(cols_per_row)
                for ci in range(cols_per_row):
                    with grid[ci]:
                        if ci >= len(row_evs):
                            continue
                        ev      = row_evs[ci]
                        ev_id    = ev["id"]
                        away     = ev["away"]; home = ev["home"]
                        sport_ev = ev.get("sport","soccer")
                        # Formatear según deporte
                        formatted = format_partido_para_display(f"{away}@{home}", sport_ev)
                        if sport_ev.lower() == "soccer":
                            parts = formatted.split(" vs ")
                            home_disp, away_disp = parts[0], parts[1]  # ✅ CORRECTO
                        else:
                            away_disp, home_disp = formatted.split("@")
                        s_txt = ev.get("date","")
                        is_live = ev.get("is_live", False)
                        away_score = ev.get("away_score", "")
                        home_score = ev.get("home_score", "")
                        
                        ao = float(ev.get("away_odds",0))
                        ho = float(ev.get("home_odds",0))
                        do = float(ev.get("draw_odds",0))
                        a_lg = mk_logo(ev.get("away_logo",""), ev.get("away_flag",""), away, 26, "6px")
                        h_lg = mk_logo(ev.get("home_logo",""), ev.get("home_flag",""), home, 26, "6px")
                        qv     = st.session_state.get(f"qp_val_{ev_id}", "")
                        ou_key = f"ou_pending_{ev_id[:10]}"
                        is_open = bool(qv) or bool(st.session_state.get(ou_key))
                        
                        # Estilos: EN VIVO rojo, abierto amarillo, normal gris
                        if is_live:
                            border  = "rgba(255,0,0,.8)"
                            bg      = "rgba(255,0,0,.15)"
                            border_width = "2px"
                            glow = "box-shadow: 0 0 20px rgba(255,0,0,.6);"
                            s_txt = "🔴 EN VIVO"
                            s_col = "#FF0000"
                        elif is_open:
                            border  = "rgba(240,255,0,.5)"
                            bg      = "rgba(240,255,0,.04)"
                            border_width = "1px"
                            glow = ""
                            s_col = "#FFD700"
                        else:
                            border  = "rgba(255,255,255,.06)"
                            bg      = "transparent"
                            border_width = "1px"
                            glow = ""
                            s_col = "#8888AA"
                        
                        # Mostrar score si existe
                        score_display = ""
                        if away_score and home_score:
                            try:
                                a_score = int(away_score)
                                h_score = int(home_score)
                                score_display = f"<br><span style='font-size:.5rem;color:#FFD700;'>{a_score} - {h_score}</span>"
                            except:
                                pass

                        odds_html = ""
                        if ao > 1:
                            odds_html = (f'<span style="background:rgba(0,255,136,.12);color:#00FF88;'
                                         f'padding:1px 6px;border-radius:4px;font-size:.58rem">{ao}</span> ')
                            if do > 1:
                                odds_html += (f'<span style="background:rgba(255,184,0,.12);color:#FFB800;'
                                              f'padding:1px 6px;border-radius:4px;font-size:.58rem">{do}</span> ')
                            odds_html += (f'<span style="background:rgba(0,180,255,.12);color:#00B4FF;'
                                          f'padding:1px 6px;border-radius:4px;font-size:.58rem">{ho}</span>')

                        # ✅ Para soccer: mostrar HOME a la izquierda, AWAY a la derecha
                        if sport_ev.lower() == "soccer":
                            logo_left, logo_right = h_lg, a_lg
                            team_left, team_right = home_disp, away_disp
                        else:
                            # NBA/etc: mostrar AWAY a la izquierda, HOME a la derecha
                            logo_left, logo_right = a_lg, h_lg
                            team_left, team_right = away_disp, home_disp
                        
                        with card_c:
                            st.markdown(
                                f'<div style="background:{bg};border:{border_width} solid {border};border-radius:10px;'
                                f'padding:8px 12px;display:flex;align-items:center;gap:8px;margin-bottom:2px;{glow}">'
                                f'<div style="display:flex;align-items:center;gap:5px;flex:1;min-width:0">'
                                f'{logo_left}'
                                f'<span style="font-size:.8rem;font-weight:700;color:#EEEEF5;'
                                f'white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{team_left}</span>'
                                f'</div>'
                                f'<div style="font-size:.55rem;color:#44445A;flex-shrink:0;text-align:center;padding:0 4px">'
                                f'vs<br><span style="font-size:.42rem;color:{s_col};font-weight:{"700" if is_live else "400"};'
                                f'{"animation:blinkLive 1s infinite;" if is_live else ""}">{s_txt}</span>'
                                f'{score_display}'
                                f'</div>'
                                f'<div style="display:flex;align-items:center;gap:5px;flex:1;min-width:0;justify-content:flex-end">'
                                f'<span style="font-size:.8rem;font-weight:700;color:#EEEEF5;'
                                f'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:right">{team_right}</span>'
                                f'{logo_right}'
                                f'</div>'
                                f'{"<div style=\\'margin-left:6px;flex-shrink:0\\'>" + odds_html + "</div>" if odds_html else ""}'
                                f'{"<div style=\\'margin-left:6px;font-size:.6rem;color:#F0FF00;flex-shrink:0\\'>" + qv + "</div>" if qv else ""}'
                                f'</div>',
                                unsafe_allow_html=True
                            )
                        with btn_c:
                            menu_open = st.session_state.get(f"open_pick_{ev_id[:10]}", False)
                            if st.button("APOSTAR", key=f"open_{ev_id[:10]}",
                                          use_container_width=True,
                                          type="primary" if menu_open else "secondary"):
                                st.session_state[f"open_pick_{ev_id[:10]}"] = not menu_open
                                st.rerun()

                # Pick panels — full width below each row
                for ci in range(min(cols_per_row, len(row_evs))):
                    ev       = row_evs[ci]
                    ev_id    = ev["id"]
                    away     = ev["away"]; home = ev["home"]
                    sport_ev = ev.get("sport","soccer")
                    ao = float(ev.get("away_odds",0))
                    ho = float(ev.get("home_odds",0))
                    do = float(ev.get("draw_odds",0))
                    ou_key = f"ou_pending_{ev_id[:10]}"
                    qv = st.session_state.get(f"qp_val_{ev_id}", "")
                    qm = st.session_state.get(f"qp_merc_{ev_id}", "ML")
                    open_flag = st.session_state.get(f"open_pick_{ev_id[:10]}", False)

                    if not qv and not st.session_state.get(ou_key) and not open_flag:
                        continue  # nothing to show for this event

                    if not qv and not st.session_state.get(ou_key):
                        # Show pick options
                        if sport_ev == "soccer":
                            picks = [(f"⚽ {away[:16]}", away, "ML"),
                                     ("➖ Empate", "Empate", "1X2"),
                                     (f"⚽ {home[:16]}", home, "ML"),
                                     ("📈 Over 2.5", "Over 2.5", "O/U"),
                                     ("📉 Under 2.5", "Under 2.5", "O/U"),
                                     ("⚽⚽ BTTS", "Ambos anotan", "BTTS")]
                        elif sport_ev == "basketball":
                            picks = [(f"🏀 {away[:16]}", away, "ML"),
                                     (f"🏀 {home[:16]}", home, "ML"),
                                     ("📈 Over pts", "Over", "O/U"),
                                     ("📉 Under pts", "Under", "O/U")]
                        elif sport_ev == "baseball":
                            picks = [(f"⚾ {away[:16]}", away, "ML"),
                                     (f"⚾ {home[:16]}", home, "ML"),
                                     ("📈 Over", "Over", "O/U"),
                                     ("📉 Under", "Under", "O/U")]
                        elif sport_ev == "hockey":
                            picks = [(f"🏒 {away[:16]}", away, "ML"),
                                     (f"🏒 {home[:16]}", home, "ML"),
                                     ("📈 Over 5.5", "Over 5.5", "O/U"),
                                     ("📉 Under 5.5", "Under 5.5", "O/U")]
                        else:
                            picks = [(f"🏆 {away[:18]}", away, "ML"),
                                     (f"🏆 {home[:18]}", home, "ML")]

                        n_picks = len(picks)
                        pc = st.columns(n_picks)
                        for pi, (col, (lbl, pval, pmerc)) in enumerate(zip(pc, picks)):
                            with col:
                                if st.button(lbl, key=f"pk_{ev_id[:10]}_{pi}",
                                              use_container_width=True):
                                    if pval in ("Over","Under"):
                                        st.session_state[ou_key] = pval
                                    else:
                                        st.session_state[f"qp_val_{ev_id}"]  = pval
                                        st.session_state[f"qp_merc_{ev_id}"] = pmerc
                                    st.rerun()

                    # Over/Under line input
                    if st.session_state.get(ou_key):
                        direction = st.session_state[ou_key]
                        def_line = 220.5 if sport_ev=="basketball" else 8.5 if sport_ev=="baseball" else 5.5
                        lc1, lc2, lc3 = st.columns([3,1,1])
                        with lc1:
                            line_val = st.number_input(f"Línea {direction}",
                                min_value=0.5, max_value=500.0, value=def_line, step=0.5,
                                key=f"ou_line_{ev_id[:10]}")
                        with lc2:
                            if st.button("✅", key=f"ou_ok_{ev_id[:10]}", use_container_width=True):
                                st.session_state[f"qp_val_{ev_id}"]  = f"{direction} {line_val}"
                                st.session_state[f"qp_merc_{ev_id}"] = "O/U"
                                st.session_state.pop(ou_key, None)
                                st.rerun()
                        with lc3:
                            if st.button("✖", key=f"ou_x_{ev_id[:10]}", use_container_width=True):
                                st.session_state.pop(ou_key, None)
                                st.rerun()

                    # Save form
                    if qv:
                        qm = st.session_state.get(f"qp_merc_{ev_id}", "ML")
                        if ao == 0 and ho == 0:
                            with st.spinner("Momios..."):
                                ao, do, ho = get_live_odds(sport_ev, home, away)

                        ql = qv.lower()
                        def_momio = 1.85
                        if "empate" in ql and do > 1:           def_momio = round(do,2)
                        elif home.lower()[:5] in ql and ho > 1: def_momio = round(ho,2)
                        elif away.lower()[:5] in ql and ao > 1: def_momio = round(ao,2)
                        elif ao > 1:                             def_momio = round(ao,2)

                        b = def_momio - 1
                        kelly_bet = round(bank * max(0,(1/def_momio*(b+1)-1)/b)*0.25, 0) if b>0 else 50.0
                        kelly_bet = max(50.0, min(kelly_bet, bank))

                        sc1, sc2, sc3, sc4 = st.columns([2,2,1,1])
                        with sc1:
                            momio_v = st.number_input("Momio", min_value=1.01, max_value=99.0,
                                                       value=float(def_momio), step=0.05,
                                                       key=f"qmomio_{ev_id[:10]}")
                        with sc2:
                            apuesta_v = st.number_input(f"Apuesta · Kelly ~${kelly_bet:,.0f}",
                                min_value=1.0, max_value=float(bank),
                                value=float(kelly_bet), step=50.0,
                                key=f"qapuesta_{ev_id[:10]}")
                            pct = apuesta_v/bank*100 if bank>0 else 0
                            bc = "#00FF88" if pct<=5 else "#FFB800" if pct<=10 else "#FF2D55"
                            st.markdown(
                                f'<div style="display:flex;align-items:center;gap:4px">'
                                f'<div style="flex:1;background:rgba(255,255,255,.05);'
                                f'border-radius:99px;height:3px">'
                                f'<div style="width:{min(100,pct*4):.0f}%;height:100%;'
                                f'background:{bc};border-radius:99px"></div></div>'
                                f'<span style="font-size:.5rem;color:{bc}">{pct:.1f}%</span></div>',
                                unsafe_allow_html=True)
                        with sc3:
                            st.markdown("<div style='height:28px'></div>", unsafe_allow_html=True)
                            if st.button("💾 OK", key=f"qsave_{ev_id[:10]}", type="primary",
                                          use_container_width=True):
                                raw_liga = ev.get("_liga_label", ev.get("liga",""))
                                SPORT_DISPLAY = {"soccer":"⚽ Fútbol","basketball":"🏀 NBA",
                                                 "baseball":"⚾ MLB","hockey":"🏒 NHL","football":"🏈 NFL"}
                                if not raw_liga or "cargar" in raw_liga.lower():
                                    raw_liga = SPORT_DISPLAY.get(sport_ev, sport_ev.upper())
                                row_data = {"fecha": str(date.today()), "deporte": sport_ev,
                                       "liga": raw_liga, "partido": f"{away} vs {home}",
                                       "event_id": ev_id, "mercado": qm, "pick_desc": qv,
                                       "momio": momio_v, "apuesta": apuesta_v,
                                       "resultado": "pendiente", "ganancia_neta": 0,
                                       "bankroll_post": bank, "notas": ""}
                                if save_pick(apodo, row_data):
                                    st.success(f"✅ {qv} @ {momio_v}x — ${apuesta_v:,.0f}")
                                    for k in ["df_picks","selected_event","pick_type"]:
                                        st.session_state.pop(k, None)
                                    st.session_state.pop(f"qp_val_{ev_id}", None)
                                    st.session_state.pop(f"qp_merc_{ev_id}", None)
                                    st.rerun()
                        with sc4:
                            st.markdown("<div style='height:28px'></div>", unsafe_allow_html=True)
                            if st.button("✖", key=f"qcancel_{ev_id[:10]}", use_container_width=True):
                                st.session_state.pop(f"qp_val_{ev_id}", None)
                                st.session_state.pop(f"qp_merc_{ev_id}", None)
                                st.rerun()

                    st.markdown("<div style='height:2px'></div>", unsafe_allow_html=True)



    # Check if any event has an open pick form
    any_open_id = None
    for ev in all_evs:
        ev_id = ev["id"]
        if (st.session_state.get(f"qp_val_{ev_id}") or
            st.session_state.get(f"ou_pending_{ev_id[:10]}") or
            st.session_state.get(f"expand_other_{ev_id[:10]}")):
            any_open_id = ev_id
            break


# ─────────────────────────────────────────────────────────────
#  TAB 2 — HISTORIAL
# ─────────────────────────────────────────────────────────────
def tab_historial(apodo: str, df: pd.DataFrame):
    if df.empty:
        st.info("Sin picks registrados aún.")
        return

    SPORT_ICON = {
        "soccer":"⚽","football":"🏈","basketball":"🏀",
        "baseball":"⚾","hockey":"🏒","tennis":"🎾","golf":"⛳","mma":"🥊",
    }
    res_c = {"ganado":"#00FF88","perdido":"#FF2D55","nulo":"#8888AA","pendiente":"#FFB800"}
    res_i = {"ganado":"✅","perdido":"❌","nulo":"➖","pendiente":"⏳"}

    # ── Liga performance analysis (auto) ──────────────────────
    resolved = df[df["resultado"].isin(["ganado","perdido","nulo"])].copy()
    if not resolved.empty:
        st.markdown('<div class="sec-head">📊 Tu rendimiento por liga</div>', unsafe_allow_html=True)
        SPORT_DISPLAY = {"soccer":"⚽ Fútbol","basketball":"🏀 NBA",
                         "baseball":"⚾ MLB","hockey":"🏒 NHL","football":"🏈 NFL"}
        # Normalize liga — replace "Cargar todo" with deporte display name
        resolved_h = resolved.copy()
        def fix_liga(row):
            liga = str(row.get("liga",""))
            if not liga or "cargar" in liga.lower():
                dep = str(row.get("deporte","")).lower()
                return SPORT_DISPLAY.get(dep, dep.upper() or "Otro")
            return liga
        resolved_h["liga_display"] = resolved_h.apply(fix_liga, axis=1)

        liga_stats = []
        for liga, grp in resolved_h.groupby("liga_display"):
            total = len(grp)
            wins  = (grp["resultado"]=="ganado").sum()
            roi   = grp["ganancia_neta"].sum() / grp["apuesta"].sum() * 100 if grp["apuesta"].sum() > 0 else 0
            liga_stats.append({"liga": liga, "total": total, "wins": int(wins), "roi": roi})
        liga_stats.sort(key=lambda x: (-x["wins"]/x["total"] if x["total"] else 0, -x["total"]))

        cols = st.columns(min(len(liga_stats), 4))
        for i, ls in enumerate(liga_stats[:8]):
            wr   = ls["wins"]/ls["total"]*100 if ls["total"] else 0
            roi  = ls["roi"]
            clr  = "#00FF88" if wr >= 55 else "#FFB800" if wr >= 40 else "#FF2D55"
            with cols[i % min(len(liga_stats),4)]:
                st.markdown(
                    f'<div style="background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.08);'
                    f'border-top:3px solid {clr};border-radius:10px;padding:10px 12px;margin-bottom:8px;text-align:center">'
                    f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.55rem;color:var(--text3);'
                    f'margin-bottom:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{ls["liga"][:20]}</div>'
                    f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:1.6rem;color:{clr};line-height:1">'
                    f'{ls["wins"]}/{ls["total"]}</div>'
                    f'<div style="font-size:.6rem;color:{clr};font-weight:700">{wr:.0f}% WR</div>'
                    f'<div style="font-size:.55rem;color:var(--text3);margin-top:2px">'
                    f'ROI {roi:+.1f}%</div></div>',
                    unsafe_allow_html=True
                )
        st.markdown("<div style='height:8px'></div>", unsafe_allow_html=True)

    # ── Filters ──────────────────────────────────────────────
    c1, c2, c3 = st.columns(3)
    with c1:
        f_res  = st.selectbox("Resultado", ["Todos","ganado","perdido","nulo","pendiente"])
    with c2:
        ligas  = ["Todas"] + sorted(df["liga"].dropna().unique().tolist())
        f_liga = st.selectbox("Liga", ligas)
    with c3:
        mercs  = ["Todos"] + sorted(df["mercado"].dropna().unique().tolist())
        f_merc = st.selectbox("Mercado", mercs)

    filt = df.copy()
    if f_res  != "Todos": filt = filt[filt["resultado"] == f_res]
    if f_liga != "Todas": filt = filt[filt["liga"] == f_liga]
    if f_merc != "Todos": filt = filt[filt["mercado"] == f_merc]
    filt = filt.sort_values("fecha", ascending=False)

    st.markdown(
        f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.55rem;color:var(--text3);'
        f'margin:8px 0">{len(filt)} picks</div>', unsafe_allow_html=True
    )

    # ── Pick cards ────────────────────────────────────────────
    for idx, row in filt.iterrows():
        res     = str(row.get("resultado","pendiente"))
        clr     = res_c.get(res,"#888")
        ico     = res_i.get(res,"·")
        gan     = float(row.get("ganancia_neta",0) or 0)
        apuesta = float(row.get("apuesta",0) or 0)
        momio   = float(row.get("momio",0) or 0)
        fd      = str(row.get("fecha",""))[:10]
        deporte = str(row.get("deporte","soccer")).lower()
        sp_ico  = SPORT_ICON.get(deporte,"🎯")
        partido = str(row.get("partido","")) or "Partido desconocido"
        liga    = str(row.get("liga","")) or ""
        pick_d  = str(row.get("pick_desc",""))
        if pick_d in ("","nan","None"): pick_d = "—"
        mercado = str(row.get("mercado","")) or ""
        if mercado in ("nan","None"): mercado = ""
        notas   = str(row.get("notas",""))
        if notas in ("nan","None",""): notas = ""

        gc  = "#00FF88" if gan>0 else "#FF2D55" if gan<0 else "#FFB800"
        pot = ""
        if res == "pendiente" and apuesta > 0 and momio > 1:
            pot_val = momio * apuesta - apuesta
            pot = f"+${pot_val:,.0f} pot."

        col_card, col_del = st.columns([11, 1])
        with col_card:
            # Row 1: icon + partido + amount
            r1, r2, r3 = st.columns([1, 7, 3])
            with r1:
                st.markdown(f'<div style="font-size:2rem;padding-top:2px;text-align:center">{sp_ico}</div>',
                             unsafe_allow_html=True)
            with r2:
                st.markdown(
                    f'<div style="font-size:.95rem;font-weight:700;color:#EEEEF5">{format_partido_para_display(partido, deporte)}</div>'
                    f'<div style="font-size:.62rem;color:#8888AA;margin-top:1px">{liga}'
                    f'{"  ·  " + mercado if mercado else ""}</div>',
                    unsafe_allow_html=True)
            with r3:
                gs = f"+${gan:,.2f}" if gan>0 else f"-${abs(gan):,.2f}" if gan<0 else pot or "⏳"
                st.markdown(
                    f'<div style="text-align:right">'
                    f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:1.4rem;'
                    f'color:{gc};line-height:1">{gs}</div>'
                    f'<div style="font-size:.58rem;color:#8888AA">'
                    f'{"@" + str(momio) + "x  ·  " if momio > 0 else ""}${apuesta:,.0f}</div>'
                    f'</div>', unsafe_allow_html=True)

            # Row 2: pick + result + date
            r4, r5 = st.columns([6, 4])
            with r4:
                st.markdown(
                    f'<div style="background:rgba(0,255,209,.07);border-left:3px solid var(--neon2);'
                    f'padding:4px 10px;border-radius:0 6px 6px 0;margin-top:6px">'
                    f'<span style="font-size:.65rem;color:#8888AA">🎯 PICK  </span>'
                    f'<span style="font-size:.82rem;font-weight:700;color:var(--neon2)">{pick_d}</span>'
                    f'</div>', unsafe_allow_html=True)
            with r5:
                st.markdown(
                    f'<div style="text-align:right;padding-top:10px">'
                    f'<span style="font-size:.7rem;font-weight:700;color:{clr}">{ico} {res.upper()}</span>'
                    f'  <span style="font-size:.58rem;color:#8888AA">{fd}</span>'
                    f'</div>', unsafe_allow_html=True)

            if notas:
                st.caption(f"📝 {notas}")
            st.divider()

        with col_del:
            st.markdown("<div style='height:14px'></div>", unsafe_allow_html=True)
            if st.button("🗑", key=f"del_{idx}", help="Eliminar"):
                if delete_pick(apodo, idx):
                    st.session_state.pop("df_picks", None)
                    st.rerun()

    # ═══════════════════════════════════════════════════════════════

    # ═══════════════════════════════════════════════════════════════
    # 🔍 PANEL: Calificar picks pendientes manualmente
    # ═══════════════════════════════════════════════════════════════
    st.divider()
    st.write("### 🔍 CALIFICAR PICKS PENDIENTES")
    
    try:
        ss = get_ss()
        ws = None
        for sheet in ss.worksheets():
            if sheet.title.lower() == f"picks_{apodo}".lower():
                ws = sheet
                break
        
        if not ws:
            st.warning(f"No se encontró hoja picks_{apodo}")
        else:
            records = _safe_get_records(ws)
            pending = [r for r in records if str(r.get("resultado", "")).strip().lower() == "pendiente"]
            
            if not pending:
                st.info("✅ No hay picks pendientes")
            else:
                st.write(f"**📝 {len(pending)} picks pendientes:**")
                st.divider()
                
                for idx, pick in enumerate(pending):
                    st.write(f"**{idx+1}. {pick.get('partido', '?')}**")
                    col1, col2, col3 = st.columns(3)
                    
                    with col1:
                        st.caption(f"🏀 {pick.get('deporte', '?')} - {pick.get('pick_desc', '?')}")
                    
                    with col2:
                        if st.button("🧪 TEST", key=f"hist_check_{idx}", use_container_width=True):
                            st.session_state[f"test_{idx}"] = True
                    
                    with col3:
                        if st.button("✅ GRADE", key=f"hist_grade_{idx}", use_container_width=True):
                            st.session_state[f"grade_{idx}"] = True
                    
                    # Mostrar resultado de TEST
                    if st.session_state.get(f"test_{idx}"):
                        with st.container(border=True):
                            st.write(f"**🧪 TEST: {pick.get('partido')}**")
                            
                            event_id = str(pick.get('event_id', '')).strip()
                            partido = str(pick.get('partido', '')).strip()
                            deporte = str(pick.get('deporte', 'soccer')).strip()
                            pick_desc = str(pick.get('pick_desc', '')).lower().strip()
                            
                            encontrado = False
                            
                            # Búsqueda 1: Event ID
                            if event_id and event_id != "":
                                st.caption(f"🔍 Buscando por EVENT_ID: {event_id}")
                                espn_data = _find_resultado_por_event_id(event_id, deporte)
                                if espn_data.get('debug'):
                                    st.caption(espn_data.get('debug'))
                                
                                if espn_data.get('found') and espn_data.get('completed'):
                                    st.success(f"✅ {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
                                    encontrado = True
                            
                            # Búsqueda 2: Por nombre
                            if not encontrado:
                                st.caption(f"🔍 Buscando por NOMBRE: {partido}")
                                found_event_id = _buscar_event_id_por_partido(partido, deporte)
                                if found_event_id:
                                    st.caption(f"✅ Event ID encontrado: {found_event_id}")
                                    espn_data = _find_resultado_por_event_id(found_event_id, deporte)
                                    if espn_data.get('debug'):
                                        st.caption(espn_data.get('debug'))
                                    if espn_data.get('found') and espn_data.get('completed'):
                                        st.success(f"✅ {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
                                        encontrado = True
                            
                            if not encontrado:
                                st.warning("❌ No se encontró resultado en ESPN")
                            
                            if st.button("✖️ Cerrar", key=f"close_test_{idx}"):
                                st.session_state[f"test_{idx}"] = False
                    
                    # Mostrar resultado de GRADE
                    if st.session_state.get(f"grade_{idx}"):
                        with st.container(border=True):
                            st.write(f"**⏳ CALIFICANDO: {pick.get('partido')}**")
                            
                            event_id = str(pick.get('event_id', '')).strip()
                            partido = str(pick.get('partido', '')).strip()
                            deporte = str(pick.get('deporte', 'soccer')).strip()
                            pick_desc = str(pick.get('pick_desc', '')).lower().strip()
                            
                            resultado = None
                            
                            if event_id and event_id != "":
                                espn_data = _find_resultado_por_event_id(event_id, deporte)
                                if espn_data.get('found') and espn_data.get('completed'):
                                    away_team = espn_data.get('away_team', '')
                                    home_team = espn_data.get('home_team', '')
                                    away_score = espn_data.get('away_score', -1)
                                    home_score = espn_data.get('home_score', -1)
                                    resultado = _calificar_resultado(away_team, home_team, away_score, home_score, pick_desc)
                            
                            if not resultado:
                                found_event_id = _buscar_event_id_por_partido(partido, deporte)
                                if found_event_id:
                                    espn_data = _find_resultado_por_event_id(found_event_id, deporte)
                                    if espn_data.get('found') and espn_data.get('completed'):
                                        away_team = espn_data.get('away_team', '')
                                        home_team = espn_data.get('home_team', '')
                                        away_score = espn_data.get('away_score', -1)
                                        home_score = espn_data.get('home_score', -1)
                                        resultado = _calificar_resultado(away_team, home_team, away_score, home_score, pick_desc)
                            
                            if not resultado:
                                resultado = _find_resultado_robusto(partido, deporte, pick_desc)
                            
                            if resultado:
                                try:
                                    ws.update_cell(idx + 2, 10, resultado)
                                    st.success(f"✅ Calificado como: {resultado.upper()}")
                                    st.session_state.pop("df_picks", None)
                                    st.session_state[f"grade_{idx}"] = False
                                except Exception as e:
                                    st.error(f"Error: {str(e)[:50]}")
                            else:
                                st.error("❌ No se encontró resultado")
                            
                            if st.button("✖️ Cerrar", key=f"close_grade_{idx}"):
                                st.session_state[f"grade_{idx}"] = False
                    
                    st.divider()
    except Exception as e:
        st.error(f"Error: {str(e)[:100]}")

#  TAB 3 — ANALYTICS
# ─────────────────────────────────────────────────────────────
def tab_analytics(df: pd.DataFrame, bank: float):
    resolved = df[df["resultado"].isin(["ganado","perdido","nulo"])].copy()
    if resolved.empty:
        st.info("Necesitas al menos un pick resuelto para ver analytics.")
        return

    wins   = (resolved["resultado"]=="ganado").sum()
    losses = (resolved["resultado"]=="perdido").sum()
    total  = len(resolved)
    wr     = wins/total*100 if total else 0
    roi    = resolved["ganancia_neta"].sum()/resolved["apuesta"].sum()*100 if resolved["apuesta"].sum() else 0
    neto   = resolved["ganancia_neta"].sum()
    sorted_res = resolved.sort_values("fecha")
    racha_list = sorted_res["resultado"].tolist()

    # ── Racha calculations ──
    def max_streak(lst, val):
        best = cur = 0
        for r in lst:
            cur = cur + 1 if r == val else 0
            best = max(best, cur)
        return best

    def current_streak(lst):
        if not lst: return 0, ""
        last = lst[-1]; cnt = 0
        for r in reversed(lst):
            if r == last: cnt += 1
            else: break
        return cnt, last

    max_win_streak  = max_streak(racha_list, "ganado")
    max_loss_streak = max_streak(racha_list, "perdido")
    cur_streak_n, cur_streak_t = current_streak(racha_list)

    # Days green vs red
    dias = sorted_res.groupby("fecha")["ganancia_neta"].sum()
    dias_verde = (dias > 0).sum()
    dias_rojo  = (dias < 0).sum()

    # Tilt alert
    consec_losses = 0
    for r in reversed(racha_list[-6:]):
        if r == "perdido": consec_losses += 1
        else: break
    if consec_losses >= 3:
        st.markdown(
            f'<div class="tilt-alert">🧠 <strong>ALERTA DE TILT</strong> — '
            f'Llevas {consec_losses} pérdidas seguidas. Considera pausar.</div>',
            unsafe_allow_html=True
        )

    # KPIs — Row 1
    st.markdown('<div class="sec-head">Resumen general</div>', unsafe_allow_html=True)
    gc = "#00FF88" if roi >= 0 else "#FF2D55"
    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box"><div class="kpi-val">{total}</div><div class="kpi-lbl">Total Picks</div></div>
  <div class="kpi-box" style="border-color:rgba(0,255,136,.2)"><div class="kpi-val" style="color:#00FF88">{wr:.1f}%</div><div class="kpi-lbl">Win Rate</div></div>
  <div class="kpi-box" style="border-color:rgba({'0,255,136' if roi>=0 else '255,45,85'},.2)"><div class="kpi-val" style="color:{gc}">{'+' if roi>=0 else ''}{roi:.1f}%</div><div class="kpi-lbl">ROI</div></div>
  <div class="kpi-box" style="border-color:rgba({'0,255,136' if neto>=0 else '255,45,85'},.2)"><div class="kpi-val" style="color:{gc}">${neto:,.0f}</div><div class="kpi-lbl">Neto MXN</div></div>
</div>""", unsafe_allow_html=True)

    # KPIs — Row 2: racha stats
    st.markdown('<div class="sec-head">Estadísticas de racha</div>', unsafe_allow_html=True)
    cur_c = "#00FF88" if cur_streak_t == "ganado" else "#FF2D55" if cur_streak_t == "perdido" else "#8888AA"
    cur_lbl = f"{'🔥' if cur_streak_t=='ganado' else '❄️'} {cur_streak_n} {'ganados' if cur_streak_t=='ganado' else 'perdidos'}" if cur_streak_t else "—"
    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box" style="border-color:rgba(0,255,136,.2)">
    <div class="kpi-val" style="color:#00FF88">{max_win_streak}</div>
    <div class="kpi-lbl">Mejor racha ganadora</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(255,45,85,.2)">
    <div class="kpi-val" style="color:#FF2D55">{max_loss_streak}</div>
    <div class="kpi-lbl">Peor racha perdedora</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(0,255,136,.15)">
    <div class="kpi-val" style="color:#00FF88">{dias_verde}</div>
    <div class="kpi-lbl">Días verdes 📈</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(255,45,85,.15)">
    <div class="kpi-val" style="color:#FF2D55">{dias_rojo}</div>
    <div class="kpi-lbl">Días rojos 📉</div>
  </div>
  <div class="kpi-box" style="border-color:rgba({cur_c.replace('#','').lstrip('0') or '888888'},.2)">
    <div class="kpi-val" style="color:{cur_c};font-size:1rem">{cur_lbl}</div>
    <div class="kpi-lbl">Racha actual</div>
  </div>
</div>""", unsafe_allow_html=True)

    st.markdown('<div class="sec-head">Racha reciente</div>', unsafe_allow_html=True)
    st.markdown(racha_html(racha_list), unsafe_allow_html=True)

    # ── Bankroll chart
    st.markdown('<div class="sec-head">Evolución del bankroll</div>', unsafe_allow_html=True)
    bank_df = resolved.sort_values("fecha").copy()

    # Always reconstruct from ganancia_neta for accuracy
    running = START_BANK
    bank_vals = [START_BANK]
    labels = ["Inicio"]
    for _, r in bank_df.iterrows():
        running = round(running + float(r.get("ganancia_neta", 0)), 2)
        bank_vals.append(max(running, 0.01))
        partido = str(r.get("partido",""))
        pick_d  = str(r.get("pick_desc",""))
        res     = str(r.get("resultado",""))
        labels.append(f"{partido[:20]}<br>{pick_d[:15]} → {res}")

    max_val = max(bank_vals)
    min_val = min(bank_vals)

    # Use log scale only if range spans more than 10x
    use_log = (max_val / max(min_val, 1)) > 10

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=list(range(len(bank_vals))),
        y=bank_vals,
        mode="lines+markers",
        text=labels,
        hovertemplate="%{text}<br><b>$%{y:,.0f}</b><extra></extra>",
        line=dict(color="#FF3D00", width=2.5),
        marker=dict(
            size=8, color=["#F0FF00"] + ["#00FF88" if v >= bank_vals[i] else "#FF2D55"
                           for i, v in enumerate(bank_vals[1:])],
            line=dict(color="#FF3D00", width=1)
        ),
        fill="tozeroy",
        fillcolor="rgba(255,61,0,0.06)",
        name="Bankroll",
    ))
    # Reference lines
    fig.add_hline(y=START_BANK, line_dash="dash", line_color="#F0FF00", line_width=1,
                  annotation_text=f"INICIO ${START_BANK:,.0f}",
                  annotation_font_color="#F0FF00", annotation_font_size=9)
    if use_log:
        fig.add_hline(y=RETO_GOAL, line_dash="dot", line_color="#BF5FFF", line_width=1.5,
                      annotation_text="META $13M", annotation_font_color="#BF5FFF",
                      annotation_font_size=10)

    # Y axis — show actual $ values around current range
    y_min = max(0.01, min_val * 0.95)
    y_max = max_val * 1.05

    if use_log:
        log_ticks = [1_000, 5_000, 10_000, 50_000, 100_000, 500_000,
                     1_000_000, 5_000_000, 13_000_000]
        log_ticks = [t for t in log_ticks if y_min <= t <= y_max * 2]
        yaxis_cfg = dict(type="log", tickvals=log_ticks,
                         ticktext=[f"${v:,.0f}" for v in log_ticks],
                         showgrid=True, gridcolor="rgba(255,255,255,0.05)", zeroline=False)
    else:
        # Linear — show actual range with nice ticks
        tick_step = max(10, round((y_max - y_min) / 5, -1))
        import math
        tick_step = 10 ** math.floor(math.log10(max(1, y_max - y_min))) // 2
        tick_step = max(10, tick_step)
        yaxis_cfg = dict(type="linear", range=[y_min, y_max],
                         tickformat="$,.0f",
                         showgrid=True, gridcolor="rgba(255,255,255,0.05)", zeroline=False)

    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color="#8888AA", family="JetBrains Mono"),
        margin=dict(l=10, r=10, t=10, b=10), height=280,
        showlegend=False,
        xaxis=dict(showgrid=False, zeroline=False, showticklabels=False,
                   title="Picks →"),
        yaxis=yaxis_cfg,
    )
    st.plotly_chart(fig, use_container_width=True)

    # ── Stats por liga
    st.markdown('<div class="sec-head">Rendimiento por liga</div>', unsafe_allow_html=True)
    SPORT_DISPLAY = {"soccer":"⚽ Fútbol","basketball":"🏀 NBA",
                     "baseball":"⚾ MLB","hockey":"🏒 NHL","football":"🏈 NFL"}
    resolved_an = resolved.copy()
    def fix_liga_an(row):
        liga = str(row.get("liga",""))
        if not liga or "cargar" in liga.lower():
            dep = str(row.get("deporte","")).lower()
            return SPORT_DISPLAY.get(dep, dep.upper() or "Otro")
        return liga
    resolved_an["liga_norm"] = resolved_an.apply(fix_liga_an, axis=1)

    liga_stats = []
    for liga, grp in resolved_an.groupby("liga_norm"):
        g = (grp["resultado"]=="ganado").sum()
        p = (grp["resultado"]=="perdido").sum()
        t = len(grp)
        wr_l   = g/t*100 if t else 0
        roi_l  = grp["ganancia_neta"].sum()/grp["apuesta"].sum()*100 if grp["apuesta"].sum() else 0
        neto_l = grp["ganancia_neta"].sum()
        liga_stats.append({"liga":liga,"g":g,"p":p,"t":t,"wr":wr_l,"roi":roi_l,"neto":neto_l})
    liga_stats.sort(key=lambda x: x["roi"], reverse=True)

    for ls in liga_stats:
        wrc  = "#00FF88" if ls["wr"]>=55 else "#FFB800" if ls["wr"]>=45 else "#FF2D55"
        roic = "#00FF88" if ls["roi"]>=0 else "#FF2D55"
        ns   = f'+${ls["neto"]:,.0f}' if ls["neto"]>=0 else f'${ls["neto"]:,.0f}'
        st.markdown(f"""
<div class="league-row">
  <div style="width:130px;font-size:.75rem;font-weight:700;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{ls['liga']}</div>
  <div style="font-size:.65rem;color:var(--text3);white-space:nowrap">{ls['g']}G / {ls['p']}P</div>
  <div class="league-bar-wrap"><div class="league-bar-fill" style="width:{min(100,ls['wr']):.0f}%;background:{wrc}"></div></div>
  <div style="font-size:.75rem;font-weight:800;color:{wrc};white-space:nowrap;width:38px;text-align:right">{ls['wr']:.0f}%</div>
  <div style="font-size:.72rem;font-weight:700;color:{roic};white-space:nowrap;width:55px;text-align:right">ROI {'+' if ls['roi']>=0 else ''}{ls['roi']:.1f}%</div>
  <div style="font-size:.72rem;font-weight:700;color:{roic};white-space:nowrap;width:70px;text-align:right">{ns}</div>
</div>""", unsafe_allow_html=True)

    # ── Stats por mercado
    st.markdown('<div class="sec-head">Rendimiento por mercado</div>', unsafe_allow_html=True)
    merc_stats = []
    for merc, grp in resolved.groupby("mercado"):
        g = (grp["resultado"]=="ganado").sum()
        p = (grp["resultado"]=="perdido").sum()
        t = len(grp)
        merc_stats.append({
            "merc":merc,"g":g,"p":p,"t":t,
            "wr":g/t*100 if t else 0,
            "roi":grp["ganancia_neta"].sum()/grp["apuesta"].sum()*100 if grp["apuesta"].sum() else 0,
            "neto":grp["ganancia_neta"].sum()
        })
    merc_stats.sort(key=lambda x: x["roi"], reverse=True)

    cols = st.columns(2)
    for i, ms in enumerate(merc_stats):
        rc = "#00FF88" if ms["roi"]>=0 else "#FF2D55"
        ns = f'+${ms["neto"]:,.0f}' if ms["neto"]>=0 else f'${ms["neto"]:,.0f}'
        with cols[i%2]:
            st.markdown(f"""
<div class="card" style="padding:12px;margin-bottom:8px">
  <div style="font-size:.8rem;font-weight:700;color:var(--text)">{ms['merc']}</div>
  <div style="font-size:.65rem;color:var(--text3);margin:2px 0">{ms['g']}G · {ms['p']}P · {ms['wr']:.0f}% WR</div>
  <div style="font-family:'Bebas Neue',sans-serif;font-size:1.3rem;color:{rc}">
    ROI {'+' if ms['roi']>=0 else ''}{ms['roi']:.1f}%
  </div>
  <div style="font-size:.65rem;color:{rc}">{ns}</div>
</div>""", unsafe_allow_html=True)

    # ── Win% por rango de momio
    st.markdown('<div class="sec-head">Win% por rango de momio</div>', unsafe_allow_html=True)
    bins = [(1.01,1.50,"1.01–1.50"),(1.51,2.00,"1.51–2.00"),
            (2.01,2.50,"2.01–2.50"),(2.51,3.50,"2.51–3.50"),(3.51,99,"3.51+")]
    for lo,hi,lbl in bins:
        grp = resolved[(resolved["momio"]>=lo)&(resolved["momio"]<hi)]
        if grp.empty: continue
        g = (grp["resultado"]=="ganado").sum(); t = len(grp)
        wr_b  = g/t*100 if t else 0
        roi_b = grp["ganancia_neta"].sum()/grp["apuesta"].sum()*100 if grp["apuesta"].sum() else 0
        bc = "#00FF88" if wr_b>=55 else "#FFB800" if wr_b>=45 else "#FF2D55"
        rc = "#00FF88" if roi_b>=0 else "#FF2D55"
        st.markdown(f"""
<div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">
  <div style="width:75px;font-family:'JetBrains Mono',monospace;font-size:.6rem;color:var(--text3)">{lbl}</div>
  <div style="width:42px;font-size:.62rem;color:var(--text3)">{g}/{t}</div>
  <div style="flex:1;background:rgba(255,255,255,.05);border-radius:99px;height:7px;overflow:hidden">
    <div style="width:{wr_b:.0f}%;height:100%;border-radius:99px;background:{bc};box-shadow:0 0 8px {bc}66"></div>
  </div>
  <div style="width:38px;font-family:'JetBrains Mono',monospace;font-size:.7rem;font-weight:700;color:{bc}">{wr_b:.0f}%</div>
  <div style="width:65px;font-family:'JetBrains Mono',monospace;font-size:.7rem;font-weight:700;color:{rc};text-align:right">{'+' if roi_b>=0 else ''}{roi_b:.1f}%</div>
</div>""", unsafe_allow_html=True)


# ─────────────────────────────────────────────────────────────
#  TAB 4 — CHALLENGE / LEADERBOARD
# ─────────────────────────────────────────────────────────────
def tab_challenge(apodo: str, df: pd.DataFrame, bank: float):
    st.markdown("""
<div style="background:linear-gradient(135deg,rgba(191,95,255,.1),rgba(255,61,0,.06),rgba(240,255,0,.04));
     border:1px solid rgba(191,95,255,.3);border-radius:16px;padding:22px;text-align:center;margin-bottom:16px;
     box-shadow:0 0 30px rgba(191,95,255,.1),0 8px 32px rgba(0,0,0,.4)">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:1.6rem;color:#BF5FFF;letter-spacing:4px">⚔️ LEADERBOARD GLOBAL</div>
  <div style="font-size:.72rem;color:#8888AA;margin-top:6px">Clasificación en tiempo real de todos los apostadores del Reto 13M</div>
</div>""", unsafe_allow_html=True)

    all_users = load_users()
    all_users.sort(key=lambda u: float(u.get("bankroll", 0)), reverse=True)

    medals = ["🥇","🥈","🥉"]
    for i, u in enumerate(all_users[:15]):
        u_apodo = u.get("apodo","?")
        u_bank  = float(u.get("bankroll", START_BANK))
        u_wins  = int(u.get("wins",0))
        u_loss  = int(u.get("losses",0))
        u_total = u_wins + u_loss
        u_wr    = f"{u_wins/u_total*100:.0f}%" if u_total else "—"
        is_me   = u_apodo.lower() == apodo.lower()
        medal   = medals[i] if i < 3 else f"#{i+1}"
        rango   = get_rango(u_bank)
        pct     = min(100, u_bank/RETO_GOAL*100)
        st.markdown(f"""
<div class="lb-row {'me' if is_me else ''}">
  <div style="font-size:1.1rem;width:32px;text-align:center;font-family:'Bebas Neue',sans-serif">{medal}</div>
  <div class="lb-avatar">{u_apodo[0].upper()}</div>
  <div style="flex:1">
    <div style="font-size:.88rem;font-weight:700;color:{'var(--neon)' if is_me else 'var(--text)'}">
      {u_apodo.upper()} {'← TÚ' if is_me else ''}
    </div>
    <div style="font-size:.6rem;color:var(--text3)">{rango['icon']} {rango['nombre']} · {u_wr} WR · {pct:.2f}% del reto</div>
  </div>
  <div style="text-align:right">
    <div style="font-family:'Bebas Neue',sans-serif;font-size:1.1rem;color:var(--gold)">${u_bank:,.0f}</div>
  </div>
</div>""", unsafe_allow_html=True)

    # Update own record
    resolved_u = df[df["resultado"].isin(["ganado","perdido"])].copy() if not df.empty else pd.DataFrame()
    w = int((resolved_u["resultado"]=="ganado").sum()) if not resolved_u.empty else 0
    l = int((resolved_u["resultado"]=="perdido").sum()) if not resolved_u.empty else 0
    upsert_user(apodo, bank, w, l)


# ─────────────────────────────────────────────────────────────
#  TAB 5 — SIMULADOR
# ─────────────────────────────────────────────────────────────
def tab_simulador(df: pd.DataFrame, bank: float):
    st.markdown('<div class="sec-head">Simulador de destino — Monte Carlo</div>', unsafe_allow_html=True)

    resolved = df[df["resultado"].isin(["ganado","perdido"])].copy() if not df.empty else pd.DataFrame()
    avg_momio  = float(resolved["momio"].mean()) if not resolved.empty else 1.85
    avg_bet_pct = float((resolved["apuesta"]/resolved["bankroll_post"].replace(0,START_BANK)).mean())*100 if not resolved.empty else 2.0
    real_wr    = float((resolved["resultado"]=="ganado").sum()/len(resolved)*100) if not resolved.empty else 55.0

    c1, c2, c3 = st.columns(3)
    with c1: n_picks  = st.slider("Picks siguientes", 5, 300, 50, 5)
    with c2: win_rate = st.slider("Win rate (%)", 30, 80, int(real_wr), 1)
    with c3: bet_pct  = st.slider("% bankroll / pick", 0.5, 10.0, round(avg_bet_pct,1), 0.5)

    momio_sim = st.slider("Momio promedio", 1.10, 5.00, round(avg_momio,2), 0.05)

    # Monte Carlo — 300 runs
    RUNS = 300
    results = []
    for _ in range(RUNS):
        b = bank; traj = [b]
        for _ in range(n_picks):
            bet = b * (bet_pct/100)
            b  += bet*(momio_sim-1) if random.random() < win_rate/100 else -bet
            b   = max(b, 0)
            traj.append(b)
        results.append(traj)

    finals = [r[-1] for r in results]
    p10  = sorted(finals)[int(RUNS*.1)]
    p50  = sorted(finals)[int(RUNS*.5)]
    p90  = sorted(finals)[int(RUNS*.9)]
    hits = sum(1 for f in finals if f >= RETO_GOAL)

    gc_p10 = "#FF2D55"; gc_p50 = "#FFB800"; gc_p90 = "#00FF88"
    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box" style="border-color:rgba(255,45,85,.25)"><div class="kpi-val" style="color:{gc_p10}">${p10:,.0f}</div><div class="kpi-lbl">Pesimista P10</div></div>
  <div class="kpi-box" style="border-color:rgba(255,184,0,.25)"><div class="kpi-val" style="color:{gc_p50}">${p50:,.0f}</div><div class="kpi-lbl">Probable P50</div></div>
  <div class="kpi-box" style="border-color:rgba(0,255,136,.25)"><div class="kpi-val" style="color:{gc_p90}">${p90:,.0f}</div><div class="kpi-lbl">Optimista P90</div></div>
  <div class="kpi-box"><div class="kpi-val">{hits}/{RUNS}</div><div class="kpi-lbl">Llegan a $13M</div></div>
</div>""", unsafe_allow_html=True)

    # Chart — log scale with P10/P90 band
    x = list(range(n_picks+1))
    med  = [sorted([r[i] for r in results])[RUNS//2] for i in range(n_picks+1)]
    p10t = [sorted([r[i] for r in results])[int(RUNS*.1)] for i in range(n_picks+1)]
    p90t = [sorted([r[i] for r in results])[int(RUNS*.9)] for i in range(n_picks+1)]

    # safe for log
    med  = [max(v,1) for v in med]
    p10t = [max(v,1) for v in p10t]
    p90t = [max(v,1) for v in p90t]

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=x+x[::-1], y=p90t+p10t[::-1],
        fill="toself", fillcolor="rgba(255,61,0,0.06)",
        line=dict(color="rgba(0,0,0,0)"), name="Rango P10–P90",
    ))
    fig.add_trace(go.Scatter(
        x=x, y=med, mode="lines",
        line=dict(color="#FF3D00", width=2.5), name="Mediana",
    ))
    fig.add_hline(y=RETO_GOAL, line_dash="dot", line_color="#BF5FFF", line_width=1.5,
                  annotation_text="META $13M", annotation_font_color="#BF5FFF")
    fig.add_hline(y=bank, line_dash="dash", line_color="#F0FF00", line_width=1,
                  annotation_text="ACTUAL", annotation_font_color="#F0FF00")

    all_vals = p10t + p90t + [bank, RETO_GOAL]
    max_v    = max(all_vals)
    log_ticks = [10_000,25_000,50_000,100_000,250_000,500_000,
                 1_000_000,2_500_000,5_000_000,13_000_000]
    log_ticks = [t for t in log_ticks if t <= max_v*2]

    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color="#8888AA", family="JetBrains Mono"),
        margin=dict(l=10,r=10,t=10,b=10), height=280,
        legend=dict(orientation="h",y=-0.18,font=dict(size=9)),
        xaxis=dict(title="Picks",showgrid=False,zeroline=False),
        yaxis=dict(
            type="log",
            tickvals=log_ticks,
            ticktext=[f"${v:,.0f}" for v in log_ticks],
            showgrid=True, gridcolor="rgba(255,255,255,.05)",
        ),
    )
    st.plotly_chart(fig, use_container_width=True)

    if p50 > bank:
        gpp = (p50/bank)**(1/n_picks)-1
        if gpp > 0:
            ptg = math.log(RETO_GOAL/bank)/math.log(1+gpp)
            st.markdown(
                f'<div style="text-align:center;font-family:\'JetBrains Mono\',monospace;font-size:.65rem;color:#8888AA;margin-top:6px">'
                f'Con este ritmo → aprox. <span style="color:var(--neon);font-weight:700">{ptg:.0f} picks</span> para llegar a $13M</div>',
                unsafe_allow_html=True
            )



# ─────────────────────────────────────────────────────────────
#  THE PIT — Google Sheets helpers
# ─────────────────────────────────────────────────────────────
PIT_RONDAS_HEADERS  = ["ronda_id","fecha_inicio","fecha_fin","estado","ganador"]
PIT_PICKS_HEADERS   = ["ronda_id","dia","fecha","apodo","partido","liga",
                        "event_id","pick_desc","momio","resultado","comodin_usado"]
PIT_CHAT_HEADERS    = ["ts","apodo","mensaje","es_bot"]
PIT_PLAYERS_HEADERS = ["ronda_id","apodo","estado","vidas","dias_vivo","roi_acum",
                        "pick_asesino","comodin_disponible","equipos_usados"]

def pit_get_ws(tab: str, headers: list):
    ss = get_ss()
    if not ss: return None
    return ensure_tab(ss, tab, headers)

def _safe_get_records(ws) -> list:
    """Get all records safely, falling back to raw values on error."""
    try:
        return ws.get_all_records()
    except Exception:
        try:
            all_vals = ws.get_all_values()
            if len(all_vals) < 2: return []
            headers = all_vals[0]
            return [dict(zip(headers, row)) for row in all_vals[1:] if any(row)]
        except Exception:
            return []

@st.cache_data(ttl=30, show_spinner=False)
def pit_load_ronda_activa() -> dict | None:
    ss = get_ss()
    if not ss: return None
    try:
        ws = ensure_tab(ss, "pit_rondas", PIT_RONDAS_HEADERS)
        rows = _safe_get_records(ws)
        for r in reversed(rows):
            if r.get("estado") in ("activa", "inscripcion"):
                return r
    except Exception:
        pass
    return None

@st.cache_data(ttl=30, show_spinner=False)
def pit_load_players(ronda_id: str) -> list:
    ss = get_ss()
    if not ss: return []
    try:
        ws = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
        return [r for r in _safe_get_records(ws) if str(r.get("ronda_id","")) == str(ronda_id)]
    except Exception:
        return []

def pit_auto_registrar_usuario(apodo: str, ronda_id: str) -> bool:
    """
    ✅ Auto-registrar usuario en la ronda si no existe
    """
    try:
        ss = get_ss()
        if not ss:
            return False
        
        ws = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
        _rate_limit_gs("pit_jugadores_check", 0.5)
        
        # Verificar si ya existe
        current_players = _safe_get_records(ws)
        existe = any(str(p.get("ronda_id","")) == str(ronda_id) and 
                     p.get("apodo","").lower() == apodo.lower() 
                     for p in current_players)
        
        if existe:
            return True
        
        # Si no existe, registrarlo automáticamente
        new_row = [
            str(ronda_id),
            apodo,
            "vivo",
            "3",  # 3 vidas
            "",
        ]
        ws.append_row(new_row)
        _rate_limit_gs("pit_jugadores_append", 1.0)
        
        # Limpiar cache
        if "pit_players" in st.session_state:
            del st.session_state["pit_players"]
        
        return True
    except Exception as e:
        return False

@st.cache_data(ttl=30, show_spinner=False)
def pit_load_picks_ronda(ronda_id: str) -> list:
    ss = get_ss()
    if not ss: return []
    try:
        ws = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
        return [r for r in _safe_get_records(ws) if str(r.get("ronda_id","")) == str(ronda_id)]
    except Exception:
        return []

@st.cache_data(ttl=20, show_spinner=False)
def pit_load_chat(limit: int = 20) -> list:
    ss = get_ss()
    if not ss: return []
    try:
        ws = ensure_tab(ss, "pit_chat", PIT_CHAT_HEADERS)
        rows = _safe_get_records(ws)
        return rows[-limit:]
    except Exception:
        return []

def pit_save_chat(apodo: str, mensaje: str, es_bot: bool = False):
    ss = get_ss()
    if not ss: return
    try:
        ws = ensure_tab(ss, "pit_chat", PIT_CHAT_HEADERS)
        ws.append_row([datetime.now().strftime("%Y-%m-%d %H:%M:%S"), apodo, mensaje, "1" if es_bot else "0"])
        pit_load_chat.clear()
    except Exception:
        pass

def pit_crear_ronda():
    """Create a new weekly ronda starting today."""
    ss = get_ss()
    if not ss: return None
    try:
        ws   = ensure_tab(ss, "pit_rondas", PIT_RONDAS_HEADERS)
        rows = _safe_get_records(ws)
        rid  = str(len(rows) + 1).zfill(3)
        hoy  = date.today()
        fin  = hoy + timedelta(days=6)
        ws.append_row([rid, str(hoy), str(fin), "inscripcion", ""])
        pit_load_ronda_activa.clear()
        return rid
    except Exception as e:
        st.error(f"Error creando ronda: {e}")
        return None

def pit_inscribir(ronda_id: str, apodo: str):
    ss = get_ss()
    if not ss: return False
    try:
        ws = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
        existing = [r for r in _safe_get_records(ws)
                    if str(r.get("ronda_id","")) == str(ronda_id)
                    and r.get("apodo","").lower() == apodo.lower()]
        if existing: return False
        ws.append_row([ronda_id, apodo, "vivo", 0, 0.0, "", "1", ""])
        pit_load_players.clear()
        for _k in ['pit_players','pit_ronda']: st.session_state.pop(_k,None)
        return True
    except Exception:
        return False

def pit_save_pick(ronda_id: str, apodo: str, partido: str, liga: str,
                  event_id: str, pick_desc: str, momio: float, dia: int):
    ss = get_ss()
    if not ss: return False
    try:
        ws = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
        ws.append_row([ronda_id, dia, str(date.today()), apodo,
                       partido, liga, event_id, pick_desc, momio, "pendiente", "0"])
        pit_load_picks_ronda.clear()
        for _k in ["pit_picks"]: st.session_state.pop(_k,None)
        return True
    except Exception:
        return False

def pit_update_player(ronda_id: str, apodo: str, estado: str,
                       dias: int, roi: float, asesino: str, equipos_str: str):
    ss = get_ss()
    if not ss: return
    try:
        ws = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
        rows = _safe_get_records(ws)
        for i, r in enumerate(rows):
            if str(r.get("ronda_id","")) == str(ronda_id) and r.get("apodo","").lower() == apodo.lower():
                comodin = r.get("comodin_disponible","1")
                ws.update(f"A{i+2}:H{i+2}",
                          [[ronda_id, apodo, estado, dias, round(roi,4), asesino, comodin, equipos_str]])
                pit_load_players.clear()
                return
    except Exception:
        pass

def pit_usar_comodin(ronda_id: str, apodo: str):
    ss = get_ss()
    if not ss: return
    ws = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
    rows = _safe_get_records(ws)
    for i, r in enumerate(rows):
        if str(r.get("ronda_id","")) == str(ronda_id) and r.get("apodo","").lower() == apodo.lower():
            ws.update_cell(i+2, 7, "0")
            pit_load_players.clear()
            for _k in ["pit_players","pit_picks","pit_ronda"]: st.session_state.pop(_k,None)
            return

# ─────────────────────────────────────────────────────────────
#  THE PIT — King Rongo AI taunts
# ─────────────────────────────────────────────────────────────
RONGO_TAUNTS_ELIM = [
    "👑 King Rongo dice: '{apodo}' confió en '{pick}' y el foso se lo tragó. Quedan {vivos} vivos.",
    "💀 ELIMINADO: '{apodo}' apostó por '{pick}'. Un clásico error de principiante. {vivos} siguen en pie.",
    "🩸 El foso exige otro sacrificio. '{apodo}' apostó '{pick}' y el árbitro fue su verdugo. {vivos} sobreviven.",
    "⚰️ '{apodo}' creyó en '{pick}'. The Pit no perdona la fe ciega. Quedan {vivos} luchadores.",
    "🔥 King Rongo anuncia: '{apodo}' ha caído. Su arma fue '{pick}'. {vivos} aún respiran en el foso.",
]
RONGO_TAUNTS_WIN = [
    "👑 '{apodo}' sobrevivió el Día {dia} con '{pick}'. El foso respeta a los valientes.",
    "⚡ '{apodo}' sigue vivo. '{pick}' fue su salvación hoy. Día {dia} completado.",
    "🩸 El foso no pudo con '{apodo}' hoy. '{pick}' los mantuvo con vida. Día {dia}.",
]

def rongo_taunt_elim(apodo: str, pick: str, vivos: int) -> str:
    import random
    t = random.choice(RONGO_TAUNTS_ELIM)
    return t.format(apodo=apodo, pick=pick, vivos=vivos)

def rongo_taunt_win(apodo: str, pick: str, dia: int) -> str:
    import random
    t = random.choice(RONGO_TAUNTS_WIN)
    return t.format(apodo=apodo, pick=pick, dia=dia)

# ─────────────────────────────────────────────────────────────
#  THE PIT — Pick del Rey (best pick algorithm)
# ─────────────────────────────────────────────────────────────
def pit_pick_del_rey(ronda_picks: list) -> str:
    """
    Simple algorithm: find the pick with the best momio >= 1.50
    that hasn't been used much this round, and that has momio 1.50-2.50 range
    (sweet spot: high enough odds, not a coinflip).
    Returns a suggestion string.
    """
    if not ronda_picks:
        return "No hay suficiente data esta ronda para calcular el Pick del Rey."
    ganados = [p for p in ronda_picks if p.get("resultado") == "ganado"]
    if not ganados:
        return "King Rongo aún no tiene data suficiente esta ronda. Vuelve después del Día 2."
    # Group by pick_desc, calculate win rate
    from collections import defaultdict
    stats = defaultdict(lambda: {"g":0,"t":0,"momio_sum":0})
    for p in ronda_picks:
        k = p.get("pick_desc","")
        stats[k]["t"] += 1
        stats[k]["momio_sum"] += float(p.get("momio", 1.5))
        if p.get("resultado") == "ganado":
            stats[k]["g"] += 1
    best = None; best_score = -1
    for pick, s in stats.items():
        if s["t"] < 2: continue
        wr    = s["g"] / s["t"]
        avg_m = s["momio_sum"] / s["t"]
        if avg_m < 1.50: continue
        score = wr * avg_m  # reward high win rate AND good odds
        if score > best_score:
            best_score = score
            best = (pick, wr, avg_m, s["t"])
    if not best:
        return "King Rongo necesita más data (mín. 2 picks por tipo). Vuelve mañana."
    pick, wr, avg_m, cnt = best
    return (f"👑 **Pick del Rey:** `{pick}`  \n"
            f"Win rate histórico esta ronda: **{wr*100:.0f}%** en {cnt} picks  \n"
            f"Momio promedio: **{avg_m:.2f}**  \n"
            f"*Usa este conocimiento con sabiduría. The Pit no garantiza nada.*")


# ─────────────────────────────────────────────────────────────
#  THE PIT — Daily 4 random games generator
# ─────────────────────────────────────────────────────────────
# One representative league per sport for the daily card
PIT_DAILY_SPORTS = [
    ("⚽ Fútbol",      "soccer",     ["eng.1","esp.1","ita.1","ger.1","fra.1","mex.1","usa.1",
                                       "uefa.champions","conmebol.libertadores","fifa.friendly",
                                       "fifa.worldq.6","fifa.worldq.europe","concacaf.worldq",
                                       "fifa.worldq","uefa.worldq","fifa.worldq.5","fifa.worldq.2"]),
    ("🏀 Basketball",  "basketball", ["nba"]),
    ("🏈 NFL",         "football",   ["nfl"]),
    ("⚾ Baseball",    "baseball",   ["mlb"]),
    ("🏒 Hockey",      "hockey",     ["nhl"]),
]

@st.cache_data(ttl=3600, show_spinner=False)  # refresh every hour
def pit_get_daily_games(seed_date: str) -> list:
    """
    Fetch 4 random upcoming games from different sports for today's PIT card.
    seed_date = str(date.today()) so cache refreshes daily.
    Returns list of event dicts with extra 'pit_sport_label' and 'pit_liga_name' keys.
    """
    import random as _rnd
    _rnd.seed(seed_date)  # deterministic per day — same games for all users

    candidates = []  # (sport_label, sport, liga_name, event)
    sports_to_try = list(PIT_DAILY_SPORTS)
    _rnd.shuffle(sports_to_try)

    for sport_label, sport, leagues in sports_to_try:
        _rnd.shuffle(leagues)
        found = False
        for league in leagues:
            try:
                url = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
                r   = requests.get(url, params={"limit": 50}, timeout=6)
                if r.status_code != 200:
                    continue
                events = r.json().get("events", [])
                upcoming = []
                for ev in events:
                    st_type   = ev.get("status", {}).get("type", {})
                    state     = st_type.get("state", "pre")
                    completed = (state == "post") or st_type.get("completed", False)
                    if completed:
                        continue
                    comps = ev.get("competitions", [{}])[0].get("competitors", [])
                    home_c = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                    away_c = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                    home_i = _extract_competitor_info(home_c, sport)
                    away_i = _extract_competitor_info(away_c, sport)
                    # Skip if both names unknown/TBD
                    if home_i["name"] in ("?","TBD","") and away_i["name"] in ("?","TBD",""):
                        continue
                    # For tennis skip if either is TBD
                    if sport == "tennis" and (home_i["name"] in ("?","TBD","") or away_i["name"] in ("?","TBD","")):
                        continue
                    date_raw = ev.get("date","")
                    try:
                        dt     = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                        dt_mx  = dt - timedelta(hours=6)
                        d_str  = dt_mx.strftime("%d %b %H:%M")
                    except Exception:
                        d_str = date_raw[:10]
                    is_live = (state == "in") and not completed
                    upcoming.append({
                        "id":         ev.get("id",""),
                        "home":       home_i["name"], "away": away_i["name"],
                        "home_logo":  home_i["logo"], "away_logo": away_i["logo"],
                        "home_flag":  home_i["flag"], "away_flag": away_i["flag"],
                        "date":       d_str, "date_raw": date_raw,
                        "is_live":    is_live, "sport": sport,
                        "pit_sport_label": sport_label,
                        "pit_liga_name":   league.replace("."," ").upper(),
                    })
                if upcoming:
                    pick = _rnd.choice(upcoming)
                    candidates.append(pick)
                    found = True
                    break
            except Exception:
                continue
        if not found:
                # Try same league but with tomorrow's date explicitly
                try:
                    tomorrow_str = (date.today() + timedelta(days=1)).strftime("%Y%m%d")
                    for league in leagues:
                        url2 = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
                        r2 = requests.get(url2, params={"dates": tomorrow_str, "limit":50}, timeout=6)
                        if r2.status_code == 200:
                            evts2 = r2.json().get("events",[])
                            upcoming2 = []
                            for ev in evts2:
                                st2 = ev.get("status",{}).get("type",{})
                                if (st2.get("state","pre") == "post") or st2.get("completed",False):
                                    continue
                                comps = ev.get("competitions",[{}])[0].get("competitors",[])
                                hc = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                                ac = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                                hi = _extract_competitor_info(hc, sport)
                                ai = _extract_competitor_info(ac, sport)
                                date_raw = ev.get("date","")
                                try:
                                    dt = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                                    d_str = (dt - timedelta(hours=6)).strftime("%d %b %H:%M")
                                except Exception:
                                    d_str = date_raw[:10]
                                upcoming2.append({
                                    "id": ev.get("id",""), "home": hi["name"], "away": ai["name"],
                                    "home_logo": hi["logo"], "away_logo": ai["logo"],
                                    "home_flag": hi["flag"], "away_flag": ai["flag"],
                                    "date": d_str, "date_raw": date_raw,
                                    "is_live": False, "sport": sport,
                                    "pit_sport_label": sport_label,
                                    "pit_liga_name": league.replace("."," ").upper(),
                                })
                            if upcoming2:
                                candidates.append(_rnd.choice(upcoming2))
                                found = True
                                break
                except Exception:
                    pass
        if found and len(candidates) >= 4:
            break

    return candidates[:4]




@st.cache_data(ttl=30, show_spinner=False)
def pit_get_games_for_date(target_date_str: str) -> list:
    """
    Fetch games SPECIFICALLY for target_date (YYYYMMDD format).
    Returns list of upcoming games for that date only.
    """
    import random as _rnd
    
    candidates = []
    sports_to_try = list(PIT_DAILY_SPORTS)
    _rnd.seed(target_date_str)
    _rnd.shuffle(sports_to_try)
    
    # Convertir target_date_str a date object para comparación
    try:
        target_date = datetime.strptime(target_date_str, "%Y%m%d").date()
    except:
        return []
    
    for sport_label, sport, leagues in sports_to_try:
        _rnd.shuffle(leagues)
        found = False
        
        for league in leagues:
            try:
                # Buscar con la fecha específica
                url = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
                r = requests.get(url, params={"dates": target_date_str, "limit": 50}, timeout=6)
                
                if r.status_code != 200:
                    continue
                
                events = r.json().get("events", [])
                upcoming = []
                
                for ev in events:
                    st_type = ev.get("status", {}).get("type", {})
                    state = st_type.get("state", "pre")
                    completed = (state == "post") or st_type.get("completed", False)
                    
                    if completed:
                        continue
                    
                    # Verificar que sea de target_date
                    date_raw = ev.get("date", "")
                    try:
                        dt = datetime.fromisoformat(date_raw.replace("Z", "+00:00"))
                        dt_cdmx = dt - timedelta(hours=6)
                        ev_date = dt_cdmx.date()
                        
                        if ev_date != target_date:
                            continue
                    except:
                        continue
                    
                    comps = ev.get("competitions", [{}])[0].get("competitors", [])
                    home_c = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                    away_c = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                    home_i = _extract_competitor_info(home_c, sport)
                    away_i = _extract_competitor_info(away_c, sport)
                    
                    if home_i["name"] in ("?","TBD","") and away_i["name"] in ("?","TBD",""):
                        continue
                    
                    d_str = dt_cdmx.strftime("%d %b %H:%M")
                    
                    upcoming.append({
                        "id": ev.get("id",""),
                        "home": home_i["name"], "away": away_i["name"],
                        "home_logo": home_i["logo"], "away_logo": away_i["logo"],
                        "home_flag": home_i["flag"], "away_flag": away_i["flag"],
                        "date": d_str, "date_raw": date_raw,
                        "sport": sport,
                        "pit_sport_label": sport_label,
                    })
                
                if upcoming:
                    pick = _rnd.choice(upcoming)
                    candidates.append(pick)
                    found = True
                    break
            
            except Exception:
                continue
        
        if not found:
            continue
    
    return candidates[:4]


def pit_auto_grade(apodo: str, ronda_id: str, my_record: dict) -> tuple[int, int]:
    """
    ✅ AUTO-GRADE THE PIT: Busca por NOMBRE de partido (IGUAL A REGISTRAR)
    - NO depende de event_id
    - Carga todos los partidos de ESPN
    - Busca por NOMBRE normalizado
    - Funciona con amistosos, ligas, todo
    """
    ss = get_ss()
    if not ss: return 0, 0

    try:
        ws_picks   = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
        all_picks  = _safe_get_records(ws_picks)
        
        # Buscar picks PENDIENTES de este jugador en esta ronda
        my_pending = [
            (i, r) for i, r in enumerate(all_picks)
            if str(r.get("ronda_id","")) == str(ronda_id)
            and r.get("apodo","").lower() == apodo.lower()
            and r.get("resultado","pendiente") == "pendiente"
        ]
        if not my_pending:
            return 0, 0

        ganados = 0
        perdidos = 0
        
        import requests
        import re as re_mod
        
        # Cargar TODOS los partidos de hoy (IGUAL A auto_grade_pending)
        all_today = {}
        sports_map = {
            "soccer": ["eng.1", "esp.1", "ita.1", "ger.1", "fra.1", "mex.1", "usa.1", "bra.1", "international-friendly"],
            "basketball": ["nba"],
            "hockey": ["nhl"],
            "baseball": ["mlb"],
        }
        
        for sport, leagues in sports_map.items():
            all_today[sport] = {}
            for league_slug in leagues:
                try:
                    url = f"https://site.api.espn.com/apis/site/v2/sports/{sport}/{league_slug}/events"
                    resp = requests.get(url, timeout=5)
                    if resp.status_code == 200:
                        data = resp.json()
                        events = data.get("events", [])
                        league_events = []
                        for evt in events:
                            comp = evt.get("competitions", [{}])[0]
                            competitors = comp.get("competitors", [])
                            if len(competitors) >= 2:
                                away = competitors[1].get("team", {}).get("name", "?")
                                home = competitors[0].get("team", {}).get("name", "?")
                                away_score = int(competitors[1].get("score", -1)) if competitors[1].get("score") is not None else -1
                                home_score = int(competitors[0].get("score", -1)) if competitors[0].get("score") is not None else -1
                                league_events.append({
                                    "away": away, "home": home,
                                    "away_score": away_score, "home_score": home_score,
                                })
                        all_today[sport][league_slug] = league_events
                except Exception:
                    all_today[sport][league_slug] = []
        
        def normalize_name(name: str) -> str:
            """Quita acentos, caracteres especiales, espacios"""
            name = ''.join(c for c in __import__('unicodedata').normalize('NFD', name)
                          if __import__('unicodedata').category(c) != 'Mn')
            name = re_mod.sub(r'[^a-z0-9\s]', '', name.lower().strip())
            return name
        
        def find_match(partido, deporte, all_today_events):
            """Busca match según deporte. Soccer usa 'vs', otros usan '@'"""
            if deporte.lower() == "soccer":
                partido_clean = partido.replace("@", " vs ").lower().strip()
                sep = " vs "
            else:
                partido_clean = partido.replace(" vs ", "@").lower().strip()
                sep = "@"
            
            if sep not in partido_clean:
                return (False, -1, -1)
            
            try:
                parts = partido_clean.split(sep)
                away_guardado = parts[0].strip()
                home_guardado = parts[1].strip()
            except:
                return (False, -1, -1)
            
            away_norm = normalize_name(away_guardado)
            home_norm = normalize_name(home_guardado)
            
            # Buscar en TODOS los sports
            for sport_key, sport_leagues in all_today_events.items():
                for league_slug, league_matches in sport_leagues.items():
                    for m in league_matches:
                        m_away_norm = normalize_name(m.get("away", ""))
                        m_home_norm = normalize_name(m.get("home", ""))
                        
                        # Match directo
                        if away_norm == m_away_norm and home_norm == m_home_norm:
                            return (True, m.get("away_score", -1), m.get("home_score", -1))
            
            return (False, -1, -1)
        
        # Calificar cada pick pendiente
        for row_idx, pick_row in my_pending:
            partido = pick_row.get("partido", "")
            deporte = pick_row.get("deporte", "soccer")
            pick_desc = str(pick_row.get("pick_desc", "")).strip().lower()
            
            # Buscar partido
            found, away_score, home_score = find_match(partido, deporte, all_today)
            
            if not found or away_score < 0 or home_score < 0:
                continue  # Partido no encontrado o sin scores
            
            # Determinar ganador
            if home_score > away_score:
                winner = "home"
            elif away_score > home_score:
                winner = "away"
            else:
                winner = "draw"
            
            # Calificar pick
            resultado = None
            if "empate" in pick_desc or "draw" in pick_desc:
                resultado = "ganado" if winner == "draw" else "perdido"
            else:
                # Extraer equipos del partido para matchear con pick_desc
                try:
                    if deporte.lower() == "soccer":
                        parts = partido.replace("@", " vs ").split(" vs ")
                    else:
                        parts = partido.split("@")
                    away_text = normalize_name(parts[0].strip()) if len(parts) > 0 else ""
                    home_text = normalize_name(parts[1].strip()) if len(parts) > 1 else ""
                except:
                    away_text = ""
                    home_text = ""
                
                # Matchear pick_desc con teams
                pick_is_home = any(w in pick_desc for w in home_text.split() if len(w) > 2)
                pick_is_away = any(w in pick_desc for w in away_text.split() if len(w) > 2)
                
                if not pick_is_home and not pick_is_away:
                    # Try first 4 chars
                    pick_is_home = home_text[:4] in pick_desc
                    pick_is_away = away_text[:4] in pick_desc
                
                if pick_is_home:
                    resultado = "ganado" if winner == "home" else "perdido"
                elif pick_is_away:
                    resultado = "ganado" if winner == "away" else "perdido"
            
            if resultado is None:
                continue
            
            # Actualizar Google Sheets
            try:
                ws_picks.update_cell(row_idx + 2, 10, resultado)  # col 10 = resultado
            except Exception:
                pass
            
            if resultado == "ganado":
                ganados += 1
            else:
                perdidos += 1
        
        # Actualizar estado del jugador si hay picks calificados
        if ganados > 0 or perdidos > 0:
            dias_vivo = int(my_record.get("dias_vivo", 0))
            roi_acum  = float(my_record.get("roi_acum", 0))

            # Get current player count for chat messages
            try:
                all_players = pit_load_players(ronda_id)
                n_vivos_cur = sum(1 for p in all_players if p.get("estado") == "vivo")
            except Exception:
                n_vivos_cur = 0

            if perdidos > 0:
                comodin = str(my_record.get("comodin_disponible","0")) == "1"
                if comodin:
                    pit_usar_comodin(ronda_id, apodo)
                    pit_save_chat("King Rongo",
                        f"🛡 **{apodo}** activó su Comodín de Badrino y sobrevivió. ¡La suerte no dura forever.", True)
                else:
                    # Get last pick description for asesino
                    try:
                        _ss2 = get_ss()
                        ws_p = ensure_tab(_ss2, "pit_picks", PIT_PICKS_HEADERS) if _ss2 else None
                        all_p = _safe_get_records(ws_p) if ws_p else []
                        my_p  = [r for r in all_p
                                 if str(r.get("ronda_id",""))==str(ronda_id)
                                 and r.get("apodo","").lower()==apodo.lower()]
                        asesino = my_p[-1].get("pick_desc","?") if my_p else "?"
                    except Exception:
                        asesino = "?"
                    pit_update_player(
                        ronda_id, apodo, "eliminado",
                        dias_vivo, roi_acum, asesino,
                        my_record.get("equipos_usados","")
                    )
                    pit_load_players.clear()
                    for _k in ["pit_players","pit_picks"]:
                        st.session_state.pop(_k, None)
                    pit_save_chat("King Rongo",
                        f"💀 **{apodo.upper()}** ELIMINADO. `{asesino}` los traicionó. "
                        f"Quedan {max(0,n_vivos_cur-1)} gladiadores.", True)
            else:
                pit_update_player(
                    ronda_id, apodo, "vivo",
                    dias_vivo + 1, roi_acum,
                    "", my_record.get("equipos_usados","")
                )
                pit_load_players.clear()
                for _k in ["pit_players","pit_picks"]:
                    st.session_state.pop(_k, None)
                pit_save_chat("King Rongo",
                    f"✅ **{apodo}** sobrevivió el Día {dias_vivo+1}. "
                    f"{n_vivos_cur} gladiadores aún respiran.", True)

        return ganados, perdidos

    except Exception:
        return 0, 0


# ─────────────────────────────────────────────────────────────
#  THE PIT — Main tab
# ─────────────────────────────────────────────────────────────
def tab_the_pit(apodo: str, bank: float):
    """THE PIT: 3 VIDAS, AUTO-GRADING, WASTED/CONGRATS EFFECTS"""
    from datetime import datetime, timedelta, date
    import random as _rnd_pit
    
    # Hora CDMX
    now_utc = datetime.utcnow()
    now_cdmx = now_utc + timedelta(hours=-6)
    today_cdmx = now_cdmx.date()
    hour_cdmx = now_cdmx.hour
    daily_seed = int(today_cdmx.strftime("%Y%m%d"))
    
    # ═══════════════════════════════════════════════════════════════
    #  PICK TYPE DEL DÍA (ALEATORIO PERO REPRODUCIBLE)
    # ═══════════════════════════════════════════════════════════════
    _rnd_pit.seed(daily_seed)
    pick_type_hoy = _rnd_pit.choice(["ML", "O/U"])
    
    # HEADER
    st.markdown("""
    <style>
        .pit-container {
            background: linear-gradient(135deg, rgba(139,0,0,0.3) 0%, rgba(0,0,0,0.8) 100%);
            border: 3px solid #DC143C;
            border-radius: 16px;
            padding: 40px;
            margin-bottom: 30px;
            box-shadow: 0 0 50px rgba(220,20,60,0.8), inset 0 0 30px rgba(220,20,60,0.2);
        }
        .pit-title {
            font-size: 5rem;
            font-weight: 900;
            color: #FF2D55;
            text-align: center;
            letter-spacing: 12px;
            text-shadow: 0 0 30px #DC143C, 0 0 60px #FF4500;
            margin: 20px 0;
        }
    </style>
    
    <div class="pit-container">
        <div style="text-align: center; font-size: 3rem; margin-bottom: 10px;">
            ☠️ 🗡️ ⚔️ 🩸 💀
        </div>
        <div class="pit-title">THE PIT</div>
        <div style="text-align: center; color: #FF6B6B; font-size: 1.1rem; letter-spacing: 4px; text-transform: uppercase; margin: 15px 0;">
            🔥 3 VIDAS - GANA O MUERE 🔥
        </div>
    </div>
    """, unsafe_allow_html=True)
    
    # ✅ BOTÓN DE REFRESH PARA ACTUALIZAR LA TABLA EN TIEMPO REAL
    col_ref = st.columns([10, 1])[1]
    with col_ref:
        if st.button("🔄", help="Actualizar tabla de picks en tiempo real", key="pit_refresh_main"):
            st.session_state.pop("pit_picks", None)
            st.rerun()
    
    # CARGAR RONDA
    if "pit_ronda" not in st.session_state:
        st.session_state["pit_ronda"] = pit_load_ronda_activa()
    ronda = st.session_state["pit_ronda"]

    if not ronda:
        st.error("⚠️ El Foso está vacío")
        c = st.columns([2,1,2])[1]
        with c:
            if st.button("⚔ ABRIR EL FOSO", type="primary", use_container_width=True):
                rid = pit_crear_ronda()
                if rid:
                    st.success(f"🩸 ¡RONDA #{rid}!")
                    st.session_state.pop("pit_ronda", None)
                    st.rerun()
        return

    ronda_id = str(ronda["ronda_id"])
    
    # ✅ AUTO-REGISTRAR USUARIO EN LA RONDA SI NO EXISTE
    pit_auto_registrar_usuario(apodo, ronda_id)
    
    # Cargar datos SIN CACHEO
    players = pit_load_players(ronda_id)
    ronda_picks = pit_load_picks_ronda(ronda_id)

    # Get user record
    my_record = next((p for p in players if p.get("apodo","").lower() == apodo.lower()), None)
    
    if not my_record:
        st.error(f"⚠️ No estás en esta ronda")
        return
    
    # Get current lives y estado
    vidas_raw = my_record.get("vidas", "3")
    try:
        my_vidas = int(vidas_raw) if vidas_raw and vidas_raw.strip() else 3
    except:
        my_vidas = 3
    
    # Si vidas es 0 o negativo, reiniciar a 3
    if my_vidas <= 0:
        my_vidas = 3
    
    my_estado = my_record.get("estado", "vivo")
    
    # ═══════════════════════════════════════════════════════════════
    #  INICIALIZAR VIDAS EN GOOGLE SHEETS SI NO EXISTEN
    # ═══════════════════════════════════════════════════════════════
    try:
        ss = get_ss()
        if ss and my_vidas == 3:  # Solo si tiene 3 vidas (initialization)
            ws_players = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
            all_rows = ws_players.get_all_values()
            
            # Buscar la fila del usuario y actualizar vidas si están vacías
            for idx, row in enumerate(all_rows):
                if (idx > 0 and  # Skip header
                    len(row) > 1 and
                    row[0] == str(ronda_id) and 
                    row[1] == apodo):
                    # Columna vidas está en posición 3
                    if idx + 1 > 0:  # Row number
                        try:
                            ws_players.update_cell(idx + 1, 4, str(my_vidas))
                        except:
                            pass
                    break
    except:
        pass
    
    # ═══════════════════════════════════════════════════════════════
    #  AUTO-GRADING: Detectar resultados y restar vidas
    # ═══════════════════════════════════════════════════════════════
    fx_to_show = None
    grading_debug = []
    
    try:
        ss = get_ss()
        if ss:
            ws_picks = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            _rate_limit_gs("pit_picks_load", 0.5)

            all_picks_sheet = _safe_get_records(ws_picks)
            
            # Obtener picks de AYER (para auto-gradarlos HOY)
            yesterday = today_cdmx - timedelta(days=1)
            yesterday_picks = [p for p in all_picks_sheet
                              if str(p.get("ronda_id","")).strip() == str(ronda_id) and
                                 str(p.get("fecha","")).strip() == str(yesterday) and
                                 str(p.get("apodo","")).lower().strip() == apodo.lower().strip() and
                                 str(p.get("resultado","")).lower().strip() == "pendiente"]
            
            grading_debug.append(f"🔍 Picks pendientes de {yesterday}: {len(yesterday_picks)}")
            
            # Auto-grade cada pick pendiente de ayer
            for pick in yesterday_picks:
                event_id = pick.get("event_id", "")
                pick_desc = pick.get("pick_desc", "")
                pick_type = "ML" if pick_desc in ["Home", "Away"] else "O/U"
                partido = pick.get("partido", "")
                
                grading_debug.append(f"  📋 {partido} - Pick: {pick_desc} (Type: {pick_type})")
                
                if not event_id:
                    grading_debug.append(f"    ❌ Sin event_id")
                    continue
                
                # Obtener resultado de ESPN - Try multiple endpoints
                resultado_espn = None
                espn_data = None
                home_score = None
                away_score = None
                
                # Try common ESPN sports endpoints
                espn_urls = [
                    f"http://site.api.espn.com/apis/site/v2/sports/baseball/mlb/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/basketball/nba/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/hockey/nhl/events/{event_id}",
                    # Soccer - multiple leagues
                    f"http://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/soccer/fra.1/events/{event_id}",
                    f"http://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/events/{event_id}",
                ]
                
                for espn_url in espn_urls:
                    try:
                        r = requests.get(espn_url, timeout=5)
                        if r.status_code == 200:
                            espn_data = r.json()
                            grading_debug.append(f"    ✅ ESPN API encontrado")
                            break
                    except:
                        continue
                
                if espn_data:
                    try:
                        competition = espn_data.get("competitions", [{}])[0]
                        status = competition.get("status", {}).get("type", "")
                        
                        grading_debug.append(f"    Status: {status}")
                        
                        if status == "STATUS_FINAL":
                            competitors = competition.get("competitors", [])
                            if len(competitors) >= 2:
                                home_score = int(competitors[0].get("score", 0))
                                away_score = int(competitors[1].get("score", 0))
                                total_score = home_score + away_score
                                
                                grading_debug.append(f"    Resultado: {away_score} - {home_score} (Total: {total_score})")
                                
                                # Procesar según pick type
                                if pick_type == "ML":
                                    winner = "Home" if home_score > away_score else "Away"
                                    resultado = "ganado" if pick_desc == winner else "perdido"
                                    grading_debug.append(f"    ML: Ganador={winner}, Tu pick={pick_desc} → {resultado.upper()}")
                                else:
                                    # O/U
                                    pick_value = float(pick_desc.replace("O", "").replace("U", ""))
                                    if pick_desc.startswith("O"):
                                        resultado = "ganado" if total_score > pick_value else "perdido"
                                        grading_debug.append(f"    O/U: {total_score} {'>' if total_score > pick_value else '<'} {pick_value} (O{pick_value}) → {resultado.upper()}")
                                    else:
                                        resultado = "ganado" if total_score < pick_value else "perdido"
                                        grading_debug.append(f"    O/U: {total_score} {'<' if total_score < pick_value else '>'} {pick_value} (U{pick_value}) → {resultado.upper()}")
                                
                                resultado_espn = resultado
                        else:
                            grading_debug.append(f"    ⏳ Partido aún no finalizado")
                    except Exception as e:
                        grading_debug.append(f"    ❌ Error procesando: {str(e)[:50]}")
                else:
                    grading_debug.append(f"    ❌ No se encontró en ESPN")
                
                # Si detectamos resultado, actualizar en Google Sheets
                if resultado_espn:
                    # Buscar la fila del pick en Google Sheets
                    all_rows = ws_picks.get_all_values()
                    for idx, row in enumerate(all_rows):
                        if (idx > 0 and  # Skip header
                            row[0] == str(ronda_id) and  # ronda_id
                            row[3] == apodo and  # apodo
                            row[2] == str(yesterday) and  # fecha
                            row[7] == pick_desc):  # pick_desc
                            # Actualizar resultado en columna 9 (resultado)
                            ws_picks.update_cell(idx + 1, 10, resultado_espn)
                            grading_debug.append(f"    💾 Actualizado en GSheets: {resultado_espn}")
                            
                            # Aplicar efecto
                            if resultado_espn == "perdido":
                                fx_to_show = "wasted"
                                # Restar una vida
                                my_vidas -= 1
                                if my_vidas <= 0:
                                    # Marcar como eliminado
                                    ws_players = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
                                    for p_idx, p_row in enumerate(ws_players.get_all_values()):
                                        if (p_idx > 0 and p_row[0] == str(ronda_id) and p_row[1] == apodo):
                                            ws_players.update_cell(p_idx + 1, 3, "eliminado")  # estado
                                            ws_players.update_cell(p_idx + 1, 4, str(my_vidas))  # vidas
                            else:
                                fx_to_show = "confetti"
                                # No restar vida
                            
                            # Actualizar vidas en Google Sheets
                            ws_players = ensure_tab(ss, "pit_jugadores", PIT_PLAYERS_HEADERS)
                            for p_idx, p_row in enumerate(ws_players.get_all_values()):
                                if (p_idx > 0 and p_row[0] == str(ronda_id) and p_row[1] == apodo):
                                    ws_players.update_cell(p_idx + 1, 4, str(my_vidas))  # vidas
                            
                            break
    except Exception as e:
        pass
    
    # Mostrar efecto si aplica
    if fx_to_show == "wasted":
        st.markdown('<div class="wasted-overlay">W A S T E D</div>', unsafe_allow_html=True)
    elif fx_to_show == "confetti":
        st.balloons()
    
    # ═══════════════════════════════════════════════════════════════
    #  DISPLAY VIDAS
    # ═══════════════════════════════════════════════════════════════
    vidas_display = "💚 " * my_vidas + "💀 " * (3 - my_vidas)
    st.markdown(f"<div style='text-align: center; font-size: 2rem; margin: 20px 0;'>{vidas_display}</div>", unsafe_allow_html=True)
    
    # ═══════════════════════════════════════════════════════════════
    # ✅ TABLA DE PICKS - EN TIEMPO REAL (ACTUALIZA AUTOMÁTICAMENTE)
    # ═══════════════════════════════════════════════════════════════
    try:
        ss = get_ss()
        if ss:
            ws_picks = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            _rate_limit_gs("pit_picks_table", 0.5)
            all_picks_sheet = _safe_get_records(ws_picks)
            
            # Filtrar picks de la ronda actual
            ronda_picks = [p for p in all_picks_sheet
                          if str(p.get("ronda_id","")).strip() == str(ronda_id)]
            
            if ronda_picks:
                st.markdown("""
                <div style="background: rgba(220,20,60,0.15); border: 2px solid rgba(220,20,60,0.4); 
                border-radius: 12px; padding: 16px; margin-bottom: 20px;">
                <div style="font-family: Bebas Neue; font-size: 1.2rem; color: #FFB800; letter-spacing: 1px;">
                📊 PICKS DE LA RONDA EN VIVO
                </div>
                """, unsafe_allow_html=True)
                
                # Preparar datos para tabla
                table_data = []
                for pick in ronda_picks:
                    partido_fmt = format_partido_para_display(pick.get("partido", "?"), pick.get("deporte", "soccer"))
                    resultado = pick.get("resultado", "pendiente")
                    
                    # Color según resultado
                    if resultado == "ganado":
                        resultado_icon = "✅ GANADO"
                    elif resultado == "perdido":
                        resultado_icon = "❌ PERDIDO"
                    elif resultado == "nulo":
                        resultado_icon = "↔️ NULO"
                    else:
                        resultado_icon = "⏳ PENDIENTE"
                    
                    table_data.append({
                        "Apodo": pick.get("apodo", "?"),
                        "Partido": partido_fmt,
                        "Pick": pick.get("pick_desc", "?"),
                        "Momio": pick.get("momio", "?"),
                        "Resultado": resultado_icon,
                    })
                
                df_picks_table = pd.DataFrame(table_data)
                st.dataframe(df_picks_table, use_container_width=True, hide_index=True)
                
                st.markdown("</div>", unsafe_allow_html=True)
    except Exception as e:
        pass
    
    # ═══════════════════════════════════════════════════════════════
    #  TEST MANUAL DE AUTO-CALIFICACIÓN (para debugging)
    # ═══════════════════════════════════════════════════════════════
    try:
        ss = get_ss()
        if ss:
            ws_picks = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            _rate_limit_gs("pit_picks_load", 0.5)

            all_picks_sheet = _safe_get_records(ws_picks)
            
            # ✅ TABLA CON TODOS LOS PICKS DE LA RONDA
            ronda_picks = [p for p in all_picks_sheet
                          if str(p.get("ronda_id","")).strip() == str(ronda_id)]
            
            if ronda_picks:
                st.markdown('<div style="font-family: Bebas Neue; font-size: 1rem; color: #FFB800; letter-spacing: 1px; margin: 15px 0 10px;">📊 PICKS DE LA RONDA</div>', unsafe_allow_html=True)
                
                # Preparar datos para tabla
                table_data = []
                for pick in ronda_picks:
                    partido_fmt = format_partido_para_display(pick.get("partido", "?"), pick.get("deporte", "soccer"))
                    table_data.append({
                        "Apodo": pick.get("apodo", "?"),
                        "Partido": partido_fmt,
                        "Liga": pick.get("liga", "?"),
                        "Pick": pick.get("pick_desc", "?"),
                        "Momio": pick.get("momio", "?"),
                        "Resultado": pick.get("resultado", "pendiente"),
                        "Día": pick.get("dia", "?"),
                    })
                
                df_picks_table = pd.DataFrame(table_data)
                st.dataframe(df_picks_table, use_container_width=True, hide_index=True)
            
            with st.expander("📋 Picks de HOY + Prueba de Calificación"):
                # Get today's picks to test
                today_picks = [p for p in all_picks_sheet
                              if str(p.get("ronda_id","")).strip() == str(ronda_id) and
                                 str(p.get("fecha","")).strip() == str(today_cdmx) and
                                 str(p.get("apodo","")).lower().strip() == apodo.lower().strip()]
                
                if today_picks:
                    st.write(f"**Tus picks de HOY ({len(today_picks)}):**")
                    for idx, pick in enumerate(today_picks):
                        col1, col2, col3 = st.columns([2, 2, 1])
                        
                        with col1:
                            st.caption(f"**{format_partido_para_display(pick.get('partido', '?'), pick.get('deporte', 'soccer'))}**")
                        
                        with col2:
                            st.caption(f"Pick: {pick.get('pick_desc', '?')}")
                        
                        with col3:
                            col3a, col3b = st.columns(2)
                            with col3a:
                                if st.button("🧪 Probar", key=f"test_grade_{idx}", use_container_width=True):
                                    # Test grading this pick
                                    event_id = pick.get("event_id", "")
                                    pick_desc = pick.get("pick_desc", "")
                                    pick_type = "ML" if pick_desc in ["Home", "Away"] else "O/U"
                                    partido = pick.get("partido", "")
                                    
                                    test_debug = [f"🧪 TESTING: {partido}"]
                                    test_debug.append(f"  Pick: {pick_desc} ({pick_type})")
                                    test_debug.append(f"  Event ID: {event_id}")
                                    
                                    if not event_id:
                                        test_debug.append(f"  ❌ Sin event_id - No se puede probar")
                                    else:
                                        # Try ESPN endpoints
                                        espn_urls = [
                                            # Soccer - amistosos internacionales (friendly)
                                            f"http://site.api.espn.com/apis/site/v2/sports/soccer/international-friendly/events/{event_id}",
                                        # Soccer - main leagues
                                        f"http://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/soccer/fra.1/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/events/{event_id}",
                                        # Other sports
                                        f"http://site.api.espn.com/apis/site/v2/sports/baseball/mlb/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/basketball/nba/events/{event_id}",
                                        f"http://site.api.espn.com/apis/site/v2/sports/hockey/nhl/events/{event_id}",
                                    ]
                                    
                                    espn_data = None
                                    for url in espn_urls:
                                        try:
                                            r = requests.get(url, timeout=5)
                                            test_debug.append(f"  🔍 Probando: {url.split('/sports/')[1].split('/')[0]}")
                                            test_debug.append(f"     Status: {r.status_code}")
                                            if r.status_code == 200:
                                                espn_data = r.json()
                                                test_debug.append(f"  ✅ ESPN API encontrado")
                                                break
                                        except Exception as e:
                                            test_debug.append(f"  ⚠️ Error en request: {str(e)[:40]}")
                                            continue
                                    
                                    if not espn_data:
                                        test_debug.append(f"  ❌ No se encontró en ESPN (probadas 8 ligas)")
                                    else:
                                        try:
                                            competition = espn_data.get("competitions", [{}])[0]
                                            status = competition.get("status", {}).get("type", "")
                                            test_debug.append(f"  Status: {status}")
                                            
                                            if status != "STATUS_FINAL":
                                                test_debug.append(f"  ⏳ Partido aún NO finalizado")
                                                test_debug.append(f"     (Espera a que finalice para auto-calificar)")
                                            else:
                                                competitors = competition.get("competitors", [])
                                                if len(competitors) >= 2:
                                                    home_score = int(competitors[0].get("score", 0))
                                                    away_score = int(competitors[1].get("score", 0))
                                                    total_score = home_score + away_score
                                                    
                                                    test_debug.append(f"  Resultado: {away_score} - {home_score}")
                                                    test_debug.append(f"  Total: {total_score}")
                                                    
                                                    if pick_type == "ML":
                                                        winner = "Home" if home_score > away_score else "Away"
                                                        resultado = "✅ GANADO" if pick_desc == winner else "❌ PERDIDO"
                                                        test_debug.append(f"  ML: Ganador={winner} vs Tu pick={pick_desc}")
                                                        test_debug.append(f"  Resultado: {resultado}")
                                                    else:
                                                        pick_value = float(pick_desc.replace("O", "").replace("U", ""))
                                                        if pick_desc.startswith("O"):
                                                            resultado = "✅ GANADO" if total_score > pick_value else "❌ PERDIDO"
                                                            test_debug.append(f"  O/U: {total_score} {'>' if total_score > pick_value else '<'} {pick_value}")
                                                        else:
                                                            resultado = "✅ GANADO" if total_score < pick_value else "❌ PERDIDO"
                                                            test_debug.append(f"  O/U: {total_score} {'<' if total_score < pick_value else '>'} {pick_value}")
                                                        test_debug.append(f"  Resultado: {resultado}")
                                        except Exception as e:
                                            test_debug.append(f"  ❌ Error procesando: {str(e)[:50]}")
                                
                                # Show results
                                st.markdown("---")
                                for line in test_debug:
                                    st.caption(line)
                            
                            with col3b:
                                if st.button("✅ FORZAR", key=f"force_grade_{idx}", use_container_width=True):
                                    # FORZAR CALIFICACIÓN INMEDIATA (para testing)
                                    try:
                                        partido = pick.get("partido", "")
                                        pick_desc = pick.get("pick_desc", "").lower()
                                        deporte = pick.get("deporte", "soccer").lower()
                                        
                                        # Simular que el partido terminó y calificar
                                        resultado = _find_resultado_robusto(partido, deporte, pick_desc)
                                        
                                        if resultado:
                                            # Actualizar en Google Sheets
                                            try:
                                                ws_picks.update_cell(idx + 2 + len([p for p in all_picks_sheet if str(p.get("ronda_id","")) == str(ronda_id) and str(p.get("apodo","")).lower() == apodo.lower() and str(p.get("resultado","")) != "pendiente"]), 10, resultado)
                                                st.success(f"✅ Pick calificado como: **{resultado.upper()}**")
                                            except Exception as e:
                                                st.warning(f"⚠️ No se pudo actualizar: {str(e)[:50]}")
                                        else:
                                            st.error("❌ No se encontró resultado en ESPN")
                                    except Exception as e:
                                        st.error(f"Error: {str(e)[:100]}")
                else:
                    st.info("📭 No hay picks de hoy. Hace un pick primero para testear.")
            
            # ═══════════════════════════════════════════════════════════════
            #  EFFECTS SIMULATOR (Previewear WASTED y CONFETTI)
            # ═══════════════════════════════════════════════════════════════
            with st.expander("🎬 PREVIEW: Efectos Visuales (WASTED/CONFETTI)"):
                st.info("Aquí puedes previewear cómo se ven los efectos cuando ganas o pierdes")
                
                col1, col2 = st.columns(2)
                
                with col1:
                    if st.button("💀 Ver WASTED (Pierdes)", use_container_width=True, key="preview_wasted"):
                        st.markdown('<div class="wasted-overlay">W A S T E D</div>', unsafe_allow_html=True)
                        st.caption("👆 Este overlay aparece cuando pierdes un pick")
                
                with col2:
                    if st.button("🎉 Ver CONFETTI (Ganas)", use_container_width=True, key="preview_confetti"):
                        st.balloons()
                        st.success("🎊 ¡GANASTE! Aparece confetti y success message")
    except:
        pass
    
    # Si no tiene vidas, game over
    if my_vidas <= 0:
        st.error(f"💀 ELIMINADO - GAME OVER")
        return
    
    # STATUS
    vivos = [p for p in players if p.get("estado") == "vivo"]
    muertos = [p for p in players if p.get("estado") == "eliminado"]
    
    col1, col2, col3 = st.columns(3)
    with col1:
        st.metric("💀 ENTRARON", len(players))
    with col2:
        st.metric("💚 VIVOS", len(vivos))
    with col3:
        st.metric("🩸 CAÍDOS", len(muertos))

    if len(players) > 0:
        st.progress(len(muertos) / len(players))

    st.write("")
    
    # ═══════════════════════════════════════════════════════════════
    #  LEADERBOARD - TODOS LOS PARTICIPANTES Y SUS PICKS
    # ═══════════════════════════════════════════════════════════════
    st.markdown('<div style="font-family: Bebas Neue; font-size: 1.1rem; color: #FFB800; letter-spacing: 1px; margin: 15px 0 10px;">📊 LEADERBOARD - VIDAS Y PICKS</div>', unsafe_allow_html=True)
    
    try:
        ss = get_ss()
        if ss:
            ws_pit = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            all_picks_today = [p for p in _safe_get_records(ws_pit) 
                              if str(p.get("ronda_id", "")).strip() == str(ronda_id) and
                                 str(p.get("fecha", "")).strip() == str(today_cdmx.date())]
            
            # Build leaderboard data
            leaderboard_data = []
            for player in players:
                apodo_player = player.get("apodo", "")
                estado = player.get("estado", "?")
                vidas = int(player.get("vidas", 3))
                
                # Find pick for this player today
                player_pick = next((p for p in all_picks_today 
                                  if str(p.get("apodo", "")).lower().strip() == apodo_player.lower().strip()), None)
                
                if player_pick:
                    # Mejorar display: partido - pick
                    partido = player_pick.get("partido", "")
                    pick_desc = player_pick.get("pick_desc", "")
                    pick_display = f"{format_partido_para_display(partido, player_pick.get('deporte', 'soccer'))} - {pick_desc}" if partido and pick_desc else pick_desc or "—"
                else:
                    pick_display = "—"
                
                # Status emoji
                status_emoji = "💚" if estado == "vivo" else "💀" if estado == "eliminado" else "?"
                vidas_emoji = "💚" * vidas + "💀" * (3 - vidas)
                
                leaderboard_data.append({
                    "Estado": status_emoji,
                    "Apodo": apodo_player,
                    "Vidas": vidas_emoji,
                    "Pick": pick_display,
                })
            
            # Display as table
            if leaderboard_data:
                df_lb = pd.DataFrame(leaderboard_data)
                st.dataframe(df_lb, use_container_width=True, hide_index=True)
    except:
        pass

    st.write("")

    # ═══════════════════════════════════════════════════════════════
    #  4 PARTIDOS - PICK TYPE ALEATORIO POR DÍA
    # ═══════════════════════════════════════════════════════════════
    st.markdown(f"""
    <div style="text-align: center; font-family: Bebas Neue; font-size: 0.95rem; color: #FFB800;
         letter-spacing: 2px; margin: 15px 0 20px; background: rgba(255,180,0,0.1);
         border: 2px solid rgba(255,180,0,0.3); padding: 12px; border-radius: 8px;">
        📌 HOY: {pick_type_hoy} - {"🏆 QUIÉN GANA" if pick_type_hoy == "ML" else "📊 OVER/UNDER"}
    </div>
    """, unsafe_allow_html=True)
    
    # Obtener 1 de cada deporte: Soccer, Basketball, Hockey, Baseball
    daily_games = []
    # Map actual sport groups from load_all_today()
    sports_map = {
        "⚽ Fútbol — Clubes": "soccer",
        "🌍 Fútbol — Selecciones": "selecciones",
        "🏀 Basketball": "basketball",
        "⚾ Baseball": "baseball",
        "🏒 Hockey": "hockey",
    }
    sports_to_fetch = ["soccer", "basketball", "hockey", "baseball"]
    sports_found = set()
    debug_info = []
    
    try:
        all_today = load_all_today()
        debug_info.append(f"load_all_today() returned {len(all_today)} sport groups")
        debug_info.append(f"Sport groups: {list(all_today.keys())}")
        
        # all_today structure: {sport_group: {liga_name: [events]}}
        for sport_group, leagues_dict in all_today.items():
            debug_info.append(f"Processing {sport_group}: {len(leagues_dict)} leagues")
            
            # Map the sport group name
            mapped_sport = sports_map.get(sport_group, sport_group.lower())
            
            if mapped_sport not in sports_to_fetch:
                debug_info.append(f"  Skipping (not in sports_to_fetch)")
                continue
            if mapped_sport in sports_found:
                debug_info.append(f"  Skipping (already have {mapped_sport})")
                continue
            
            # Get first event from first league in this sport
            for liga_name, events in leagues_dict.items():
                debug_info.append(f"  {sport_group}/{liga_name}: {len(events)} events")
                
                if events and len(events) > 0:
                    event = events[0]  # Take first event
                    game_obj = {
                        "id": event.get("id", ""),
                        "away": event.get("away", "?"),
                        "home": event.get("home", "?"),
                        "liga": event.get("liga", liga_name),
                        "sport": mapped_sport,
                        "date": event.get("date", "")
                    }
                    daily_games.append(game_obj)
                    sports_found.add(mapped_sport)
                    debug_info.append(f"  ✅ Added ({mapped_sport}): {game_obj['home']} vs {game_obj['away']}")
                    break  # Got one from this sport, move to next sport
    except Exception as e:
        debug_info.append(f"ERROR: {str(e)}")
    
    # Show debug info
    if not daily_games:
        st.warning("⚠️ No games found. Debug info:")
        for info in debug_info:
            st.caption(info)
    
    # Reorder to ensure: Soccer, Basketball, Hockey, Baseball
    ordered_games = []
    for sport in sports_to_fetch:
        game = next((g for g in daily_games if g["sport"] == sport), None)
        if game:
            ordered_games.append(game)
    
    daily_games = ordered_games
    
    def get_picks_for_sport(sport, ptype):
        # Map sport groups to pick values - REALISTIC LINES
        sport_lines = {
            "soccer": 2.5,
            "basketball": 228.5,
            "hockey": 5.5,
            "baseball": 7.5,  # Changed from football to baseball
            "mlb": 7.5,  # Also support old format
            "nba": 228.5,
            "nhl": 5.5,
            "nfl": 49.5,
        }
        
        if ptype == "ML":
            return [("Home", "Home"), ("Away", "Away")]
        else:  # O/U
            line = sport_lines.get(sport, 2.5)
            return [(f"O{line}", f"O{line}"), (f"U{line}", f"U{line}")]
    
    for i, game in enumerate(daily_games):
        away = game.get("away", "?")
        home = game.get("home", "?")
        liga = game.get("liga", "?")
        game_id = game.get("id", "")
        sport = game.get("sport", "mlb")
        game_date = game.get("date", "")  # Date/time string
        
        st.markdown(f"""
        <div style="background: rgba(220,20,60,0.12); border: 2px solid rgba(220,20,60,0.3);
             border-radius: 10px; padding: 16px; margin-bottom: 15px;">
            <div style="font-weight: 700; color: #FF4500; margin-bottom: 8px;">{liga}</div>
            <div style="font-size: 1.1rem; color: #EEEEF5; font-weight: 700; margin-bottom: 6px;">
                {format_partido_para_display(f"{away}@{home}", sport)}
            </div>
            <div style="font-size: 0.85rem; color: #AAA; margin-top: 8px;">🕐 {game_date}</div>
        </div>
        """, unsafe_allow_html=True)
        
        picks = get_picks_for_sport(sport, pick_type_hoy)
        cols = st.columns(len(picks))
        
        for j, (label, value) in enumerate(picks):
            with cols[j]:
                # Deshabilitar botón si se está guardando un pick
                is_saving = st.session_state.get("pit_saving", False)
                disabled = is_saving
                
                if st.button(label, key=f"pit_pick_{i}_{j}", use_container_width=True, disabled=disabled):
                    # MARCAR que se está guardando para evitar doble click
                    st.session_state["pit_saving"] = True
                    
                    # Validar que solo pueda registrar 1 pick por día
                    puede, mensaje = puede_registrar_pick_hoy(apodo, ronda_id)
                    
                    if not puede:
                        st.error(mensaje)
                        st.session_state["pit_saving"] = False
                        st.stop()
                    
                    try:
                        ws_picks = ensure_tab(get_ss(), "pit_picks", PIT_PICKS_HEADERS)
                        _rate_limit_gs("pit_picks_append", 0.5)  # Rate limit
                        new_row = [
                            ronda_id,
                            str(today_cdmx.weekday()),
                            str(today_cdmx),  # today_cdmx is already a date object
                            apodo,
                            f"{away}@{home}",  # Guardar como Away@Home
                            liga,
                            game_id,
                            value,
                            "1.0",
                            "pendiente",
                            ""
                        ]
                        ws_picks.append_row(new_row)
                        _rate_limit_gs("pit_picks_append", 1.0)
                        
                        # Limpiar cache sin `.pop()` agresivo
                        if "pit_picks" in st.session_state:
                            del st.session_state["pit_picks"]
                        
                        st.success(f"✅ Pick guardado: {format_partido_para_display(f'{away}@{home}', sport)} - {value}")
                        time.sleep(1)
                        st.session_state["pit_saving"] = False
                        st.rerun()
                    except Exception as e:
                        st.error(f"❌ Error: {str(e)[:150]}")  # Mostrar más detalles del error
                        st.session_state["pit_saving"] = False
    
    st.write("")
    
    # Show mi pick de hoy
    try:
        ss = get_ss()
        if ss:
            ws_pit = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
            all_pit_picks = _safe_get_records(ws_pit)
            
            today_pick = None
            for pick in all_pit_picks:
                if (str(pick.get("apodo", "")).lower().strip() == apodo.lower().strip() and
                    str(pick.get("fecha", "")).strip() == str(today_cdmx.date()) and
                    str(pick.get("ronda_id", "")).strip() == str(ronda_id)):
                    today_pick = pick
                    break
            
            if today_pick:
                partido = today_pick.get("partido", "")
                pick_valor = today_pick.get('pick_desc', 'N/A')
                st.success(f"✅ **Tu pick de hoy: {format_partido_para_display(partido, today_pick.get('deporte', 'soccer'))} - {pick_valor}**")
    except:
        pass

    st.markdown(f"---\n🔴 RONDA #{ronda_id} · CDMX {now_cdmx.strftime('%H:%M')} · TIPO: {pick_type_hoy}")



def main():
    inject_css()
    
    # 🚀 EJECUTAR CALIFICACIÓN AUTOMÁTICA CADA 5 MIN
    auto_grade_all_picks_master()

    # FX
    fx = st.session_state.pop("fx", None)
    if fx == "confetti":
        st.markdown(confetti_html(), unsafe_allow_html=True)
    elif fx == "wasted":
        st.markdown('<div class="wasted-overlay">W A S T E D</div>', unsafe_allow_html=True)

    # Login gate
    if "apodo" not in st.session_state:
        render_login()
        return

    apodo = st.session_state["apodo"]

    # Load data
    # ── Load picks — cache in session_state to avoid gspread APIError on reruns
    if "df_picks" not in st.session_state or st.session_state.get("df_apodo") != apodo:
        with st.spinner("⚡ Cargando…"):
            try:
                df = load_picks(apodo)
                st.session_state["df_picks"] = df
                st.session_state["df_apodo"] = apodo
            except Exception:
                df = pd.DataFrame(columns=PICKS_HEADERS)
                st.session_state["df_picks"] = df
    else:
        df = st.session_state["df_picks"]

    # ── AUTO-GRADE on every load ──────────────────────────────
    bank = get_bankroll(df)
    pending_count = (df["resultado"].isin(["pendiente","nulo"])).sum() if not df.empty else 0
    if pending_count > 0:
        try:
            df, graded, bank = auto_grade_pending(apodo, df, bank)
            st.session_state["df_picks"] = df
            if graded > 0:
                st.markdown(
                    f'<div class="autobanner">⚡ Auto-calificador: <strong>{graded} pick(s)</strong> resueltos automáticamente desde ESPN.</div>',
                    unsafe_allow_html=True
                )
        except Exception:
            pass
    else:
        bank = get_bankroll(df)

    # Manual refresh button
    col_r = st.columns([6,1])[1]
    with col_r:
        if st.button("🔄", help="Actualizar resultados desde ESPN (limpia cache)", key="main_refresh"):
            # Limpiar todos los caches
            st.cache_data.clear()
            st.cache_resource.clear()
            for k in ["df_picks","df_apodo","pit_ronda","pit_players","pit_picks"]:
                st.session_state.pop(k, None)
            st.rerun()

    # Header
    render_header(apodo, bank)

    # ═══════════════════════════════════════════════════════════════
    # 🔍 DEBUG GLOBAL: DESACTIVADO TEMPORALMENTE (consume mucha cuota de Google Sheets)
    # ═══════════════════════════════════════════════════════════════
#     # with st.expander("🔍 DEBUG GLOBAL: Status de todos tus picks (PENDIENTES)"):
#     #     st.write("**Tus picks que aún necesitan calificación:**")
#     #     
#     #     try:
#     #         ss = get_ss()
#     #         if ss:
#     #             found_any = False
#     #             
#     #             # Debug: Mostrar TODAS las hojas disponibles con detalles
#     #             with st.expander("📋 DEBUG: Hojas disponibles y contenido:"):
#     #                 all_sheets = ss.worksheets()
#     #                 for sheet in all_sheets:
#     #                         st.write(f"**Hoja: {sheet.title}**")
#     #                         try:
#     #                             records = _safe_get_records(sheet)
#     #                             st.caption(f"Total registros: {len(records)}")
#     #                             
#     #                             # Mostrar estructura
#     #                             if records:
#     #                                 st.caption(f"Headers: {list(records[0].keys())}")
#     #                                 
#     #                                 # Mostrar TODOS tus registros (comparar exactamente con .lower().strip())
#     #                                 my_records = [r for r in records if str(r.get("apodo", "")).lower().strip() == apodo.lower()]
#     #                                 st.caption(f"Registros con apodo '{apodo}': {len(my_records)}")
#     #                                 
#     #                                 # Mostrar tus registros con TODO el detalle
#     #                                 if my_records:
#     #                                     for idx, r in enumerate(my_records):
#     #                                         st.caption(f"  {idx+1}. {r.get('fecha', '?')} | {r.get('partido', '?')} | Pick: {r.get('pick_desc', '?')} | Resultado: '{r.get('resultado', '?')}'")
#                         except Exception as e:
#                             st.error(f"Error leyendo {sheet.title}: {str(e)[:50]}")
#                 
#                 # THE PIT picks
#                 try:
#                     ws_pit = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
#                     pit_records = _safe_get_records(ws_pit)
#                     my_pit_pending = [r for r in pit_records 
#                                      if str(r.get("apodo", "")).lower().strip() == apodo.lower()
#                                      and str(r.get("resultado", "")).strip().lower() == "pendiente"]
#                     
#                     if my_pit_pending:
#                         found_any = True
#                         st.write("**🩸 THE PIT (PENDIENTES):**")
#                         for idx, pick in enumerate(my_pit_pending):
#                             col1, col2, col3, col4 = st.columns([2, 2, 1, 1])
#                             with col1:
#                                 st.caption(f"**{pick.get('partido', '?')}**")
#                             with col2:
#                                 st.caption(f"Pick: {pick.get('pick_desc', '?')}")
#                             with col3:
#                                 st.caption("⏳ **PENDIENTE**")
#                             with col4:
#                                 if st.button("🧪", key=f"debug_pit_{idx}", use_container_width=True):
#                                     event_id = pick.get('event_id', '')
#                                     partido = pick.get('partido', '')
#                                     deporte = pick.get('deporte', 'soccer')
#                                     pick_desc = pick.get('pick_desc', '').lower()
#                                     
#                                     # Intentar por EVENT_ID primero
#                                     if event_id:
#                                         espn_data = _find_resultado_por_event_id(event_id, deporte)
#                                         if espn_data.get('found'):
#                                             if espn_data.get('completed'):
#                                                 st.success(f"✅ Resultado encontrado por EVENT_ID: {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
#                                             else:
#                                                 st.info(f"⏳ Partido EN CURSO - Status: {espn_data.get('status', '?')}")
#                                             return
#                                     
#                                     # Si NO hay event_id, BUSCARLO por NOMBRE
#                                     if not event_id:
#                                         st.info("🔍 Buscando event_id por nombre del partido...")
#                                         found_event_id = _buscar_event_id_por_partido(partido, deporte)
#                                         if found_event_id:
#                                             st.success(f"✅ Event_id encontrado: {found_event_id}")
#                                             espn_data = _find_resultado_por_event_id(found_event_id, deporte)
#                                             if espn_data.get('found') and espn_data.get('completed'):
#                                                 st.success(f"✅ Resultado: {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
#                                                 return
#                                             elif espn_data.get('found'):
#                                                 st.info(f"⏳ Partido EN CURSO")
#                                                 return
#                                     
#                                     # Fallback: buscar por NOMBRE
#                                     st.info("🔍 Buscando por nombre del partido...")
#                                     resultado = _find_resultado_robusto(partido, deporte, pick_desc)
#                                     if resultado:
#                                         st.success(f"✅ Se puede calificar como: **{resultado.upper()}**")
#                                     else:
#                                         st.warning("❌ No se encontró resultado en ESPN")
#                 except Exception as e:
#                     pass
#                 
#                 # REGISTRAR picks - BUSCAR EN TODAS LAS HOJAS picks_*
#                 try:
#                     for sheet in ss.worksheets():
#                         # Buscar SOLO en hojas que empiezan con "picks_"
#                         if not sheet.title.startswith("picks_"):
#                             continue
#                         
#                         # Saltar la hoja de pit_picks (ya la procesamos)
#                         if sheet.title == "pit_picks":
#                             continue
#                         
#                         try:
#                             records = _safe_get_records(sheet)
#                             
#                             # El nombre de la hoja ES el apodo (picks_RONGO → RONGO)
#                             sheet_apodo = sheet.title.replace("picks_", "").strip().lower()
#                             
#                             # ¿Es esta hoja para el usuario actual?
#                             if sheet_apodo == apodo.lower():
#                                 # Filtrar picks pendientes
#                                 # (picks_APODO no tiene columna 'apodo', así que todos son del usuario)
#                                 my_pending = [r for r in records 
#                                              if str(r.get("resultado", "")).strip().lower() == "pendiente"]
#                                 
#                                 if my_pending:
#                                     found_any = True
#                                     st.write(f"**📝 {sheet.title} (PENDIENTES: {len(my_pending)}):**")
#                                     for idx, pick in enumerate(my_pending):
#                                         col1, col2, col3, col4 = st.columns([2, 2, 1, 1])
#                                         with col1:
#                                             st.caption(f"**{pick.get('partido', '?')}**")
#                                         with col2:
#                                             st.caption(f"Pick: {pick.get('pick_desc', '?')}")
#                                         with col3:
#                                             st.caption("⏳ **PENDIENTE**")
#                                         with col4:
#                                             if st.button("🧪", key=f"debug_reg_{sheet.title}_{idx}", use_container_width=True):
#                                                 event_id = pick.get('event_id', '')
#                                                 partido = pick.get('partido', '')
#                                                 deporte = pick.get('deporte', 'soccer')
#                                                 pick_desc = pick.get('pick_desc', '').lower()
#                                                 
#                                                 # Intentar por EVENT_ID primero
#                                                 if event_id:
#                                                     espn_data = _find_resultado_por_event_id(event_id, deporte)
#                                                     if espn_data.get('found'):
#                                                         if espn_data.get('completed'):
#                                                             st.success(f"✅ Resultado encontrado por EVENT_ID: {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
#                                                         else:
#                                                             st.info(f"⏳ Partido EN CURSO - Status: {espn_data.get('status', '?')}")
#                                                         return
#                                                 
#                                                 # Si NO hay event_id, BUSCARLO por NOMBRE
#                                                 if not event_id:
#                                                     st.info("🔍 Buscando event_id por nombre del partido...")
#                                                     found_event_id = _buscar_event_id_por_partido(partido, deporte)
#                                                     if found_event_id:
#                                                         st.success(f"✅ Event_id encontrado: {found_event_id}")
#                                                         espn_data = _find_resultado_por_event_id(found_event_id, deporte)
#                                                         if espn_data.get('found') and espn_data.get('completed'):
#                                                             st.success(f"✅ Resultado: {espn_data['away_team']} {espn_data['away_score']} - {espn_data['home_score']} {espn_data['home_team']}")
#                                                             return
#                                                         elif espn_data.get('found'):
#                                                             st.info(f"⏳ Partido EN CURSO")
#                                                             return
#                                                 
#                                                 # Fallback: buscar por NOMBRE
#                                                 st.info("🔍 Buscando por nombre del partido...")
#                                                 resultado = _find_resultado_robusto(partido, deporte, pick_desc)
#                                                 if resultado:
#                                                     st.success(f"✅ Se puede calificar como: **{resultado.upper()}**")
#                                                 else:
#                                                     st.warning("❌ No se encontró resultado en ESPN")
#                         except Exception as e:
#                             st.warning(f"Error en {sheet.title}: {str(e)[:30]}")
#                 except Exception as e:
#                     pass
#                 
#                 if not found_any:
#                     st.info("✅ No hay picks pendientes. ¡Todos están calificados!")
#         except Exception as e:
#             st.error(f"Error cargando debug: {str(e)[:100]}")

    # Tabs
    t1, t2, t3, t4, t5, t6 = st.tabs([
        "📝  REGISTRAR", "📋  HISTORIAL", "📊  ANALYTICS",
        "⚔️  LEADERBOARD", "🔮  SIMULADOR", "🩸  THE PIT"
    ])
    with t1: tab_registrar(apodo, df, bank)
    with t2: tab_historial(apodo, df)
    with t3: tab_analytics(df, bank)
    with t4: tab_challenge(apodo, df, bank)
    with t5: tab_simulador(df, bank)
    with t6:
        try:
            tab_the_pit(apodo, bank)
        except Exception as _pit_err:
            st.error(f"THE PIT error: {type(_pit_err).__name__}: {_pit_err}")


if __name__ == "__main__":
    main()
