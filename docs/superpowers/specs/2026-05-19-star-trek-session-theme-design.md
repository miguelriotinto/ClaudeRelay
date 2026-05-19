# Star Trek Session Naming Theme

**Status:** Approved
**Date:** 2026-05-19
**Owner:** Miguel Rio-Tinto

## Background

Sessions on iOS and Mac are auto-named from a themed character pool selected
in Settings. The current themes are Game of Thrones, Viking, Star Wars, Dune,
and Lord of the Rings — each with ~65–70 names. This spec adds a sixth
theme: **Star Trek**.

Names live in `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift` so
both the iOS and Mac apps share a single source of truth.

## Goals

- Add a `starTrek` case to `SessionNamingTheme` with mixed-canon coverage
  (TOS through SNW/Lower Decks).
- Surface the new theme in both apps' Settings Pickers without touching
  any view code.
- Preserve existing user theme preferences (no migration, no raw-value
  churn).

## Non-Goals

- Changing the default theme (stays `gameOfThrones`).
- Adding any new UI affordance beyond the existing Picker row.
- Adding theme sub-categories or per-series filters.
- Changing how names are picked (`SessionNaming.pickDefaultName` is
  unchanged).

## Design

### Single-file change

The entire feature lives in `Sources/ClaudeRelayClient/Helpers/SessionNaming.swift`:

1. **Add enum case** — `case starTrek` appended to `SessionNamingTheme`.
   - Raw value `"starTrek"` (matches the existing `lowerCamelCase`
     convention; `lordOfTheRings`, `gameOfThrones`, `starWars` set the
     precedent).
   - Append to the end of the enum so the Picker order remains stable
     for existing users (Game of Thrones first, Star Trek last).
2. **`displayName` arm** — `case .starTrek: return "Star Trek"`.
3. **`names` arm** — `case .starTrek: return Self.starTrekNames`.
4. **Name pool** — `public static let starTrekNames: [String]` with
   ~65 entries spanning TOS, TNG, DS9, VOY, ENT, DSC, PIC, SNW, LD.

No other files change. The Settings Picker on both platforms iterates
`SessionNamingTheme.allCases`, and `@AppStorage` round-trips any raw
value, so the new theme appears automatically.

### Name pool (~65 entries, mixed canon)

Distribution targets the iconic-ensemble layer of each show:

- **TOS / TOS films (14):** Kirk, Spock, McCoy, Uhura, Scotty, Sulu,
  Chekov, Chapel, Rand, Sarek, Khan, Pike, T'Pring, Number One
- **TNG (15):** Picard, Riker, Data, Worf, La Forge, Crusher, Troi,
  Wesley, Guinan, Q, Ro Laren, Pulaski, Tasha Yar, Barclay, Lwaxana
- **DS9 (16):** Sisko, Kira, Odo, Bashir, Dax, O'Brien, Quark, Garak,
  Rom, Nog, Jake, Dukat, Weyoun, Martok, Damar, Ezri
- **VOY (10):** Janeway, Chakotay, Tuvok, Paris, Torres, Kim, Neelix,
  Kes, Seven, The Doctor
- **ENT (7):** Archer, T'Pol, Trip, Reed, Mayweather, Hoshi, Phlox
- **Modern — DSC / PIC / SNW / LD (14):** Burnham, Saru, Tilly,
  Lorca, Georgiou, Stamets, Una, La'an, M'Benga, Ortegas, Mariner,
  Boimler, Tendi, Rutherford

**Total: 76.** Matches the density of existing pools (Star Wars 70,
Viking 70, LotR 70). In code they will live in a single flat array
ordered roughly by series for readability — order doesn't affect
behavior since `pickDefaultName` calls `randomElement()`.

### Persistence & migration

None required. `SessionNamingTheme` raw values are persisted by
`@AppStorage("sessionNamingTheme")` (iOS) and
`@AppStorage("com.clauderelay.mac.sessionNamingTheme")` (Mac).
Appending a new case does not affect the encoding of existing cases.
`testThemeRawValuesAreStable` already pins each existing raw value
and will gain one new assertion for `"starTrek"` to lock the new one
in too.

### Tests

In `Tests/ClaudeRelayClientTests/SessionNamingTests.swift`:

1. **Extend `testThemeRawValuesAreStable`** with:
   ```swift
   XCTAssertEqual(SessionNamingTheme.starTrek.rawValue, "starTrek")
   ```
2. **Add `testStarTrekPoolHasReasonableSize`** — asserts
   `SessionNamingTheme.starTrek.names.count >= 50`. Guards against
   accidentally shipping a tiny pool that would cause early
   `Session N` fallback. Lower bound matches the de-facto density
   of the other themes without pinning an exact count.

The existing tests automatically cover the new theme:
- `testEveryThemeHasNames` — non-empty.
- `testEveryThemeHasAtLeastTenNames` — minimum floor.
- `testAllThemesIdMatchesRawValue` — `id == rawValue`.
- `testPickFromEmptyUsedNamesReturnsThemeName` — only ever uses
  `dune` directly, but the underlying `pickDefaultName` is theme-
  agnostic so adding `starTrek` doesn't require new coverage here.

### Default selection

Unchanged. New users still default to `gameOfThrones`. Users who
want Star Trek pick it from Settings → Session Naming.

## Risks

- **None substantive.** Adding an enum case is the lowest-risk change
  in this codebase — no protocol, no API, no persistence-format
  change. Both Settings Pickers iterate `allCases` and use
  `.fixedSize()` for layout, so a new label doesn't disrupt sizing.

## Implementation Order

1. Add `starTrek` case + `displayName` + `names` arm + name array to
   `SessionNaming.swift`.
2. Extend `testThemeRawValuesAreStable` and add
   `testStarTrekPoolHasReasonableSize`.
3. Run `swift test --filter SessionNamingTests`.
4. Manual verification:
   - Mac: open Settings → Session Naming, confirm "Star Trek" appears
     and persists across app restart.
   - iOS: same flow in iOS Settings.
   - Create a new session in each app while Star Trek is selected
     and confirm the auto-name comes from the pool.

## Out of Scope (Future)

- Per-theme sub-options (e.g., "TOS only").
- User-customisable name pools.
- Localised names (none of the existing themes localise).
