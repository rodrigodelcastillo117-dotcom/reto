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
ESPN_LEAGUES = {
    # ── SOCCER — Ligas de clubes
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
    # ── SOCCER — Selecciones
    "Eliminatorias UEFA":    ("soccer", "uefa.worldq.eu"),
    "Eliminatorias CONMEBOL":("soccer", "conmebol.worldq"),
    "Eliminatorias CONCACAF":("soccer", "concacaf.worldq"),
    "Eliminatorias AFC":     ("soccer", "afc.worldq"),
    "Nations League UEFA":   ("soccer", "uefa.nations"),
    "Copa América":          ("soccer", "conmebol.america"),
    "Eurocopa":              ("soccer", "uefa.euro"),
    "Gold Cup":              ("soccer", "concacaf.gold"),
    "Amistosos Internac.":   ("soccer", "fifa.friendly"),
    "Mundial de Clubes":     ("soccer", "fifa.cwc"),
    # ── BASKETBALL
    "NBA":                   ("basketball", "nba"),
    # ── AMERICAN FOOTBALL
    "NFL":                   ("football", "nfl"),
    # ── BASEBALL
    "MLB":                   ("baseball", "mlb"),
    # ── HOCKEY
    "NHL":                   ("hockey", "nhl"),
    # ── TENNIS
    "ATP":                   ("tennis", "atp"),
    "WTA":                   ("tennis", "wta"),
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
  background:linear-gradient(145deg,rgba(255,255,255,.05),rgba(255,255,255,.01))!important;
  border:1px solid rgba(255,255,255,.1)!important;color:var(--text)!important;
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

@st.cache_data(ttl=120, show_spinner=False)
def espn_search_events(sport: str, league: str, query: str) -> list:
    """
    Search upcoming + recent events for a sport/league.
    For tennis, query is used to filter by player name.
    Returns list of dicts with id, name, date, status, competitors.
    """
    results = []
    try:
        if sport == "tennis":
            # Tennis: hit scoreboard for ATP/WTA
            url = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
            params = {"limit": 100}
        else:
            url = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
            params = {"limit": 100}

        r = requests.get(url, params=params, timeout=8)
        if r.status_code != 200:
            return []
        data = r.json()
        events = data.get("events", [])

        q_low = query.strip().lower()
        for ev in events:
            name = ev.get("name", "")
            short = ev.get("shortName", name)
            if q_low and q_low not in name.lower() and q_low not in short.lower():
                # also check competitor names
                comps = ev.get("competitions", [{}])[0].get("competitors", [])
                comp_names = " ".join(c.get("team", {}).get("displayName", "") for c in comps).lower()
                if q_low not in comp_names:
                    continue

            comp0 = ev.get("competitions", [{}])[0]
            status_type = ev.get("status", {}).get("type", {})
            status_name = status_type.get("name", "STATUS_SCHEDULED")
            status_short = status_type.get("shortDetail", "")
            completed = status_type.get("completed", False)

            # competitors
            comps = comp0.get("competitors", [])
            home = next((c for c in comps if c.get("homeAway") == "home"), comps[0] if comps else {})
            away = next((c for c in comps if c.get("homeAway") == "away"), comps[1] if len(comps) > 1 else {})
            home_name  = home.get("team", {}).get("displayName", home.get("athlete", {}).get("displayName", "?"))
            away_name  = away.get("team", {}).get("displayName", away.get("athlete", {}).get("displayName", "?"))
            home_score = home.get("score", "")
            away_score = away.get("score", "")

            # date
            date_raw = ev.get("date", "")
            try:
                dt = datetime.fromisoformat(date_raw.replace("Z", "+00:00"))
                date_str = dt.strftime("%d %b %H:%M")
            except Exception:
                date_str = date_raw[:10]

            results.append({
                "id":         ev.get("id", ""),
                "name":       name,
                "short":      short,
                "home":       home_name,
                "away":       away_name,
                "home_score": home_score,
                "away_score": away_score,
                "date":       date_str,
                "date_raw":   date_raw,
                "status":     status_name,
                "status_detail": status_short,
                "completed":  completed,
            })

        # Also pull next page (schedule) if few results
        if len(results) < 5:
            url2 = f"{ESPN_BASE}/{sport}/{league}/scoreboard"
            tomorrow = (date.today() + timedelta(days=1)).isoformat()
            week_out = (date.today() + timedelta(days=7)).isoformat()
            r2 = requests.get(url2, params={"dates": f"{tomorrow.replace('-','')}-{week_out.replace('-','')}", "limit": 50}, timeout=8)
            if r2.status_code == 200:
                for ev in r2.json().get("events", []):
                    name = ev.get("name", "")
                    short = ev.get("shortName", name)
                    if q_low and q_low not in name.lower() and q_low not in short.lower():
                        comps = ev.get("competitions", [{}])[0].get("competitors", [])
                        comp_names = " ".join(c.get("team", {}).get("displayName", "") for c in comps).lower()
                        if q_low not in comp_names:
                            continue
                    comp0 = ev.get("competitions", [{}])[0]
                    status_type = ev.get("status", {}).get("type", {})
                    comps = comp0.get("competitors", [])
                    home = next((c for c in comps if c.get("homeAway") == "home"), comps[0] if comps else {})
                    away = next((c for c in comps if c.get("homeAway") == "away"), comps[1] if len(comps) > 1 else {})
                    home_name = home.get("team", {}).get("displayName", home.get("athlete", {}).get("displayName", "?"))
                    away_name = away.get("team", {}).get("displayName", away.get("athlete", {}).get("displayName", "?"))
                    date_raw = ev.get("date", "")
                    try:
                        dt = datetime.fromisoformat(date_raw.replace("Z", "+00:00"))
                        date_str = dt.strftime("%d %b %H:%M")
                    except Exception:
                        date_str = date_raw[:10]
                    results.append({
                        "id": ev.get("id", ""), "name": name, "short": short,
                        "home": home_name, "away": away_name,
                        "home_score": "", "away_score": "",
                        "date": date_str, "date_raw": date_raw,
                        "status": status_type.get("name","STATUS_SCHEDULED"),
                        "status_detail": status_type.get("shortDetail",""),
                        "completed": status_type.get("completed", False),
                    })

    except Exception:
        pass
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

@st.cache_resource(ttl=60)
def get_client():
    try:
        creds_dict = {k: v for k, v in st.secrets["gsheets"].items() if k != "spreadsheet_id"}
        creds = ServiceAccountCredentials.from_json_keyfile_dict(creds_dict, SCOPE)
        return gspread.authorize(creds)
    except Exception:
        return None

def get_ss():
    c = get_client()
    if not c: return None
    try:
        return c.open_by_key(st.secrets["gsheets"]["spreadsheet_id"])
    except Exception:
        return None

def ensure_tab(ss, name: str, headers: list):
    try:
        return ss.worksheet(name)
    except gspread.WorksheetNotFound:
        ws = ss.add_worksheet(title=name, rows=2000, cols=len(headers))
        ws.append_row(headers)
        return ws

def load_picks(apodo: str) -> pd.DataFrame:
    ss = get_ss()
    if not ss: return pd.DataFrame(columns=PICKS_HEADERS)
    ws   = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
    data = ws.get_all_records()
    if not data: return pd.DataFrame(columns=PICKS_HEADERS)
    df = pd.DataFrame(data)
    df["fecha"] = pd.to_datetime(df["fecha"], errors="coerce")
    for col in ["momio","apuesta","ganancia_neta","bankroll_post"]:
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    return df

def save_pick(apodo: str, row: dict) -> bool:
    ss = get_ss()
    if not ss: return False
    ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
    ws.append_row([str(row.get(h, "")) for h in PICKS_HEADERS])
    return True

def update_pick_row(apodo: str, df_idx: int, resultado: str, ganancia: float, bank_post: float):
    ss = get_ss()
    if not ss: return False
    ws = ensure_tab(ss, f"picks_{apodo.lower()}", PICKS_HEADERS)
    sheet_row = df_idx + 2  # header=1, data starts at 2
    # cols: resultado=10, ganancia_neta=11, bankroll_post=12
    ws.update_cell(sheet_row, 10, resultado)
    ws.update_cell(sheet_row, 11, round(ganancia, 2))
    ws.update_cell(sheet_row, 12, round(bank_post, 2))
    return True

def load_users() -> list:
    ss = get_ss()
    if not ss: return []
    ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","wins","losses","created"])
    return ws.get_all_records()

def upsert_user(apodo: str, bankroll: float, wins: int, losses: int):
    ss = get_ss()
    if not ss: return
    ws = ensure_tab(ss, TAB_USERS, ["apodo","bankroll","wins","losses","created"])
    records = ws.get_all_records()
    for i, r in enumerate(records):
        if r.get("apodo","").lower() == apodo.lower():
            ws.update(f"A{i+2}:E{i+2}", [[apodo, round(bankroll,2), wins, losses, r.get("created","")]])
            return
    ws.append_row([apodo, round(bankroll,2), wins, losses, str(date.today())])


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
    try:
        users_data = load_users()
        existing_users = [u["apodo"] for u in users_data if u.get("apodo","").strip()]
    except Exception:
        existing_users = []

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
#  TAB 1 — REGISTRAR PICK
# ─────────────────────────────────────────────────────────────
def tab_registrar(apodo: str, df: pd.DataFrame, bank: float):
    st.markdown('<div class="sec-head">Buscar partido</div>', unsafe_allow_html=True)

    # ── Step 1: Sport + League selector
    c1, c2 = st.columns(2)
    with c1:
        liga_sel = st.selectbox("Liga / Torneo", list(ESPN_LEAGUES.keys()), key="reg_liga")
    with c2:
        # HTML input with autocomplete=off — reads value via query params trick
        st.markdown("""
<label style="font-family:'Rajdhani',sans-serif;font-weight:600;font-size:.9rem;color:#8888AA">
  Buscar equipo / jugador
</label>
<input
  id="espn_query_input"
  type="text"
  autocomplete="off"
  autocorrect="off"
  autocapitalize="off"
  spellcheck="false"
  placeholder="ej: Liverpool, Djokovic, Lakers…"
  style="width:100%;padding:10px 14px;margin-top:4px;
         background:#1A1A28;border:1px solid rgba(255,255,255,.18);
         border-radius:10px;color:#EEEEF5;font-family:'Rajdhani',sans-serif;
         font-size:1rem;outline:none;caret-color:#F0FF00;box-sizing:border-box"
  oninput="document.getElementById('espn_query_hidden').value=this.value"
  onfocus="this.style.borderColor='rgba(240,255,0,.5)';this.style.boxShadow='0 0 14px rgba(240,255,0,.12)'"
  onblur="this.style.borderColor='rgba(255,255,255,.18)';this.style.boxShadow='none'"
/>
<input type="hidden" id="espn_query_hidden" value="">
<script>
// Sync HTML input value into Streamlit session via a hidden st.text_input
var _qInput = document.getElementById('espn_query_input');
var _interval = setInterval(function(){
  var stInput = document.querySelector('input[data-testid="espn_query_st"]');
  if(!stInput){ stInput = document.querySelectorAll('input[aria-label="__espn_q__"]')[0]; }
  if(_qInput && stInput){
    stInput.value = _qInput.value;
    stInput.dispatchEvent(new Event('input',{bubbles:true}));
  }
}, 300);
</script>
""", unsafe_allow_html=True)
        # Hidden Streamlit input that captures the value
        query = st.text_input("__espn_q__", value=st.session_state.get("espn_query",""),
                               label_visibility="hidden", key="espn_query_st")
        # Also store in session for persistence
        if query:
            st.session_state["espn_query"] = query

    # Use session query as fallback
    query = st.session_state.get("espn_query_st", "") or st.session_state.get("espn_query", "")

    sport, league = ESPN_LEAGUES[liga_sel]
    events = []

    if st.button("🔍 BUSCAR PARTIDOS", key="btn_search"):
        with st.spinner("Consultando ESPN…"):
            events = espn_search_events(sport, league, query)
            st.session_state["search_events"] = events
            st.session_state["selected_event"] = None

    events = st.session_state.get("search_events", [])
    selected = st.session_state.get("selected_event", None)

    if events:
        st.markdown(f'<div style="font-family:\'JetBrains Mono\',monospace;font-size:.6rem;color:var(--text3);margin-bottom:8px">{len(events)} PARTIDOS ENCONTRADOS</div>', unsafe_allow_html=True)
        for ev in events[:20]:
            status_cls = "status-live" if "IN" in ev["status"] else ("status-final" if ev["completed"] else "status-pre")
            status_lbl = "● LIVE" if "IN" in ev["status"] else ("✓ FINAL" if ev["completed"] else "⏰ " + ev["date"])
            score_str  = f"{ev['away_score']} – {ev['home_score']}" if ev["completed"] or "IN" in ev["status"] else ""
            is_sel     = selected and selected["id"] == ev["id"]

            card_html = f"""
<div class="game-card {'selected' if is_sel else ''}" id="gc_{ev['id']}">
  <div style="display:flex;justify-content:space-between;align-items:center">
    <div style="font-family:'Rajdhani',sans-serif;font-size:.88rem;font-weight:700;color:var(--text)">
      {ev['away']} <span style="color:var(--text3)">vs</span> {ev['home']}
    </div>
    <div style="display:flex;align-items:center;gap:10px">
      {"<span style='font-family:\"JetBrains Mono\",monospace;font-size:.85rem;font-weight:700;color:var(--neon)'>" + score_str + "</span>" if score_str else ""}
      <span class="{status_cls}">{status_lbl}</span>
    </div>
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.55rem;color:var(--text3);margin-top:3px">
    {liga_sel}  ·  ID: {ev['id']}
  </div>
</div>"""
            st.markdown(card_html, unsafe_allow_html=True)
            if st.button(f"✔ Seleccionar", key=f"sel_{ev['id']}"):
                st.session_state["selected_event"] = ev
                st.rerun()

    # ── Step 2: Pick form (only if event selected)
    selected = st.session_state.get("selected_event", None)
    if selected:
        st.markdown(f"""
<div style="background:linear-gradient(135deg,rgba(240,255,0,.08),rgba(255,184,0,.04));
     border:1px solid rgba(240,255,0,.3);border-radius:12px;padding:14px 18px;margin:14px 0">
  <div style="font-family:'Bebas Neue',sans-serif;font-size:.7rem;letter-spacing:3px;color:var(--neon);margin-bottom:6px">PARTIDO SELECCIONADO</div>
  <div style="font-family:'Rajdhani',sans-serif;font-size:1.1rem;font-weight:700;color:var(--text)">
    {selected['away']} vs {selected['home']}
  </div>
  <div style="font-family:'JetBrains Mono',monospace;font-size:.58rem;color:var(--text3)">
    {liga_sel}  ·  {selected['date']}  ·  ESPN ID: {selected['id']}
  </div>
</div>
""", unsafe_allow_html=True)

        st.markdown('<div class="sec-head">Detalles del pick</div>', unsafe_allow_html=True)

        with st.form("form_pick", clear_on_submit=True):
            c1, c2 = st.columns(2)
            with c1:
                mercado  = st.selectbox("Mercado", MERCADOS)
                momio    = st.number_input("Momio (decimal)", min_value=1.01, max_value=99.0, value=1.85, step=0.01)
            with c2:
                kelly_amt = round(bank * kelly(momio), 2)
                apuesta  = st.number_input(
                    f"Apuesta ($MXN)  —  Kelly: ${kelly_amt:,.2f}",
                    min_value=1.0, max_value=float(bank),
                    value=min(kelly_amt, bank) if kelly_amt > 0 else 100.0,
                    step=50.0
                )
                fecha_p  = st.date_input("Fecha del partido", value=date.today())

            pick_desc = st.text_input(
                "Descripción del pick",
                placeholder="ej: Over 2.5 · Real Madrid ML · Lakers -5.5 · BTTS Sí"
            )
            notas = st.text_area("Análisis / notas", placeholder="¿Por qué este pick?", height=70)
            submitted = st.form_submit_button("💾 GUARDAR PICK", type="primary")

        if submitted:
            if not pick_desc:
                st.error("Escribe la descripción del pick.")
            else:
                row = {
                    "fecha":        str(fecha_p),
                    "deporte":      sport,
                    "liga":         liga_sel,
                    "partido":      f"{selected['away']} vs {selected['home']}",
                    "event_id":     selected["id"],
                    "mercado":      mercado,
                    "pick_desc":    pick_desc,
                    "momio":        momio,
                    "apuesta":      apuesta,
                    "resultado":    "pendiente",
                    "ganancia_neta":0,
                    "bankroll_post":bank,
                    "notas":        notas,
                }
                if save_pick(apodo, row):
                    st.success("✅ Pick guardado en Google Sheets")
                    st.session_state.pop("search_events", None)
                    st.session_state.pop("selected_event", None)
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
def tab_historial(df: pd.DataFrame):
    if df.empty:
        st.info("Sin picks registrados aún.")
        return

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

    res_c = {"ganado":"#00FF88","perdido":"#FF2D55","nulo":"#8888AA","pendiente":"#FFB800"}
    res_i = {"ganado":"✅","perdido":"❌","nulo":"➖","pendiente":"⏳"}

    for _, row in filt.iterrows():
        res  = row.get("resultado","pendiente")
        clr  = res_c.get(res,"#888")
        ico  = res_i.get(res,"·")
        gan  = float(row.get("ganancia_neta",0))
        gs   = f'+${gan:,.2f}' if gan>0 else f'${gan:,.2f}' if gan<0 else "—"
        gc   = "#00FF88" if gan>0 else "#FF2D55" if gan<0 else "#8888AA"
        fd   = str(row.get("fecha",""))[:10]
        st.markdown(f"""
<div class="pick-card">
  <div class="pick-badge {res[0] if res in ('ganado','perdido') else 'n'}">{ico}</div>
  <div style="flex:1;min-width:0">
    <div style="font-size:.88rem;font-weight:700;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
      {row.get('partido','')}
    </div>
    <div style="font-size:.65rem;color:var(--text3)">
      {row.get('liga','')} · {row.get('mercado','')} · <span style="color:var(--neon2)">{row.get('pick_desc','')}</span>
    </div>
    <div style="font-size:.6rem;color:var(--text3)">{fd}</div>
  </div>
  <div style="text-align:right;flex-shrink:0">
    <div style="font-family:'Bebas Neue',sans-serif;font-size:1.2rem;color:{gc}">{gs}</div>
    <div style="font-size:.6rem;color:var(--text3)">{row.get('momio','')}x · ${float(row.get('apuesta',0)):,.0f}</div>
    <div style="font-size:.6rem;color:{clr};font-weight:700;font-family:'JetBrains Mono',monospace">{res.upper()}</div>
  </div>
</div>""", unsafe_allow_html=True)


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
    with st.spinner("⚡ Cargando…"):
        df = load_picks(apodo)

    # ── AUTO-GRADE on every load ──────────────────────────────
    bank = get_bankroll(df)
    pending_count = (df["resultado"] == "pendiente").sum() if not df.empty else 0
    if pending_count > 0:
        df, graded, bank = auto_grade_pending(apodo, df, bank)
        if graded > 0:
            st.markdown(
                f'<div class="autobanner">⚡ Auto-calificador: <strong>{graded} pick(s)</strong> resueltos automáticamente desde ESPN.</div>',
                unsafe_allow_html=True
            )
    else:
        bank = get_bankroll(df)

    # Manual refresh button
    col_r = st.columns([6,1])[1]
    with col_r:
        if st.button("🔄", help="Actualizar resultados desde ESPN"):
            st.cache_data.clear()
            df = load_picks(apodo)
            bank = get_bankroll(df)
            df, graded, bank = auto_grade_pending(apodo, df, bank)
            if graded > 0:
                st.success(f"✅ {graded} pick(s) resueltos.")
            else:
                st.info("No hay nuevos resultados disponibles.")
            st.rerun()

    # Header
    render_header(apodo, bank)

    # Tabs
    t1, t2, t3, t4, t5 = st.tabs([
        "📝  REGISTRAR", "📋  HISTORIAL", "📊  ANALYTICS", "⚔️  LEADERBOARD", "🔮  SIMULADOR"
    ])
    with t1: tab_registrar(apodo, df, bank)
    with t2: tab_historial(df)
    with t3: tab_analytics(df, bank)
    with t4: tab_challenge(apodo, df, bank)
    with t5: tab_simulador(df, bank)


if __name__ == "__main__":
    main()
