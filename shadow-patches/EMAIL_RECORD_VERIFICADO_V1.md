# Récord verificado en vivo dentro del email diario

Fecha: 2026-11-09. Gatillo: "mejora toda la app" (transparencia diaria). DINERO OFF.

## Qué
El email `mejores-picks-diario` (v9) ahora muestra, bajo el encabezado, una barra **"Récord verificado"**
con números EN VIVO leídos de `v_reto_tablero_validacion_v1`:
- ✅ acierto global (% + n de picks con resultado)
- 🔒 acierto del tier ≥70% (% + n)
- enlace al tablero: `/validacion`

Reusa la misma vista del tablero → cero cuota, siempre al día. Falla suave: si la vista no responde,
la barra simplemente se omite (el email sale igual). Sin dinero, sin EV, sin stake.

## Por qué
Poner el track record verificado frente al usuario cada mañana construye confianza y fija expectativas
honestas ("≥70% acierta 79%"). Es la honestidad como feature, visible a diario.
