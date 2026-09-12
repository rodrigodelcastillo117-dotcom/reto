# ISS-003/009 V1 — RETIRED / DO_NOT_DEPLOY

`shadow-patches/iss003_009_mlb_governance.sql`
SHA `57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad`

**No desplegar.** Defecto determinista: su Parte 2 insertaba `economically_eligible` y
`reason_code` en las posiciones 15/16 de `v_mejores_picks_mlb`, desplazando `nivel` de 15 a 17.
`CREATE OR REPLACE VIEW` solo admite columnas nuevas **al final**, así que el deploy falla
siempre con:

```
ERROR: cannot change name of view column "nivel" to "economically_eligible"
```

El intento real revirtió atómicamente; producción quedó intacta.

Los archivos V1 se conservan **sin modificar** para que su SHA siga siendo verificable como
referencia histórica. También queda retirado su runner `deploy/run_deploy.sh` y su wrapper
`deploy/deploy_iss003_009.sql`.

**Sustituto:** `iss003_009_mlb_governance_v2.sql` · runbook `iss003_009_DEPLOY_RUNBOOK_V2.md`
· runner `deploy/run_deploy_v2.sh`.
