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
import math, random, json
from oauth2client.service_account import ServiceAccountCredentials
from datetime import datetime, date, timedelta, timezone

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
        "Fútbol Internacional":          ("soccer", "fifa.worldq"),
    },
    "🏀 Basketball": {
        "NBA":                   ("basketball", "nba"),
    },
    "🏈 American Football": {
        "NFL":                   ("football", "nfl"),
    },
    "⚾ Baseball": {
        "MLB":                   ("baseball", "mlb"),
    },
    "🏒 Hockey": {
        "NHL":                   ("hockey", "nhl"),
    },
    "🎾 Tenis": {
        "ATP (incl. Miami Open)":  ("tennis", "atp"),
        "WTA (incl. Miami Open)":  ("tennis", "wta"),
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
    "atp":                 "tennis_atp_french_open",
    "wta":                 "tennis_wta_french_open",
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

ODDS_CACHE_TAB     = "odds_cache"
ODDS_CACHE_HEADERS = ["sport_key","fetched_at","event_id","home","away",
                       "date_raw","home_odds","away_odds","draw_odds","odds_sport"]
ODDS_CACHE_TTL_HRS = 6  # hours before Sheet cache is considered stale

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

    score = comp.get("score", "")
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
        is_live      = (state == "in") and not completed

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
            "name":          name,
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
    pick_desc examples: "Real Madrid", "Over 2.5", "BTTS Si", "Lakers -5.5"
    """
    if not event_data:
        return None

    try:
        # Get competitors and scores
        comp_data = event_data.get("boxscore", {}).get("teams", [])
        if not comp_data:
            comps = event_data.get("header", {}).get("competitions", [{}])[0].get("competitors", [])
            scores = {c.get("homeAway", ""): {"score": c.get("score", "0"), "name": c.get("team", {}).get("displayName", "")} for c in comps}
        else:
            scores = {}
            for t in comp_data:
                side = t.get("homeAway", "")
                name = t.get("team", {}).get("displayName", "")
                score = t.get("score", "0")
                scores[side] = {"score": score, "name": name}

        home_score = float(scores.get("home", {}).get("score", 0) or 0)
        away_score = float(scores.get("away", {}).get("score", 0) or 0)
        home_name  = scores.get("home", {}).get("name", "").lower()
        away_name  = scores.get("away", {}).get("name", "").lower()
        total      = home_score + away_score
        pick_low   = pick_desc.strip().lower()
        merc_low   = mercado.lower()

        # ── ML / Ganador ──
        if "ml" in merc_low or "ganador" in merc_low or "1x2" in merc_low or "resultado" in merc_low:
            if any(w in pick_low for w in home_name.split()) or home_name in pick_low:
                return "ganado" if home_score > away_score else ("nulo" if home_score == away_score else "perdido")
            if any(w in pick_low for w in away_name.split()) or away_name in pick_low:
                return "ganado" if away_score > home_score else ("nulo" if home_score == away_score else "perdido")
            if "empate" in pick_low or "draw" in pick_low or " x " in pick_low:
                return "ganado" if home_score == away_score else "perdido"

        # ── Over / Under ──
        if "over" in pick_low or "under" in pick_low or "o/u" in merc_low:
            import re
            nums = re.findall(r"[\d.]+", pick_desc)
            if nums:
                line = float(nums[0])
                if "over" in pick_low:
                    if total > line: return "ganado"
                    elif total == line: return "nulo"
                    else: return "perdido"
                else:  # under
                    if total < line: return "ganado"
                    elif total == line: return "nulo"
                    else: return "perdido"

        # ── BTTS ──
        if "btts" in merc_low or "ambos" in merc_low:
            both_scored = home_score > 0 and away_score > 0
            if "si" in pick_low or "yes" in pick_low:
                return "ganado" if both_scored else "perdido"
            else:
                return "ganado" if not both_scored else "perdido"

        # ── Handicap ──
        if "hándicap" in merc_low or "handicap" in merc_low:
            import re
            nums = re.findall(r"[+-]?[\d.]+", pick_desc)
            if nums and len(nums) >= 1:
                hcap = float(nums[-1])
                if any(w in pick_low for w in home_name.split()):
                    adj = home_score + hcap
                    if adj > away_score: return "ganado"
                    elif adj == away_score: return "nulo"
                    else: return "perdido"
                if any(w in pick_low for w in away_name.split()):
                    adj = away_score + hcap
                    if adj > home_score: return "ganado"
                    elif adj == home_score: return "nulo"
                    else: return "perdido"

    except Exception:
        pass
    return None  # couldn't auto-determine → leave for manual


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
            first_row = ws.row_values(1)
            if not first_row:
                ws.append_row(headers)
        except Exception:
            pass
        return ws
    except gspread.WorksheetNotFound:
        ws = ss.add_worksheet(title=name, rows=2000, cols=max(len(headers), 20))
        ws.append_row(headers)
        return ws
    except Exception as e:
        # APIError (token expired mid-session) — try reconnect once
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
def auto_grade_pending(apodo: str, df: pd.DataFrame, bank: float) -> tuple[pd.DataFrame, int, float]:
    """
    Check all pending picks against ESPN.
    Returns updated df, count graded, new bank.
    """
    pending = df[df["resultado"] == "pendiente"].copy()
    if pending.empty:
        return df, 0, bank

    graded = 0
    current_bank = bank

    for idx, row in pending.iterrows():
        event_id = str(row.get("event_id", "")).strip()
        if not event_id:
            continue

        liga  = str(row.get("liga", ""))
        sport_info = ESPN_LEAGUES.get(liga)
        if not sport_info:
            continue
        sport, league = sport_info

        event_data = espn_get_event(sport, league, event_id)
        if not event_data:
            continue

        # Check if completed
        header = event_data.get("header", {})
        comps  = header.get("competitions", [{}])
        status = comps[0].get("status", {}).get("type", {}) if comps else {}
        if not status.get("completed", False):
            continue

        # Try to determine result
        resultado = parse_result_from_event(
            event_data,
            str(row.get("pick_desc", "")),
            str(row.get("mercado", ""))
        )
        if resultado is None:
            continue

        apuesta  = float(row.get("apuesta", 0))
        momio    = float(row.get("momio", 1))
        if resultado == "ganado":
            ganancia = round(apuesta * (momio - 1), 2)
        elif resultado == "perdido":
            ganancia = -apuesta
        else:  # nulo
            ganancia = 0.0

        new_bank = round(current_bank + ganancia, 2)
        update_pick_row(apodo, idx, resultado, ganancia, new_bank)
        df.at[idx, "resultado"]    = resultado
        df.at[idx, "ganancia_neta"] = ganancia
        df.at[idx, "bankroll_post"] = new_bank
        current_bank = new_bank
        graded += 1

    return df, graded, current_bank


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
    ("🌍 Fútbol — Selecciones", "Fútbol Internacional",   "soccer", "fifa.worldq"),
    # Basketball
    ("🏀 Basketball", "NBA",  "basketball", "nba"),
    # Baseball
    ("⚾ Baseball",   "MLB",  "baseball",   "mlb"),
    # Hockey
    ("🏒 Hockey",     "NHL",  "hockey",     "nhl"),
    # Tennis — atp and wta cover all active tournaments including Miami Open
    ("🎾 Tenis", "ATP Tour",  "tennis", "atp"),
    ("🎾 Tenis", "WTA Tour",  "tennis", "wta"),
]

@st.cache_data(ttl=1800, show_spinner=False)
def load_all_today() -> dict:
    """
    Fetch all games happening today+tomorrow across all leagues.
    Returns dict: {sport_group: {liga: [events]}}
    Cached 30 min to avoid hammering ESPN.
    """
    today    = date.today().strftime("%Y%m%d")
    tomorrow = (date.today() + timedelta(days=1)).strftime("%Y%m%d")
    result   = {}  # {sport_group: {liga: [events]}}
    seen_ids = set()

    for sport_group, liga_name, sport, league_slug in ALL_TODAY_LEAGUES:
        try:
            url = f"{ESPN_BASE}/{sport}/{league_slug}/scoreboard"
            events_found = []

            # For tennis: search bare scoreboard + today + tomorrow to get all active matches
            date_params = [None, today, tomorrow] if sport == "tennis" else [today, tomorrow]

            for dt_str in date_params:
                params = {"limit": 200}
                if dt_str:
                    params["dates"] = dt_str
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
                    comp0 = ev.get("competitions",[{}])[0]
                    comps = comp0.get("competitors",[])
                    home_c = next((c for c in comps if c.get("homeAway")=="home"), comps[0] if comps else {})
                    away_c = next((c for c in comps if c.get("homeAway")=="away"), comps[1] if len(comps)>1 else {})
                    home_i = _extract_competitor_info(home_c, sport)
                    away_i = _extract_competitor_info(away_c, sport)
                    date_raw = ev.get("date","")
                    try:
                        dt_ev  = datetime.fromisoformat(date_raw.replace("Z","+00:00"))
                        dt_mx  = dt_ev - timedelta(hours=6)
                        d_str  = dt_mx.strftime("%d %b %H:%M")
                    except Exception:
                        d_str = date_raw[:10]
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

    # Also fetch from Odds API for ALL international soccer (all confederations)
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
            grp  = "🌍 Fútbol — Selecciones"
            liga = "Partidos Internacionales (The Odds API)"
            if grp not in result:
                result[grp] = {}
            # Remove duplicates with ESPN data
            espn_ids = {
                e["id"]
                for ligas in result.get(grp,{}).values()
                for e in ligas
            }
            new_evs = [e for e in intl_events if e["id"] not in espn_ids]
            if new_evs:
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

                                st.markdown(
                                    f'<div style="background:{bg};border:1px solid {border};'
                                    f'border-radius:12px;padding:10px 8px;text-align:center">'
                                    f'<div style="display:flex;align-items:center;justify-content:center;'
                                    f'gap:5px;margin-bottom:5px">'
                                    f'<div style="display:flex;flex-direction:column;align-items:center;gap:2px;flex:1">'
                                    f'{a_lg}<div style="font-size:.58rem;font-weight:700;color:#EEEEF5;'
                                    f'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:80px">'
                                    f'{away}</div></div>'
                                    f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.7rem;color:#44445A">VS</div>'
                                    f'<div style="display:flex;flex-direction:column;align-items:center;gap:2px;flex:1">'
                                    f'{h_lg}<div style="font-size:.58rem;font-weight:700;color:#EEEEF5;'
                                    f'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:80px">'
                                    f'{home}</div></div></div>'
                                    f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.48rem;'
                                    f'color:{s_col}">{s_txt}</div>'
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
    st.markdown('<div class="sec-head">Buscar partido</div>', unsafe_allow_html=True)

    # ── Step 1: Sport group → then league
    c1, c2 = st.columns(2)
    with c1:
        group_names = list(ESPN_LEAGUES_GROUPED.keys())
        sport_group = st.selectbox("Deporte", group_names, key="reg_sport_group")
        ligas_in_group = list(ESPN_LEAGUES_GROUPED[sport_group].keys())
        liga_sel = st.selectbox("Liga / Torneo", ligas_in_group, key="reg_liga")
    with c2:
        query = st.text_input(
            "Buscar equipo / jugador",
            placeholder="ej: Turkey, Italy, Liverpool, Lakers…",
            key="reg_query"
        )

    sport, league = ESPN_LEAGUES[liga_sel]

    # ── All Today mode ──────────────────────────────────────────
    if league == "__all_today__":
        render_all_today(apodo)
        # Step 2 still works — if user selected an event, show pick builder
        selected = st.session_state.get("selected_event", None)
        if selected:
            st.markdown("---")
        else:
            return

    events = []

    if st.button("🔍 BUSCAR PARTIDOS", key="btn_search"):
        with st.spinner("Consultando…"):
            # Use Odds API for international soccer (more complete coverage)
            use_odds = (sport == "soccer" and league in ODDS_SPORT_MAP) or league == "__team_search__"
            if use_odds:
                events = odds_search_events(league, query)
                # Fallback to ESPN if Odds API returned nothing
                if not events and league != "__team_search__":
                    events = espn_search_events(sport, league, query)
            elif league == "__team_search__":
                events = espn_search_by_team(sport, query) if query.strip() else []
            else:
                events = espn_search_events(sport, league, query)
            st.session_state["search_events"] = events
            st.session_state["selected_event"] = None

    events = st.session_state.get("search_events", [])
    selected = st.session_state.get("selected_event", None)

    if events:
        is_tennis = (sport == "tennis")
        sz_ev   = 40
        brad_ev = "50%" if is_tennis else "8px"

        ev_list = events[:30]
        st.markdown(
            f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.58rem;'
            f'color:var(--text3);margin-bottom:10px">{len(ev_list)} PARTIDOS ENCONTRADOS</div>',
            unsafe_allow_html=True
        )

        for ev_i, ev in enumerate(ev_list):
            ev_id   = ev["id"]
            away    = ev["away"]; home = ev["home"]

            # Skip TBD tennis
            if ev.get("sport","") == "tennis" and (away in ("?","TBD","") or home in ("?","TBD","")):
                continue
            is_live = ev.get("is_live", False)
            is_sel  = selected and selected["id"] == ev_id
            s_txt   = "● LIVE" if is_live else ev["date"]
            s_col   = "#FF3D00" if is_live else "#00FFD1"
            s_anim  = "animation:blinkLive 1.2s infinite" if is_live else ""
            a_lg    = mk_logo(ev.get("away_logo",""), ev.get("away_flag",""), away, sz_ev, brad_ev)
            h_lg    = mk_logo(ev.get("home_logo",""), ev.get("home_flag",""), home, sz_ev, brad_ev)

            # Odds display
            ho = ev.get("home_odds",0); ao = ev.get("away_odds",0); do = ev.get("draw_odds",0)
            odds_html = ""
            if ao > 1:
                odds_html = (f'<div style="display:flex;gap:6px;justify-content:center;margin-top:5px;'
                             f'font-family:\'JetBrains Mono\',monospace;font-size:.52rem">'
                             f'<span style="background:rgba(0,255,136,.1);color:#00FF88;padding:2px 7px;border-radius:4px">{ao}</span>')
                if do > 1:
                    odds_html += f'<span style="background:rgba(255,184,0,.1);color:#FFB800;padding:2px 7px;border-radius:4px">{do}</span>'
                odds_html += f'<span style="background:rgba(0,180,255,.1);color:#00B4FF;padding:2px 7px;border-radius:4px">{ho}</span></div>'

            border = "rgba(240,255,0,.7)" if is_sel else ("rgba(255,61,0,.5)" if is_live else "rgba(255,255,255,.08)")
            bg     = "rgba(240,255,0,.06)" if is_sel else "rgba(255,255,255,.02)"

            st.markdown(
                f'<div style="background:{bg};border:1px solid {border};border-radius:14px;'
                f'padding:12px 16px;margin-bottom:4px">'
                f'<div style="display:flex;align-items:center;gap:12px">'
                f'<div style="display:flex;align-items:center;gap:8px;flex:1">'
                f'{a_lg}<span style="font-size:.85rem;font-weight:700;color:#EEEEF5">{away}</span></div>'
                f'<div style="text-align:center;min-width:50px">'
                f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.75rem;color:#44445A">VS</div>'
                f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.48rem;color:{s_col};{s_anim}">{s_txt}</div></div>'
                f'<div style="display:flex;align-items:center;gap:8px;flex:1;justify-content:flex-end">'
                f'<span style="font-size:.85rem;font-weight:700;color:#EEEEF5">{home}</span>{h_lg}</div>'
                f'</div>{odds_html}</div>',
                unsafe_allow_html=True
            )

            # ── Inline pick buttons — show immediately under the card ──
            sport_ev = ev.get("sport", sport)
            is_tennis_ev = (sport_ev == "tennis")
            is_soccer_ev = (sport_ev == "soccer")

            if is_tennis_ev:
                pick_opts  = [(away, "ML"), (home, "ML")]
                btn_labels = [f"🎾 {away[:20]}", f"🎾 {home[:20]}"]
            elif is_soccer_ev:
                pick_opts  = [(away, "ML"), ("Empate", "1X2"), (home, "ML")]
                btn_labels = [f"⚽ {away[:15]}", "➖ Empate", f"⚽ {home[:15]}"]
            elif sport_ev == "basketball":
                pick_opts  = [(away, "ML"), (home, "ML"), ("Over", "O/U"), ("Under", "O/U")]
                btn_labels = [f"🏀 {away[:13]}", f"🏀 {home[:13]}", "📈 Over", "📉 Under"]
            elif sport_ev == "baseball":
                pick_opts  = [(away, "ML"), (home, "ML"), ("Over", "O/U"), ("Under", "O/U")]
                btn_labels = [f"⚾ {away[:13]}", f"⚾ {home[:13]}", "📈 Over", "📉 Under"]
            elif sport_ev == "hockey":
                pick_opts  = [(away, "ML"), (home, "ML"), ("Over 5.5", "O/U"), ("Under 5.5", "O/U")]
                btn_labels = [f"🏒 {away[:13]}", f"🏒 {home[:13]}", "📈 Over 5.5", "📉 Under 5.5"]
            else:
                pick_opts  = [(away, "ML"), (home, "ML")]
                btn_labels = [f"🏆 {away[:18]}", f"🏆 {home[:18]}"]

            # Quick-pick cols
            n_opts  = len(btn_labels)
            q_cols  = st.columns(n_opts + 1)  # +1 for custom pick
            clicked_pick = None
            for bi, (col, lbl, (pick_val, pick_merc)) in enumerate(zip(q_cols[:n_opts], btn_labels, pick_opts)):
                with col:
                    if st.button(lbl, key=f"qp_{ev_id[:10]}_{bi}", use_container_width=True):
                        clicked_pick = (pick_val, pick_merc, lbl)

            with q_cols[-1]:
                expand_key = f"expand_other_{ev_id[:10]}"
                if st.button("✏️ Otro pick", key=f"qp_custom_{ev_id[:10]}", use_container_width=True):
                    # Toggle expanded state
                    st.session_state[expand_key] = not st.session_state.get(expand_key, False)
                    st.session_state["selected_event"] = ev

            # ── "Otro pick" inline expanded panel ──
            if st.session_state.get(expand_key, False) and (not is_sel or not st.session_state.get(f"qp_val_{ev_id}")):
                sport_ev2   = ev.get("sport", sport)
                is_soc2     = sport_ev2 == "soccer"
                is_ten2     = sport_ev2 == "tennis"
                is_bas2     = sport_ev2 == "basketball"
                is_base2    = sport_ev2 == "baseball"

                # Build pick options based on sport
                if is_ten2:
                    quick_picks = {
                        f"🏆 {away} gana": (away, "ML"),
                        f"🏆 {home} gana": (home, "ML"),
                        f"📊 Over sets": ("Over sets", "O/U"),
                        f"📊 Under sets": ("Under sets", "O/U"),
                    }
                elif is_soc2:
                    quick_picks = {
                        f"⚽ {away[:15]} gana": (away, "ML"),
                        "➖ Empate": ("Empate", "1X2"),
                        f"⚽ {home[:15]} gana": (home, "ML"),
                        f"📈 Over 2.5": ("Over 2.5", "O/U"),
                        f"📉 Under 2.5": ("Under 2.5", "O/U"),
                        "⚽⚽ Ambos anotan": ("Ambos anotan", "BTTS"),
                        f"🔱 {away[:12]} hándicap": (f"{away} hándicap", "Hándicap"),
                        f"🔱 {home[:12]} hándicap": (f"{home} hándicap", "Hándicap"),
                    }
                elif is_bas2:
                    quick_picks = {
                        f"🏀 {away[:15]} ML":      (away, "ML"),
                        f"🏀 {home[:15]} ML":      (home, "ML"),
                        f"📈 Over puntos":          ("Over puntos", "O/U"),
                        f"📉 Under puntos":         ("Under puntos", "O/U"),
                        f"🔱 {away[:12]} -3.5":    (f"{away} -3.5", "Hándicap"),
                        f"🔱 {home[:12]} +3.5":    (f"{home} +3.5", "Hándicap"),
                    }
                elif is_base2:
                    quick_picks = {
                        f"⚾ {away[:15]} ML": (away, "ML"),
                        f"⚾ {home[:15]} ML": (home, "ML"),
                        f"📈 Over carreras": ("Over carreras", "O/U"),
                        f"📉 Under carreras": ("Under carreras", "O/U"),
                        f"🔱 {away[:12]} RL": (f"{away} run line", "Hándicap"),
                        f"🔱 {home[:12]} RL": (f"{home} run line", "Hándicap"),
                    }
                else:
                    quick_picks = {
                        f"🏆 {away[:15]} gana": (away, "ML"),
                        f"🏆 {home[:15]} gana": (home, "ML"),
                        f"📈 Over": ("Over", "O/U"),
                        f"📉 Under": ("Under", "O/U"),
                    }

                st.markdown(
                    f'<div style="background:rgba(191,95,255,.05);border:1px solid rgba(191,95,255,.2);'
                    f'border-radius:10px;padding:10px 14px;margin:4px 0 6px">'
                    f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.55rem;'
                    f'color:#BF5FFF;margin-bottom:8px">ELIGE TU MERCADO</div></div>',
                    unsafe_allow_html=True
                )

                # Render pick buttons in rows of 4
                pick_keys = list(quick_picks.keys())
                for row_s in range(0, len(pick_keys), 4):
                    row_k = pick_keys[row_s:row_s+4]
                    rcols = st.columns(len(row_k))
                    for ri, rk in enumerate(row_k):
                        with rcols[ri]:
                            if st.button(rk, key=f"op_{ev_id[:10]}_{ri}_{row_s}", use_container_width=True):
                                pv, pm = quick_picks[rk]
                                st.session_state[f"qp_val_{ev_id}"]  = pv
                                st.session_state[f"qp_merc_{ev_id}"] = pm
                                st.session_state[expand_key] = False
                                st.rerun()

            # ── If quick-pick clicked → show inline save form ──
            # Check if Over/Under was picked — needs line input first
            ou_key = f"ou_pending_{ev_id[:10]}"
            if clicked_pick and clicked_pick[0] in ("Over","Under"):
                st.session_state[ou_key] = clicked_pick[0]  # "Over" or "Under"
                clicked_pick = None  # don't proceed to save yet

            # Show line input if Over/Under pending
            if st.session_state.get(ou_key):
                direction = st.session_state[ou_key]
                lc1, lc2 = st.columns([3,1])
                with lc1:
                    line_val = st.number_input(
                        f"Línea para {direction}",
                        min_value=0.5, max_value=500.0,
                        value=220.5 if sport_ev=="basketball" else 8.5 if sport_ev=="baseball" else 5.5,
                        step=0.5, key=f"ou_line_{ev_id[:10]}"
                    )
                with lc2:
                    st.markdown("<div style='height:28px'></div>", unsafe_allow_html=True)
                    if st.button("✅ OK", key=f"ou_confirm_{ev_id[:10]}", use_container_width=True):
                        pv = f"{direction} {line_val}"
                        st.session_state[f"qp_val_{ev_id}"]  = pv
                        st.session_state[f"qp_merc_{ev_id}"] = "O/U"
                        st.session_state.pop(ou_key, None)
                        st.rerun()
                    if st.button("✖", key=f"ou_cancel_{ev_id[:10]}", use_container_width=True):
                        st.session_state.pop(ou_key, None)
                        st.rerun()
                if clicked_pick:
                    pick_val, pick_merc, pick_lbl = clicked_pick
                    st.session_state["selected_event"] = ev
                    st.session_state[f"qp_val_{ev_id}"]  = pick_val
                    st.session_state[f"qp_merc_{ev_id}"] = pick_merc

                ev      = st.session_state.get("selected_event", ev)
                qv      = st.session_state.get(f"qp_val_{ev_id}", "")
                qm      = st.session_state.get(f"qp_merc_{ev_id}", "ML")

                if qv:
                    # Get default momio
                    def_momio = 1.85
                    aho = float(ev.get("home_odds",0)); aao = float(ev.get("away_odds",0)); ado = float(ev.get("draw_odds",0))
                    if aho == 0 and aao == 0:
                        # Try matching from Odds API cache
                        try:
                            for sk in list(ODDS_SPORT_MAP.values())[:6]:
                                if not sk: continue
                                cached = odds_fetch_sport(sk)
                                for cev in cached:
                                    if (ev["home"].lower()[:5] in cev["home"].lower() or cev["home"].lower()[:5] in ev["home"].lower()):
                                        aho = cev.get("home_odds",0); aao = cev.get("away_odds",0); ado = cev.get("draw_odds",0); break
                                if aho > 0: break
                        except Exception:
                            pass
                    if "empate" in qv.lower() and ado > 1:   def_momio = round(ado,2)
                    elif qv.lower()[:5] in home.lower()[:5] and aho > 1: def_momio = round(aho,2)
                    elif qv.lower()[:5] in away.lower()[:5] and aao > 1: def_momio = round(aao,2)
                    elif aao > 1: def_momio = round(aao,2)

                    with st.container():
                        st.markdown(
                            f'<div style="background:rgba(240,255,0,.05);border:1px solid rgba(240,255,0,.25);'
                            f'border-radius:10px;padding:12px 16px;margin:4px 0 8px">'
                            f'<span style="font-family:\'JetBrains Mono\',monospace;font-size:.6rem;color:#F0FF00">'
                            f'💾 GUARDAR PICK: {qv}</span></div>',
                            unsafe_allow_html=True
                        )
                        fc1, fc2, fc3 = st.columns([2,2,1])
                        with fc1:
                            momio_v = st.number_input("Momio", min_value=1.01, max_value=99.0,
                                                       value=def_momio, step=0.05,
                                                       key=f"qmomio_{ev_id[:10]}")
                        with fc2:
                            apuesta_v = st.number_input("Apuesta ($MXN)", min_value=1.0,
                                                         max_value=float(bank), value=100.0, step=50.0,
                                                         key=f"qapuesta_{ev_id[:10]}")
                        with fc3:
                            st.markdown("<div style='height:28px'></div>", unsafe_allow_html=True)
                            if st.button("💾 GUARDAR", key=f"qsave_{ev_id[:10]}", type="primary", use_container_width=True):
                                row = {
                                    "fecha":         str(date.today()),
                                    "deporte":       sport_ev,
                                    "liga":          ev.get("liga", liga_sel),
                                    "partido":       f"{away} vs {home}",
                                    "event_id":      ev_id,
                                    "mercado":       qm,
                                    "pick_desc":     qv,
                                    "momio":         momio_v,
                                    "apuesta":       apuesta_v,
                                    "resultado":     "pendiente",
                                    "ganancia_neta": 0,
                                    "bankroll_post": bank,
                                    "notas":         "",
                                }
                                if save_pick(apodo, row):
                                    st.success(f"✅ {qv} @ {momio_v}x — ${apuesta_v:,.0f}")
                                    for k in ["df_picks","search_events","selected_event","pick_type"]:
                                        st.session_state.pop(k, None)
                                    st.session_state.pop(f"qp_val_{ev_id}", None)
                                    st.session_state.pop(f"qp_merc_{ev_id}", None)
                                    st.rerun()

            st.markdown("<div style='height:2px'></div>", unsafe_allow_html=True)


    # ── Step 2: Visual pick builder (only if event selected)
    selected = st.session_state.get("selected_event", None)
    if selected:
        away = selected["away"]
        home = selected["home"]
        sport_sel = selected.get("sport", sport)
        is_tennis_pick = (sport_sel == "tennis")
        is_soccer_pick = (sport_sel == "soccer")

        # Selected event banner
        away_lg_sm = mk_logo(selected.get("away_logo",""), selected.get("away_flag",""), away)
        home_lg_sm = mk_logo(selected.get("home_logo",""), selected.get("home_flag",""), home)
        st.markdown(
            f'<div style="background:linear-gradient(135deg,rgba(240,255,0,.07),rgba(255,184,0,.04));'
            f'border:1px solid rgba(240,255,0,.35);border-radius:12px;padding:12px 18px;margin:14px 0;'
            f'display:flex;align-items:center;gap:14px">'
            f'<div style="display:flex;align-items:center;gap:8px;flex:1">'
            f'{away_lg_sm}'
            f'<div style="font-family:\'Rajdhani\',sans-serif;font-size:.9rem;font-weight:700;color:#EEEEF5">{away}</div>'
            f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.75rem;color:#44445A;margin:0 4px">VS</div>'
            f'<div style="font-family:\'Rajdhani\',sans-serif;font-size:.9rem;font-weight:700;color:#EEEEF5">{home}</div>'
            f'{home_lg_sm}'
            f'</div>'
            f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.52rem;color:#44445A;text-align:right">'
            f'{liga_sel}<br>{selected["date"]}</div>'
            f'</div>',
            unsafe_allow_html=True
        )

        st.markdown('<div class="sec-head">¿Cuál es tu pick?</div>', unsafe_allow_html=True)

        # ── STEP A: Pick type buttons
        pick_type = st.session_state.get("pick_type", None)

        # Define pick categories based on sport
        if is_tennis_pick:
            pick_categories = {
                "🎾 Ganador del match": "ML",
                "📊 Hándicap de games": "Hándicap",
                "🔢 Total de games O/U": "Over/Under Goles",
            }
        elif is_soccer_pick:
            pick_categories = {
                f"🏆 {away} gana": "ML",
                "🤝 Empate": "ML",
                f"🏆 {home} gana": "ML",
                "⚽ Over/Under goles": "Over/Under Goles",
                "🎯 BTTS (ambos anotan)": "BTTS (Ambos Anotan)",
                "📐 Hándicap asiático": "Hándicap Asiático",
                "🔲 Doble oportunidad": "Doble Oportunidad",
            }
        else:
            # NBA / NFL / NHL / MLB
            pick_categories = {
                f"🏆 {away} ML": "ML",
                f"🏆 {home} ML": "ML",
                f"📊 {away} hándicap": "Hándicap Asiático",
                f"📊 {home} hándicap": "Hándicap Asiático",
                "📈 Over puntos": "Over/Under Goles",
                "📉 Under puntos": "Over/Under Goles",
            }

        # Render pick type buttons in a grid
        cat_keys = list(pick_categories.keys())
        n_cols   = 3 if len(cat_keys) >= 3 else len(cat_keys)
        btn_rows = [cat_keys[i:i+n_cols] for i in range(0, len(cat_keys), n_cols)]

        for btn_row in btn_rows:
            cols = st.columns(len(btn_row))
            for col, cat in zip(cols, btn_row):
                with col:
                    is_active = (pick_type == cat)
                    # Force dark text on inactive, neon on active
                    btn_style = (
                        "background:linear-gradient(135deg,rgba(240,255,0,.15),rgba(255,184,0,.1))!important;"
                        "border-color:rgba(240,255,0,.6)!important;color:#F0FF00!important;"
                        "box-shadow:0 0 14px rgba(240,255,0,.2)!important;"
                    ) if is_active else (
                        "color:#EEEEF5!important;background:rgba(255,255,255,.06)!important;"
                        "border-color:rgba(255,255,255,.15)!important;"
                    )
                    st.markdown(
                        f'<style>'
                        f'div[data-testid="stButton"]:has(button[kind="secondary"][title="{cat}"]) button,'
                        f'div[data-testid="stButton"]:has(button[data-testid="{cat}"]) button'
                        f'{{ {btn_style} }}</style>',
                        unsafe_allow_html=True
                    )
                    if st.button(cat, key=f"ptype_{cat}"):
                        st.session_state["pick_type"]   = cat
                        st.session_state["pick_desc_v"] = cat
                        st.rerun()

        # ── STEP B: Details after pick type chosen
        if pick_type:
            st.markdown(
                f'<div style="background:rgba(240,255,0,.05);border:1px solid rgba(240,255,0,.2);'
                f'border-radius:10px;padding:10px 14px;margin:10px 0;'
                f'font-family:\'Rajdhani\',sans-serif;font-size:.85rem;color:#F0FF00">'
                f'Pick seleccionado: <strong>{pick_type}</strong></div>',
                unsafe_allow_html=True
            )

            mercado = pick_categories[pick_type]

            # Extra input for lines (Over/Under value, handicap value)
            pick_extra = ""
            if "Over" in pick_type or "Under" in pick_type or "O/U" in pick_type or "total" in pick_type.lower():
                line = st.number_input("Línea (ej: 2.5 goles, 220.5 puntos)", min_value=0.5, max_value=300.0, value=2.5, step=0.5, key="pick_line")
                direction = "Over" if ("Over" in pick_type or "over" in pick_type.lower()) else "Under"
                pick_extra = f" {direction} {line}"
            elif "hándicap" in pick_type.lower() or "Hándicap" in pick_type:
                hcap = st.number_input("Valor hándicap (ej: -1.5, +2.5)", min_value=-10.0, max_value=10.0, value=-1.5, step=0.5, key="pick_hcap")
                pick_extra = f" {hcap:+.1f}"

            pick_desc = pick_type + pick_extra

            # Pre-fill momio from Odds API — reset session key when event/pick changes
            ev_id       = selected.get("id","")
            momio_key   = f"pick_momio_{ev_id}_{pick_type[:8]}"
            default_momio = 1.85

            # Try to get odds — either from event object (Odds API events) or by matching
            ho = float(selected.get("home_odds") or 0)
            ao = float(selected.get("away_odds") or 0)
            do = float(selected.get("draw_odds") or 0)

            # If ESPN event (no odds), try to find matching event in Odds API cache
            if ho == 0 and sport_sel == "soccer":
                try:
                    for sk in WC_QUALIFIER_KEYS + [
                        ODDS_SPORT_MAP.get(liga_sel,""),
                        "soccer_epl","soccer_spain_la_liga","soccer_italy_serie_a",
                        "soccer_germany_bundesliga","soccer_france_ligue_one",
                        "soccer_uefa_champs_league","soccer_conmebol_libertadores",
                    ]:
                        if not sk: continue
                        cached = odds_fetch_sport(sk)
                        for cev in cached:
                            ch = cev["home"].lower(); ca = cev["away"].lower()
                            eh = home.lower();        ea = away.lower()
                            if (eh[:5] in ch or ch[:5] in eh) and (ea[:5] in ca or ca[:5] in ea):
                                ho = cev.get("home_odds",0)
                                ao = cev.get("away_odds",0)
                                do = cev.get("draw_odds",0)
                                break
                        if ho > 0: break
                except Exception:
                    pass

            if ho > 1 or ao > 1:
                pt_low = pick_type.lower()
                hn_low = home.lower(); an_low = away.lower()
                if any(w in pt_low for w in [hn_low[:5], "home gana", "local gana"]) and ho > 1:
                    default_momio = round(ho, 2)
                elif any(w in pt_low for w in [an_low[:5], "away gana", "visita gana"]) and ao > 1:
                    default_momio = round(ao, 2)
                elif any(w in pt_low for w in ["empate","draw"]) and do > 1:
                    default_momio = round(do, 2)
                elif ao > 1:
                    default_momio = round(ao, 2)

            # Show all three odds as reference
            if ho > 1:
                odds_ref = (f"💰 **{away}** {ao}  ·  Empate {do}  ·  **{home}** {ho}"
                            if do > 1 else f"💰 **{away}** {ao}  ·  **{home}** {ho}")
                st.caption(odds_ref)

            c1, c2 = st.columns(2)
            with c1:
                momio = st.number_input(
                    "Momio (decimal)",
                    min_value=1.01, max_value=99.0,
                    value=default_momio,
                    step=0.01,
                    key=momio_key  # unique key per event+pick — always reflects correct default
                )
            with c2:
                apuesta = st.number_input(
                    "¿Cuánto apostaste? ($MXN)",
                    min_value=1.0, max_value=float(bank),
                    value=50.0, step=50.0, key="pick_apuesta"
                )

            notas = st.text_area("Análisis / notas (opcional)", placeholder="¿Por qué este pick?", height=60, key="pick_notas")

            # % del bankroll indicator
            pct_bank = apuesta / bank * 100 if bank > 0 else 0
            bar_c = "#00FF88" if pct_bank <= 3 else "#FFB800" if pct_bank <= 5 else "#FF2D55"
            st.markdown(
                f'<div style="display:flex;align-items:center;gap:10px;margin:6px 0 12px">'
                f'<div style="flex:1;background:rgba(255,255,255,.05);border-radius:99px;height:6px;overflow:hidden">'
                f'<div style="width:{min(100,pct_bank*10):.0f}%;height:100%;background:{bar_c};border-radius:99px"></div>'
                f'</div>'
                f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.6rem;color:{bar_c};white-space:nowrap">'
                f'{pct_bank:.1f}% del bankroll</div>'
                f'</div>',
                unsafe_allow_html=True
            )

            if st.button("💾 GUARDAR PICK", type="primary", key="btn_save_pick"):
                row = {
                    "fecha":         str(date.today()),
                    "deporte":       sport_sel,
                    "liga":          liga_sel,
                    "partido":       f"{away} vs {home}",
                    "event_id":      selected["id"],
                    "mercado":       mercado,
                    "pick_desc":     pick_desc,
                    "momio":         momio,
                    "apuesta":       apuesta,
                    "resultado":     "pendiente",
                    "ganancia_neta": 0,
                    "bankroll_post": bank,
                    "notas":         notas,
                }
                if save_pick(apodo, row):
                    st.success(f"✅ Pick guardado: {pick_desc} @ {momio}x — ${apuesta:,.0f}")
                    st.session_state.pop("df_picks", None)
                    st.session_state.pop("search_events", None)
                    st.session_state.pop("selected_event", None)
                    st.session_state.pop("pick_type", None)
                    st.rerun()


    # ── Pending picks — resolve manually
    pending = df[df["resultado"] == "pendiente"].copy()
    if not pending.empty:
        st.markdown('<div class="sec-head">Picks pendientes</div>', unsafe_allow_html=True)
        st.caption("El auto-calificar se ejecuta al abrir la app. Aquí puedes resolver manualmente si ESPN no lo detecta.")
        for idx, row in pending.iterrows():
            with st.expander(f"⏳  {row['partido']}  ·  {row['liga']}  ·  {row['momio']}x  ·  ${float(row['apuesta']):,.0f}"):
                c1, c2, c3 = st.columns(3)
                with c1:
                    if st.button("✅ Ganado", key=f"w_{idx}"):
                        gan = round(float(row["apuesta"]) * (float(row["momio"]) - 1), 2)
                        nb  = round(bank + gan, 2)
                        update_pick_row(apodo, idx, "ganado", gan, nb)
                        st.session_state["fx"] = "confetti"
                        st.rerun()
                with c2:
                    if st.button("❌ Perdido", key=f"l_{idx}"):
                        gan = -float(row["apuesta"])
                        nb  = round(bank + gan, 2)
                        update_pick_row(apodo, idx, "perdido", gan, nb)
                        st.session_state["fx"] = "wasted"
                        st.rerun()
                with c3:
                    if st.button("➖ Nulo", key=f"n_{idx}"):
                        update_pick_row(apodo, idx, "nulo", 0, bank)
                        st.rerun()


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
        liga_stats = []
        for liga, grp in resolved.groupby("liga"):
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
                    f'<div style="font-size:.95rem;font-weight:700;color:#EEEEF5">{partido}</div>'
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



# ─────────────────────────────────────────────────────────────
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
    racha_list = resolved.sort_values("fecha")["resultado"].tolist()

    # Tilt alert
    consec = 0
    for r in reversed(racha_list[-6:]):
        if r=="perdido": consec+=1
        else: break
    if consec >= 3:
        st.markdown(f'<div class="tilt-alert">🧠 <strong>ALERTA DE TILT</strong> — Llevas {consec} pérdidas consecutivas. Considera pausar y revisar tu estrategia antes del próximo pick.</div>', unsafe_allow_html=True)

    # KPIs
    st.markdown('<div class="sec-head">Resumen general</div>', unsafe_allow_html=True)
    gc = "#00FF88" if roi>=0 else "#FF2D55"
    st.markdown(f"""
<div class="kpi-grid">
  <div class="kpi-box"><div class="kpi-val">{total}</div><div class="kpi-lbl">Total Picks</div></div>
  <div class="kpi-box" style="border-color:rgba(0,255,136,.2)"><div class="kpi-val" style="color:#00FF88">{wr:.1f}%</div><div class="kpi-lbl">Win Rate</div></div>
  <div class="kpi-box" style="border-color:rgba({'0,255,136' if roi>=0 else '255,45,85'},.2)"><div class="kpi-val" style="color:{gc}">{'+' if roi>=0 else ''}{roi:.1f}%</div><div class="kpi-lbl">ROI</div></div>
  <div class="kpi-box" style="border-color:rgba({'0,255,136' if neto>=0 else '255,45,85'},.2)"><div class="kpi-val" style="color:{gc}">${neto:,.0f}</div><div class="kpi-lbl">Neto</div></div>
</div>""", unsafe_allow_html=True)

    st.markdown('<div class="sec-head">Racha reciente</div>', unsafe_allow_html=True)
    st.markdown(racha_html(racha_list), unsafe_allow_html=True)

    # ── Bankroll chart — logarithmic
    st.markdown('<div class="sec-head">Evolución del bankroll (escala logarítmica)</div>', unsafe_allow_html=True)
    bank_df = resolved.sort_values("fecha").copy()
    bank_vals = [START_BANK] + bank_df["bankroll_post"].tolist()
    bank_vals = [max(v, 1) for v in bank_vals]

    # Dynamic log ticks based on max
    max_val  = max(bank_vals + [bank])
    log_ticks = [10_000, 25_000, 50_000, 100_000, 250_000, 500_000,
                 1_000_000, 2_500_000, 5_000_000, 13_000_000]
    log_ticks = [t for t in log_ticks if t <= max_val * 3]

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        y=bank_vals, mode="lines+markers",
        line=dict(color="#FF3D00", width=2.5),
        marker=dict(size=6, color="#FFB800",
                    line=dict(color="#FF3D00", width=1)),
        fill="tozeroy",
        fillcolor="rgba(255,61,0,0.06)",
        name="Bankroll",
    ))
    fig.add_hline(y=RETO_GOAL, line_dash="dot", line_color="#BF5FFF", line_width=1.5,
                  annotation_text="META $13M", annotation_font_color="#BF5FFF",
                  annotation_font_size=10)
    fig.add_hline(y=START_BANK, line_dash="dash", line_color="#F0FF00", line_width=1,
                  annotation_text="INICIO", annotation_font_color="#F0FF00",
                  annotation_font_size=9)
    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color="#8888AA", family="JetBrains Mono"),
        margin=dict(l=10, r=10, t=10, b=10), height=260,
        showlegend=False,
        xaxis=dict(showgrid=False, zeroline=False),
        yaxis=dict(
            type="log",
            tickvals=log_ticks,
            ticktext=[f"${v:,.0f}" for v in log_ticks],
            showgrid=True, gridcolor="rgba(255,255,255,0.05)",
            zeroline=False,
        ),
    )
    st.plotly_chart(fig, use_container_width=True)

    # ── Stats por liga
    st.markdown('<div class="sec-head">Rendimiento por liga</div>', unsafe_allow_html=True)
    liga_stats = []
    for liga, grp in resolved.groupby("liga"):
        g = (grp["resultado"]=="ganado").sum()
        p = (grp["resultado"]=="perdido").sum()
        t = len(grp)
        wr_l  = g/t*100 if t else 0
        roi_l = grp["ganancia_neta"].sum()/grp["apuesta"].sum()*100 if grp["apuesta"].sum() else 0
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
PIT_PLAYERS_HEADERS = ["ronda_id","apodo","estado","dias_vivo","roi_acum",
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
    ("🎾 Tenis",       "tennis",     ["atp","wta"]),
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



def pit_auto_grade(apodo: str, ronda_id: str, my_record: dict) -> tuple[int, int]:
    """
    Check pending PIT picks against ESPN results.
    Returns (ganados, perdidos) count for this run.
    Updates pit_picks rows and pit_jugadores state.
    """
    ss = get_ss()
    if not ss: return 0, 0

    try:
        ws_picks   = ensure_tab(ss, "pit_picks", PIT_PICKS_HEADERS)
        all_picks  = _safe_get_records(ws_picks)
        my_pending = [
            (i, r) for i, r in enumerate(all_picks)
            if str(r.get("ronda_id","")) == str(ronda_id)
            and r.get("apodo","").lower() == apodo.lower()
            and r.get("resultado","pendiente") == "pendiente"
            and r.get("event_id","").strip()
        ]
        if not my_pending:
            return 0, 0

        ganados = 0; perdidos = 0

        for row_idx, pick_row in my_pending:
            event_id = str(pick_row.get("event_id","")).strip()
            pick_desc = str(pick_row.get("pick_desc","")).strip().lower()
            liga_name = str(pick_row.get("liga",""))

            # Find sport for this league name
            sport = "soccer"
            league_slug = ""
            for grp in ESPN_LEAGUES_GROUPED.values():
                for liga, (sp, sl) in grp.items():
                    if liga.upper() == liga_name.upper() or sl.upper().replace("."," ") == liga_name.upper():
                        sport = sp; league_slug = sl; break

            # Try to get event result from ESPN
            event_data = {}
            if league_slug:
                event_data = espn_get_event(sport, league_slug, event_id)
            # Fallback: try common slugs
            if not event_data:
                for sp2, sl2 in [("soccer","eng.1"),("soccer","esp.1"),("basketball","nba"),
                                  ("football","nfl"),("baseball","mlb"),("hockey","nhl"),
                                  ("tennis","atp"),("tennis","wta")]:
                    event_data = espn_get_event(sp2, sl2, event_id)
                    if event_data:
                        sport = sp2; break

            if not event_data:
                continue

            # Check if completed
            header = event_data.get("header",{})
            comps  = header.get("competitions",[{}])
            status = comps[0].get("status",{}).get("type",{}) if comps else {}
            if not status.get("completed", False):
                continue

            # Get scores
            competitors = comps[0].get("competitors",[]) if comps else []
            home_c = next((c for c in competitors if c.get("homeAway")=="home"), None)
            away_c = next((c for c in competitors if c.get("homeAway")=="away"), None)
            if not home_c or not away_c:
                continue

            try:
                home_score = float(home_c.get("score",0) or 0)
                away_score = float(away_c.get("score",0) or 0)
            except Exception:
                continue

            home_name = (home_c.get("team",{}).get("displayName","") or
                         home_c.get("athlete",{}).get("displayName","")).lower()
            away_name = (away_c.get("team",{}).get("displayName","") or
                         away_c.get("athlete",{}).get("displayName","")).lower()

            # Determine winner
            if home_score > away_score:
                winner = "home"
            elif away_score > home_score:
                winner = "away"
            else:
                winner = "draw"

            # Match pick to result
            resultado = None
            if "empate" in pick_desc or "draw" in pick_desc or pick_desc == "empate":
                resultado = "ganado" if winner == "draw" else "perdido"
            else:
                # Check if pick matches home or away team name
                pick_is_home = any(w in pick_desc for w in home_name.split() if len(w)>2)
                pick_is_away = any(w in pick_desc for w in away_name.split() if len(w)>2)
                if not pick_is_home and not pick_is_away:
                    # Try partial match
                    pick_is_home = home_name[:4] in pick_desc
                    pick_is_away = away_name[:4] in pick_desc

                if pick_is_home:
                    resultado = "ganado" if winner == "home" else "perdido"
                elif pick_is_away:
                    resultado = "ganado" if winner == "away" else "perdido"

            if resultado is None:
                continue

            # Update pit_picks row
            try:
                ws_picks.update_cell(row_idx + 2, 10, resultado)  # col 10 = resultado
            except Exception:
                pass

            if resultado == "ganado":
                ganados += 1
            else:
                perdidos += 1

        # Update player state if any picks resolved
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

    # ── Header
    st.markdown("""
<div style="position:relative;text-align:center;padding:28px 20px 20px;overflow:hidden;
     background:linear-gradient(180deg,rgba(255,45,85,.08) 0%,transparent 100%);
     border:1px solid rgba(255,45,85,.2);border-radius:16px;margin-bottom:18px">
  <div style="position:absolute;inset:0;pointer-events:none;
       background-image:linear-gradient(rgba(255,45,85,.04) 1px,transparent 1px),
       linear-gradient(90deg,rgba(255,45,85,.04) 1px,transparent 1px);
       background-size:24px 24px"></div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.55rem;letter-spacing:6px;
       color:rgba(255,45,85,.6);text-transform:uppercase;margin-bottom:8px">⚔ ARENA DE MUERTE ⚔</div>
  <div style="font-family:'Bebas Neue',sans-serif;font-size:4rem;line-height:.9;
       background:linear-gradient(135deg,#FF2D55,#FF6B00,#FFB800);
       -webkit-background-clip:text;-webkit-text-fill-color:transparent;
       filter:drop-shadow(0 0 20px rgba(255,45,85,.5));letter-spacing:4px">
    THE PIT
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.6rem;color:rgba(255,255,255,.25);
       letter-spacing:4px;margin-top:8px">
    MIL ENTRAN · SOLO UNO SALE CON LOS BOLSILLOS LLENOS
  </div>
</div>
""", unsafe_allow_html=True)

    # ── Refresh button (manual)
    col_ref = st.columns([8,1])[1]
    with col_ref:
        if st.button("🔄", key="pit_refresh", help="Actualizar datos del Pit"):
            for k in ["pit_ronda","pit_players","pit_picks","pit_chat_msgs","pit_graded"]:
                st.session_state.pop(k, None)
            pit_load_ronda_activa.clear()
            pit_load_players.clear()
            pit_load_picks_ronda.clear()
            pit_load_chat.clear()
            st.rerun()

    # ── Load active ronda — use session cache to avoid API call on every button click
    if "pit_ronda" not in st.session_state:
        st.session_state["pit_ronda"] = pit_load_ronda_activa()
    ronda = st.session_state["pit_ronda"]

    # ── No active ronda
    if not ronda:
        st.markdown("""
<div style="text-align:center;padding:30px;background:rgba(255,45,85,.05);
     border:1px solid rgba(255,45,85,.2);border-radius:14px">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:1.8rem;color:#FF2D55;margin-bottom:8px">
    NO HAY RONDA ACTIVA
  </div>
  <div style="font-size:.8rem;color:#8888AA">El siguiente torneo aún no ha comenzado.</div>
</div>""", unsafe_allow_html=True)
        c = st.columns([2,1,2])[1]
        with c:
            if st.button("⚔ CREAR NUEVA RONDA", type="primary"):
                rid = pit_crear_ronda()
                if rid:
                    st.success(f"Ronda #{rid} creada. ¡Que comience el foso!")
                    st.session_state.pop("pit_ronda", None)
                    st.rerun()
        return

    ronda_id     = str(ronda["ronda_id"])
    estado_ronda = ronda.get("estado","")
    fecha_inicio = ronda.get("fecha_inicio","")
    fecha_fin    = ronda.get("fecha_fin","")
    hoy          = date.today()
    try:
        dia_actual = (hoy - date.fromisoformat(str(fecha_inicio))).days + 1
    except Exception:
        dia_actual = 1

    # Cache players and picks in session_state
    if "pit_players" not in st.session_state:
        st.session_state["pit_players"] = pit_load_players(ronda_id)
    if "pit_picks" not in st.session_state:
        st.session_state["pit_picks"] = pit_load_picks_ronda(ronda_id)

    players     = st.session_state["pit_players"]
    ronda_picks = st.session_state["pit_picks"]

    vivos      = [p for p in players if p.get("estado") == "vivo"]
    eliminados = [p for p in players if p.get("estado") == "eliminado"]
    total      = len(players)
    n_vivos    = len(vivos)

    # My player record
    my_record = next((p for p in players if p.get("apodo","").lower() == apodo.lower()), None)
    yo_vivo   = my_record and my_record.get("estado") == "vivo"
    yo_elim   = my_record and my_record.get("estado") == "eliminado"

    # ── Auto-grade pending PIT picks (once per session load)
    if yo_vivo and my_record and "pit_graded" not in st.session_state:
        with st.spinner("⚔ Verificando resultados del foso…"):
            try:
                g, p = pit_auto_grade(apodo, ronda_id, my_record)
                st.session_state["pit_graded"] = True
                if g > 0:
                    st.markdown(
                        f'<div class="autobanner" style="background:rgba(0,255,136,.07);border-color:rgba(0,255,136,.3)">'
                        f'⚔ THE PIT: <strong>{g} pick(s) ganados</strong> — ¡Sobreviviste otro día!</div>',
                        unsafe_allow_html=True
                    )
                elif p > 0:
                    st.markdown(
                        f'<div class="tilt-alert">💀 THE PIT: <strong>{p} pick(s) perdidos</strong> — '
                        f'Revisa tu estado en el leaderboard.</div>',
                        unsafe_allow_html=True
                    )
                # Reload players after grading
                if g > 0 or p > 0:
                    st.session_state.pop("pit_players", None)
                    st.session_state.pop("pit_picks", None)
                    players     = pit_load_players(ronda_id)
                    ronda_picks = pit_load_picks_ronda(ronda_id)
                    st.session_state["pit_players"] = players
                    st.session_state["pit_picks"]   = ronda_picks
                    vivos      = [p for p in players if p.get("estado") == "vivo"]
                    eliminados = [p for p in players if p.get("estado") == "eliminado"]
                    total      = len(players)
                    n_vivos    = len(vivos)
                    my_record  = next((p for p in players if p.get("apodo","").lower() == apodo.lower()), None)
                    yo_vivo    = my_record and my_record.get("estado") == "vivo"
                    yo_elim    = my_record and my_record.get("estado") == "eliminado"
            except Exception:
                st.session_state["pit_graded"] = True
    pct_vivos = n_vivos / total * 100 if total else 0
    st.markdown(f"""
<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:16px">
  <div class="kpi-box" style="border-color:rgba(255,45,85,.3)">
    <div class="kpi-val" style="color:#FF2D55">{total}</div>
    <div class="kpi-lbl">Entraron</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(0,255,136,.3)">
    <div class="kpi-val" style="color:#00FF88">{n_vivos}</div>
    <div class="kpi-lbl">Siguen Vivos</div>
  </div>
  <div class="kpi-box" style="border-color:rgba(255,184,0,.3)">
    <div class="kpi-val" style="color:#FFB800">Día {dia_actual}</div>
    <div class="kpi-lbl">{fecha_inicio} → {fecha_fin}</div>
  </div>
</div>
<div style="background:rgba(255,255,255,.04);border-radius:99px;height:8px;overflow:hidden;margin-bottom:16px">
  <div style="width:{100-pct_vivos:.1f}%;height:100%;
       background:linear-gradient(90deg,#FF2D55,#FF6B00);border-radius:99px;
       box-shadow:0 0 12px rgba(255,45,85,.5)"></div>
</div>
<div style="font-family:'JetBrains Mono',monospace;font-size:.55rem;color:#8888AA;
     text-align:center;margin-bottom:16px">
  {total-n_vivos} ELIMINADOS · {pct_vivos:.0f}% AÚN RESPIRAN
</div>
""", unsafe_allow_html=True)

    # ── Inscripcion / Join
    if estado_ronda == "inscripcion" and not my_record:
        st.markdown("""
<div style="background:linear-gradient(135deg,rgba(255,45,85,.1),rgba(255,107,0,.06));
     border:1px solid rgba(255,45,85,.35);border-radius:14px;padding:20px;text-align:center;margin-bottom:16px">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:1.4rem;color:#FF2D55;letter-spacing:3px">
    ¿TIENES LO QUE SE NECESITA?
  </div>
  <div style="font-size:.78rem;color:#8888AA;margin:8px 0 16px">
    Un pick al día · Cuota mínima 1.50 · Sin repetir equipo · Muerte súbita
  </div>
</div>""", unsafe_allow_html=True)
        c = st.columns([2,1,2])[1]
        with c:
            if st.button("⚔ ENTRAR AL FOSO", type="primary"):
                pit_inscribir(ronda_id, apodo)
                pit_load_players.clear()
                pit_save_chat("King Rongo",
                    f"⚔ Un nuevo gladiador entra al foso: **{apodo}**. El Pit tiene {n_vivos+1} víctimas potenciales.", True)
                st.rerun()
        return

    # ── Already eliminated
    if yo_elim:
        asesino = my_record.get("pick_asesino","?")
        st.markdown(f"""
<div style="background:rgba(255,45,85,.08);border:1px solid rgba(255,45,85,.4);
     border-radius:14px;padding:24px;text-align:center;margin-bottom:16px">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:3rem;color:#FF2D55;
       letter-spacing:6px;animation:wastedFade 0s forwards;opacity:1">ELIMINADO</div>
  <div style="font-size:.8rem;color:#8888AA;margin-top:8px">
    Tu pick <strong style="color:#FF2D55">{asesino}</strong> te costó el torneo.
  </div>
  <div style="font-size:.7rem;color:#44445A;margin-top:6px">
    Sobreviviste <strong style="color:#FFB800">{my_record.get('dias_vivo',0)}</strong> día(s) esta ronda.
    La próxima ronda empieza el próximo lunes.
  </div>
</div>""", unsafe_allow_html=True)

    # ── Pick del día (if alive)
    if yo_vivo:
        # Check if already picked today
        today_pick = next(
            (p for p in ronda_picks
             if p.get("apodo","").lower() == apodo.lower()
             and str(p.get("fecha","")) == str(hoy)),
            None
        )
        # Equipos ya usados
        mis_picks_ronda  = [p for p in ronda_picks if p.get("apodo","").lower() == apodo.lower()]
        equipos_usados   = set()
        for pp in mis_picks_ronda:
            desc = pp.get("pick_desc","")
            # extract team name (first word group before spaces/symbols)
            equipos_usados.add(desc.lower().strip())

        comodin_disp = str(my_record.get("comodin_disponible","1")) == "1"

        st.markdown(f"""
<div style="background:linear-gradient(135deg,rgba(0,255,136,.07),rgba(0,180,255,.04));
     border:1px solid rgba(0,255,136,.3);border-radius:12px;padding:14px 18px;margin-bottom:14px">
  <div style="display:flex;justify-content:space-between;align-items:center">
    <div>
      <div style="font-family:'Bebas Neue',sans-serif;font-size:.7rem;letter-spacing:3px;
           color:#00FF88;margin-bottom:2px">🟢 SIGUES VIVO — DÍA {dia_actual}</div>
      <div style="font-family:'JetBrains Mono',monospace;font-size:.6rem;color:#8888AA">
        Días sobrevividos: {my_record.get('dias_vivo',0)} · ROI: {float(my_record.get('roi_acum',0)):.2f}%
      </div>
    </div>
    <div style="text-align:right">
      {"<span style='font-family:\"JetBrains Mono\",monospace;font-size:.6rem;color:#FFB800'>🛡 COMODÍN DISPONIBLE</span>" if comodin_disp else "<span style='font-family:\"JetBrains Mono\",monospace;font-size:.6rem;color:#44445A'>🛡 Comodín usado</span>"}
    </div>
  </div>
</div>""", unsafe_allow_html=True)

        if today_pick:
            res = today_pick.get("resultado","pendiente")
            res_c = {"ganado":"#00FF88","perdido":"#FF2D55","pendiente":"#FFB800"}.get(res,"#888")
            st.markdown(f"""
<div style="background:rgba(255,184,0,.06);border:1px solid rgba(255,184,0,.3);
     border-radius:12px;padding:14px 18px;margin-bottom:14px">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:.65rem;letter-spacing:3px;
       color:#FFB800;margin-bottom:6px">PICK DE HOY REGISTRADO</div>
  <div style="font-family:'Rajdhani',sans-serif;font-size:1rem;font-weight:700;color:#EEEEF5">
    {today_pick.get('partido','')}
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.6rem;color:#8888AA">
    {today_pick.get('pick_desc','')} @ {today_pick.get('momio','')}x
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.65rem;font-weight:700;
       color:{res_c};margin-top:4px">{res.upper()}</div>
</div>""", unsafe_allow_html=True)
        else:
            st.markdown('<div class="sec-head">⚔ Partidos del día — Elige tu pick</div>', unsafe_allow_html=True)
            st.caption("4 partidos aleatorios de distintos deportes · Cuota mínima 1.50 · Sin repetir equipo")

            # Load today's 4 games — cached by date so same for all users
            today_seed = str(date.today())
            pit_daily_key = f"pit_daily_{today_seed}"

            if pit_daily_key not in st.session_state:
                with st.spinner("⚔ Preparando la cartelera del foso…"):
                    st.session_state[pit_daily_key] = pit_get_daily_games(today_seed)

            daily_games = st.session_state.get(pit_daily_key, [])

            if not daily_games:
                st.warning("No se encontraron partidos hoy. Intenta más tarde.")
                if st.button("🔄 Reintentar", key="pit_retry_games"):
                    st.session_state.pop(pit_daily_key, None)
                    pit_get_daily_games.clear()
                    st.rerun()
            else:
                for ev_idx, ev in enumerate(daily_games):
                    sport_ev      = ev.get("sport","soccer")
                    is_tennis_pit = (sport_ev == "tennis")
                    is_soccer_pit = (sport_ev == "soccer")
                    away          = ev["away"]; home = ev["home"]

                    # Skip TBD tennis
                    if is_tennis_pit and (away in ("?","TBD","") or home in ("?","TBD","")):
                        continue

                    is_live       = ev.get("is_live", False)
                    s_txt         = "● LIVE" if is_live else ev["date"]
                    s_col         = "#FF3D00" if is_live else "#00FFD1"
                    sport_label   = ev.get("pit_sport_label","⚽")
                    liga_name     = ev.get("pit_liga_name","")
                    brad_ev       = "50%" if is_tennis_pit else "6px"
                    a_lg = mk_logo(ev.get("away_logo",""), ev.get("away_flag",""), away, 36, brad_ev)
                    h_lg = mk_logo(ev.get("home_logo",""), ev.get("home_flag",""), home, 36, brad_ev)

                    # Card
                    st.markdown(
                        f'<div style="background:rgba(255,45,85,.04);border:1px solid rgba(255,45,85,.2);'
                        f'border-radius:14px;padding:12px 16px;margin-bottom:6px">'
                        f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.5rem;'
                        f'color:#BF5FFF;margin-bottom:8px;letter-spacing:2px">'
                        f'{sport_label} · {liga_name}</div>'
                        f'<div style="display:flex;align-items:center;gap:10px">'
                        f'<div style="display:flex;align-items:center;gap:8px;flex:1">'
                        f'{a_lg}<span style="font-size:.82rem;font-weight:700;color:#EEEEF5">{away}</span>'
                        f'</div>'
                        f'<div style="text-align:center;min-width:40px">'
                        f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.8rem;color:#44445A">VS</div>'
                        f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.48rem;color:{s_col}">{s_txt}</div>'
                        f'</div>'
                        f'<div style="display:flex;align-items:center;gap:8px;flex:1;justify-content:flex-end">'
                        f'<span style="font-size:.82rem;font-weight:700;color:#EEEEF5">{home}</span>{h_lg}'
                        f'</div>'
                        f'</div></div>',
                        unsafe_allow_html=True
                    )

                    # ── Pick buttons per sport ──
                    if is_tennis_pit:
                        # Tennis: only winner, no draw
                        cols_pick = st.columns(2)
                        opts = [(cols_pick[0], f"🎾 {away} gana", away),
                                (cols_pick[1], f"🎾 {home} gana", home)]
                    elif is_soccer_pit:
                        # Soccer: 1X2
                        cols_pick = st.columns(3)
                        opts = [(cols_pick[0], f"⚽ {away[:14]} gana", away),
                                (cols_pick[1], "➖ Empate",            "Empate"),
                                (cols_pick[2], f"⚽ {home[:14]} gana", home)]
                    elif sport_ev == "basketball":
                        # NBA: ML only in THE PIT — O/U lines vary too much
                        cols_pick = st.columns(2)
                        opts = [(cols_pick[0], f"🏀 {away[:16]} ML", away),
                                (cols_pick[1], f"🏀 {home[:16]} ML", home)]
                    elif sport_ev == "baseball":
                        # MLB: ML only in THE PIT
                        cols_pick = st.columns(2)
                        opts = [(cols_pick[0], f"⚾ {away[:16]} ML", away),
                                (cols_pick[1], f"⚾ {home[:16]} ML", home)]
                    elif sport_ev == "hockey":
                        # NHL: ML + Over 5.5 (standard line)
                        cols_pick = st.columns(3)
                        opts = [(cols_pick[0], f"🏒 {away[:12]} ML", away),
                                (cols_pick[1], "📈 Over 5.5",         "Over 5.5"),
                                (cols_pick[2], f"🏒 {home[:12]} ML", home)]
                    elif sport_ev == "football":
                        # NFL: spread + ML
                        cols_pick = st.columns(2)
                        opts = [(cols_pick[0], f"🏈 {away[:16]} ML", away),
                                (cols_pick[1], f"🏈 {home[:16]} ML", home)]
                    else:
                        cols_pick = st.columns(2)
                        opts = [(cols_pick[0], f"🏆 {away[:16]} gana", away),
                                (cols_pick[1], f"🏆 {home[:16]} gana", home)]

                    for opt_idx, (col, lbl, pick_val) in enumerate(opts):
                        with col:
                            used = pick_val.lower().strip() in equipos_usados
                            if st.button(
                                f"{'🚫 ' if used else ''}{lbl}",
                                key=f"pp_{ev_idx}_{opt_idx}",
                                disabled=used,
                                use_container_width=True
                            ):
                                pit_save_pick(
                                    ronda_id, apodo,
                                    f"{away} vs {home}",
                                    liga_name, ev["id"],
                                    pick_val, 1.85, dia_actual
                                )
                                pit_load_picks_ronda.clear()
                                for _k in ["pit_picks","pit_players"]:
                                    st.session_state.pop(_k, None)
                                pit_save_chat("King Rongo",
                                    f"🩸 **{apodo}** disparó `{pick_val}` — "
                                    f"{away} vs {home}. Día {dia_actual}. {n_vivos} siguen vivos.", True)
                                st.success(f"✅ Pick registrado: {pick_val}")
                                st.rerun()

                    st.markdown("<div style='height:4px'></div>", unsafe_allow_html=True)



    # ── Pick del Rey
    with st.expander("👑 PICK DEL REY — Consejo de King Rongo"):
        st.markdown(pit_pick_del_rey(ronda_picks))

    # ── Leaderboard THE PIT
    st.markdown('<div class="sec-head">⚔ Muro de los Vivos y los Caídos</div>', unsafe_allow_html=True)

    vivos_sorted = sorted(vivos, key=lambda p: (-int(p.get("dias_vivo",0)), -float(p.get("roi_acum",0))))
    elim_sorted  = sorted(eliminados, key=lambda p: -int(p.get("dias_vivo",0)))

    medals = ["🥇","🥈","🥉"]

    # Vivos
    for i, p in enumerate(vivos_sorted):
        es_yo   = p.get("apodo","").lower() == apodo.lower()
        medal   = medals[i] if i < 3 else f"#{i+1}"
        dias    = int(p.get("dias_vivo",0))
        roi     = float(p.get("roi_acum",0))
        como    = "🛡" if str(p.get("comodin_disponible","1")) == "1" else ""
        st.markdown(
            f'<div class="lb-row {"me" if es_yo else ""}" '
            f'style="border-color:{"rgba(0,255,136,.4)" if es_yo else "rgba(0,255,136,.15)"};">'
            f'<div style="font-size:1rem;width:28px;text-align:center">{medal}</div>'
            f'<div class="lb-avatar" style="background:linear-gradient(135deg,#00FF88,#00B4FF)">'
            f'{p["apodo"][0].upper()}</div>'
            f'<div style="flex:1">'
            f'<div style="font-size:.85rem;font-weight:700;color:{"#00FF88" if es_yo else "#EEEEF5"}">'
            f'🟢 {p["apodo"].upper()} {"← TÚ" if es_yo else ""} {como}</div>'
            f'<div style="font-size:.6rem;color:#8888AA">Día {dias} · ROI {roi:+.1f}%</div>'
            f'</div>'
            f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:1rem;color:#00FF88">VIVO</div>'
            f'</div>',
            unsafe_allow_html=True
        )

    # Eliminados
    for p in elim_sorted[:10]:
        es_yo  = p.get("apodo","").lower() == apodo.lower()
        dias   = int(p.get("dias_vivo",0))
        asesino = p.get("pick_asesino","?")
        st.markdown(
            f'<div class="lb-row" style="opacity:.55;border-color:rgba(255,45,85,.15)">'
            f'<div style="font-size:1rem;width:28px;text-align:center">💀</div>'
            f'<div class="lb-avatar" style="background:rgba(255,255,255,.06);color:#44445A">'
            f'{p["apodo"][0].upper()}</div>'
            f'<div style="flex:1">'
            f'<div style="font-size:.82rem;font-weight:700;color:#44445A">'
            f'{p["apodo"].upper()} {"← TÚ" if es_yo else ""}</div>'
            f'<div style="font-size:.6rem;color:#44445A">Murió en Día {dias} · Asesinado por: <span style="color:#FF2D55">{asesino}</span></div>'
            f'</div>'
            f'<div style="font-family:\'Bebas Neue\',sans-serif;font-size:.85rem;color:#FF2D55">CAÍDO</div>'
            f'</div>',
            unsafe_allow_html=True
        )

    # ── Taunt Box
    st.markdown('<div class="sec-head">🔥 Taunt Box — King Rongo habla</div>', unsafe_allow_html=True)

    chat_msgs = pit_load_chat(25)
    chat_html = ""
    for msg in reversed(chat_msgs[-15:]):
        is_bot = str(msg.get("es_bot","0")) == "1"
        color  = "#FFB800" if is_bot else "#EEEEF5"
        name   = "👑 KING RONGO" if is_bot else msg.get("apodo","?").upper()
        name_c = "#FFB800" if is_bot else "#BF5FFF"
        ts     = str(msg.get("ts",""))[-8:-3]
        chat_html += (
            f'<div style="padding:6px 0;border-bottom:1px solid rgba(255,255,255,.04)">'
            f'<div style="display:flex;justify-content:space-between;margin-bottom:2px">'
            f'<span style="font-family:\'JetBrains Mono\',monospace;font-size:.55rem;'
            f'color:{name_c};font-weight:700">{name}</span>'
            f'<span style="font-family:\'JetBrains Mono\',monospace;font-size:.5rem;color:#44445A">{ts}</span>'
            f'</div>'
            f'<div style="font-size:.78rem;color:{color}">{msg.get("mensaje","")}</div>'
            f'</div>'
        )
    st.markdown(
        f'<div style="background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.07);'
        f'border-radius:12px;padding:12px 16px;max-height:260px;overflow-y:auto">'
        f'{chat_html or "<div style=\'color:#44445A;font-size:.75rem;text-align:center;padding:20px\'>El foso está en silencio... por ahora.</div>"}'
        f'</div>',
        unsafe_allow_html=True
    )

    # Send message
    c1, c2 = st.columns([5, 1])
    with c1:
        nuevo_msg = st.text_input("", placeholder="Habla o calla para siempre…",
                                   label_visibility="collapsed", key="pit_chat_input")
    with c2:
        if st.button("📢", key="pit_send_chat"):
            if nuevo_msg.strip():
                pit_save_chat(apodo, nuevo_msg.strip())
                st.rerun()


# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────
def main():
    inject_css()

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
    pending_count = (df["resultado"] == "pendiente").sum() if not df.empty else 0
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
        if st.button("🔄", help="Actualizar resultados desde ESPN", key="main_refresh"):
            for k in ["df_picks","df_apodo","pit_ronda","pit_players","pit_picks"]:
                st.session_state.pop(k, None)
            st.rerun()

    # Header
    render_header(apodo, bank)

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
