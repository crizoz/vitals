#!/bin/bash
# Que ningún idioma se quede atrás: compara las claves que usa Localization.swift
# contra cada tabla de traducción. Si sobra o falta una, o los marcadores de
# formato no calzan con el idioma base, la compilación falla en vez de dejar que
# la app muestre la clave cruda o reviente al armar la frase.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
exec /usr/bin/python3 "$(dirname "$0")/check_strings.py" "$ROOT"
