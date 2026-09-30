# Third-party notices

Warden's source is licensed under MIT. This does not replace the licenses of the following components.

- **Sound packs:** Elise by Doomspork (Utensils), Kenney Voiceover Pack, Aimee Smith's Announcer Voice Pack and minimal-dings by iain. Their CC BY 4.0 or CC0 notices, source links and modifications are documented in [Resources/Voice/CREDITS.md](Resources/Voice/CREDITS.md). The same credits are included in the app's `Contents/Resources/Voice` folder.
- **train-guard:** MIT, copyright 2026 fus3r. The bundled wheel contains its Python source and license. The frozen helper includes the license under `train_guard-0.5.0.dev0.dist-info/licenses`.
- **CPython:** Python Software Foundation license and the notices for its bundled components, included as `PYTHON-LICENSE.txt` in the helper's Resources folder.
- **psutil:** BSD 3-Clause, with its full notice under `psutil-7.2.2.dist-info/licenses` in the helper.
- **PyInstaller bootloader:** GPL with the distribution exception described in its full `PYINSTALLER-LICENSE.txt`, included in the helper. Source: https://github.com/pyinstaller/pyinstaller/tree/v6.22.3

The helper is `Warden.app/Contents/Helpers/TrainGuard.app`. Its notices live in `Contents/Resources`.

The optional relay installs its npm dependencies separately. Their individual license files are included by npm; `Relay/package-lock.json` records the dependency versions and licenses.
