# Devxpander

Personal macOS menu bar snippet app with:

- Snippets listed in the menu bar dropdown (no background text monitoring)
- One-click paste of the snippet text where the caret is focused
- Optional **menu label** plus expansion text (`title` in JSON—legacy `keyword` keys still load)
- JSON import/export for backup and migration

## Build

```bash
./scripts/build-devxpander.sh
```

## Run

```bash
open "Devxpander.app"
```

## First-time Permissions

Devxpander needs **Accessibility** permission to insert snippet text into other apps:

`System Settings > Privacy & Security > Accessibility`

## Snippet JSON Format

```json
[
  {
    "title": "Email sign-off",
    "expansion": "Thanks,\nRaffy"
  }
]
```

Legacy files using `"keyword"` instead of `"title"` are still accepted on import and when loading `snippets.json`.
