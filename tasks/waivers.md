# Waivers

- **B3d, retired-destinations notice in the app (2026-10-25).** `RetiredDestinationsNotice` is tested with injected closures, not against a real vault: the AppTests vault is in memory at the latest schema, and only migration v16 writes `retired_destinations`. Covered instead by VaultStore `retiredDestinationsShowOnceThenClear` (the SQL) and the app's notice tests. Manual check: RELEASING.md #49.
