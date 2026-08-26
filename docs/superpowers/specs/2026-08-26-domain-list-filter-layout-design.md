# Domain List Filter Header Layout Design

## Goal

Naprawić nagłówek filtrów na liście domen, aby elementy:
`No domains yet`, `Subdomains`, `Show empty`, `Monitored`
nie nachodziły na siebie i nie sklejały się wizualnie.

## Scope

Dotyczy wyłącznie widoku:

- `lib/ravner_web/live/domain_live/index.html.heex`

Bez zmian w logice LiveView, routingu, query params, eventach i danych.

## Chosen Approach

Zastosowany układ kolumnowy:

1. Pierwsza linia: status/licznik (`No domains yet` albo liczba domen).
2. Druga linia: przyciski filtrów (`Subdomains`, `Show empty`, `Monitored`) w osobnym kontenerze.
3. Kontener filtrów z możliwością zawijania i czytelnymi odstępami.

## Why This

- Eliminuje konflikt poziomy między etykietą i filtrami.
- Jest najmniejszą możliwą zmianą UI bez ruszania logiki.
- Działa stabilnie niezależnie od długości tekstu i szerokości sidebaru.

## Non-Goals

- Brak zmian zachowania filtrów (`toggle_filter_subdomains`, `toggle_empty_facets`, `toggle_monitored_only`).
- Brak refaktoru innych sekcji listy domen.

## Validation

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`

Testy zależne od lokalnej bazy PostgreSQL są poza zakresem tej poprawki.
