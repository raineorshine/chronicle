---
description: Rebuild and install Chronicle.app from the current checkout, then launch it.
---

Rebuild and (re)install the Chronicle app from the current checkout, then open it:

```bash
./scripts/install-app.sh --open
```

Notes:
- Installs from the current working directory's checkout (use `/install-main` to
  install from the main checkout instead).
- `install-app.sh` builds the Release configuration, installs to
  `/Applications/Chronicle.app`, and `--open` relaunches it.
